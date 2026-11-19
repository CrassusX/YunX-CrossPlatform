"""YunX Linux 测试套件：全部使用本地 HTTP 服务器，不依赖外网。

运行： python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from yunx import __version__  # noqa: E402
from yunx.baidu import BaiduResolver, PanHTTP  # noqa: E402
from yunx.cookiestore import load_cookies, save_cookies  # noqa: E402
from yunx.engine import Engine, Timing  # noqa: E402
from yunx.linkparser import baidu_surl, parse  # noqa: E402
from yunx.models import Segment, Task  # noqa: E402
from yunx.web import WebApp  # noqa: E402


DATA = random.Random(20261118).randbytes(400 * 1024)


class RecordingServer:
    """可配置行为的 Range 服务器。"""

    def __init__(self, data: bytes = DATA, **options):
        self.data = data
        self.options = options
        self.lock = threading.Lock()
        self.requests = []
        self._ref = None

        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                pass

            def do_GET(self):
                with server.lock:
                    server.requests.append(self.headers.get("Range") or "FULL")
                    number = len(server.requests)
                    options = server.options

                if options.get("fatal_status"):
                    self.send_response(options["fatal_status"])
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return

                if number <= options.get("http_error_times", 0):
                    self.send_response(503)
                    self.send_header("Content-Length", "2")
                    self.end_headers()
                    self.wfile.write(b"no")
                    return

                if options.get("ignore_range"):
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(server.data)))
                    self.end_headers()
                    self.wfile.write(server.data)
                    return

                header = self.headers.get("Range")
                if not header:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(server.data)))
                    self.end_headers()
                    self.wfile.write(server.data)
                    return
                try:
                    spec = header.split("=", 1)[1]
                    left, right = spec.split("-", 1)
                    start = int(left)
                    end = int(right) if right else len(server.data) - 1
                except (ValueError, IndexError):
                    self.send_response(400)
                    self.end_headers()
                    return
                end = min(end, len(server.data) - 1)

                limit = options.get("empty_before", 0)
                if limit and number <= limit:
                    # 模拟百度限流：206 + 0 字节，状态码完全正常
                    self.send_response(206)
                    self.send_header("Content-Range",
                                     f"bytes {start}-{start}/{len(server.data)}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return

                length = min(end - start + 1, options.get("chunk", 1 << 30))
                last = start + length - 1
                self.send_response(206)
                self.send_header("Content-Range",
                                 f"bytes {start}-{last}/{len(server.data)}")
                self.send_header("Content-Length", str(length))
                self.end_headers()
                try:
                    self.wfile.write(server.data[start:start + length])
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                if length < end - start + 1:
                    self.close_connection = True

        self._ref = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self._ref.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self._ref.server_port}/data.bin"

    def stop(self):
        self._ref.shutdown()
        self._ref.server_close()
        self.thread.join(timeout=2)

    def count(self):
        with self.lock:
            return len(self.requests)


class EngineTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        os.environ["YUNX_CONFIG_DIR"] = self.temp.name
        self.server = None
        self.engine = None

    def tearDown(self):
        if self.engine:
            self.engine.shutdown()
        if self.server:
            self.server.stop()
        os.environ.pop("YUNX_CONFIG_DIR", None)
        self.temp.cleanup()

    def make_engine(self, **settings):
        values = {
            "download_directory": os.path.join(self.temp.name, "dl"),
            "connections": 4,
            "speed_limit_kbps": 0,
            "auto_retry": True,
            "max_segment_attempts": 30,
            "max_empty_responses": 80,
            "stall_timeout": 60,
        }
        values.update(settings)
        engine = Engine(settings=values, timing=Timing(fast=True))
        engine.start()
        self.engine = engine
        return engine

    @staticmethod
    def wait_done(task, timeout=25):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if task.status in ("completed", "failed", "waitingRetry", "paused"):
                return task.status
            time.sleep(0.02)
        return "timeout"

    def assert_file_ok(self, task):
        raw = Path(task.file_path).read_bytes()
        self.assertEqual(len(raw), len(DATA))
        self.assertEqual(hashlib.sha256(raw).hexdigest(), hashlib.sha256(DATA).hexdigest())

    # ---------- 引擎 ----------

    def test_01_normal_segmented_download(self):
        self.server = RecordingServer(chunk=8192)
        engine = self.make_engine()
        task = engine.add_task(self.server.url, "normal.bin", len(DATA), connections=4)
        self.assertEqual(self.wait_done(task), "completed")
        self.assert_file_ok(task)
        self.assertGreater(self.server.count(), 4)   # 分片确实分多次请求
        print(f"\n  正常分片：{self.server.count()} 次请求，逐字节校验通过")

    def test_02_force_disconnect_resume(self):
        # 每次只给 16KB 就断开，模拟弱网反复断连
        self.server = RecordingServer(chunk=16 * 1024)
        engine = self.make_engine()
        task = engine.add_task(self.server.url, "weak.bin", len(DATA), connections=4)
        self.assertEqual(self.wait_done(task, 40), "completed")
        self.assert_file_ok(task)
        self.assertGreater(self.server.count(), 25)
        print(f"\n  每 16KB 断连：{self.server.count()} 次重连后完成，校验通过")

    def test_03_empty_206_not_counted_as_failure(self):
        self.server = RecordingServer(chunk=64 * 1024, empty_before=6)
        engine = self.make_engine()
        task = engine.add_task(self.server.url, "limited.bin", len(DATA), connections=4)
        status = self.wait_done(task, 40)
        self.assertEqual(status, "completed", task.error)
        self.assert_file_ok(task)
        self.assertEqual(task.retry_count, 0)   # 空响应不该升级成任务级重试
        print(f"\n  206+0字节限流：空响应后仍完成，任务级重试={task.retry_count}")

    def test_04_transient_5xx_retry(self):
        self.server = RecordingServer(chunk=64 * 1024, http_error_times=5)
        engine = self.make_engine()
        task = engine.add_task(self.server.url, "5xx.bin", len(DATA))
        self.assertEqual(self.wait_done(task, 30), "completed")
        self.assert_file_ok(task)
        print(f"\n  5xx 临时故障：重试后完成，共 {self.server.count()} 次请求")

    def test_05_fatal_403_no_retry(self):
        self.server = RecordingServer(fatal_status=403)
        engine = self.make_engine()
        # 单连接：排除并发分片竞态，403 必然只发 1 次请求（不重试不打转）
        task = engine.add_task(self.server.url, "fatal.bin", len(DATA), connections=1)
        self.assertEqual(self.wait_done(task), "failed")
        self.assertEqual(self.server.count(), 1)
        print("\n  403：直接失败，只请求 1 次")

    def test_06_no_range_fallback(self):
        self.server = RecordingServer(ignore_range=True)
        engine = self.make_engine()
        task = engine.add_task(self.server.url, "norange.bin", len(DATA), connections=4)
        self.assertEqual(self.wait_done(task, 30), "completed")
        self.assert_file_ok(task)
        self.assertFalse(task.supports_range)
        print("\n  服务器忽略 Range：自动降级单连接并校验通过")

    def test_07_resume_from_partial_file(self):
        self.server = RecordingServer(chunk=64 * 1024)
        engine = self.make_engine()
        half = len(DATA) // 2
        directory = engine.settings["download_directory"]
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "partial.bin")
        with open(path, "wb") as handle:
            handle.write(DATA[:half])
        task = Task(
            id="partial123456", url=self.server.url, file_name="partial.bin",
            directory=directory, total_size=len(DATA),
            segments=[Segment(0, half - 1, half), Segment(half, len(DATA) - 1, 0)],
            status="queued", connections=2,
        )
        engine.tasks[task.id] = task
        engine.save()
        engine.pump()
        self.assertEqual(self.wait_done(task, 30), "completed")
        self.assert_file_ok(task)
        self.assertTrue(all("bytes=0-" not in (r or "") for r in self.server.requests),
                        "已完成的分片不该被重新请求")
        print(f"\n  断点续传：只请求缺失部分，共 {self.server.count()} 次，校验通过")

    def test_08_speed_limit(self):
        self.server = RecordingServer(chunk=64 * 1024)
        engine = self.make_engine(speed_limit_kbps=200)
        task = engine.add_task(self.server.url, "slow.bin", len(DATA), connections=1)
        started = time.time()
        self.assertEqual(self.wait_done(task, 30), "completed")
        elapsed = time.time() - started
        self.assertGreater(elapsed, 0.8, "限速没有生效")
        self.assert_file_ok(task)
        print(f"\n  限速 200KB/s：{len(DATA)/1024:.0f}KB 用时 {elapsed:.2f}s")

    def test_09_task_level_retry_then_success(self):
        self.server = RecordingServer(chunk=64 * 1024, fatal_status=503)
        engine = self.make_engine(max_segment_attempts=2)
        task = engine.add_task(self.server.url, "retry.bin", len(DATA))
        deadline = time.time() + 10
        while time.time() < deadline and task.retry_count < 1:
            time.sleep(0.02)
        self.assertGreaterEqual(task.retry_count, 1, "未进入任务级重试")
        self.assertEqual(task.status, "waitingRetry")
        with self.server.lock:
            self.server.options.pop("fatal_status")
        deadline = time.time() + 30
        while time.time() < deadline and task.status != "completed":
            if task.status == "failed":
                break
            time.sleep(0.02)
        self.assertEqual(task.status, "completed", task.error)
        self.assert_file_ok(task)
        print(f"\n  任务级重试：进入等待重试后自动恢复，retry={task.retry_count}")

    def test_10_pause_resume_and_persistence(self):
        self.server = RecordingServer(chunk=16 * 1024)
        engine = self.make_engine()
        task = engine.add_task(self.server.url, "pause.bin", len(DATA))
        time.sleep(0.25)
        self.assertTrue(engine.pause(task.id))
        self.assertEqual(task.status, "paused")
        before = task.received
        self.assertGreater(before, 0)
        engine.save()
        engine.shutdown()

        fresh = Engine(settings=engine.settings, timing=Timing(fast=True))
        self.engine = fresh
        restored = fresh.get(task.id)
        self.assertIsNotNone(restored)
        self.assertEqual(restored.received, before)
        self.assertEqual(restored.status, "paused")
        self.assertEqual(restored.segments, task.segments)
        self.assertTrue(fresh.resume(task.id))
        self.assertEqual(self.wait_done(restored, 30), "completed")
        self.assert_file_ok(restored)
        print(f"\n  暂停/恢复：重启后保留 {before} 字节断点并下完")

    def test_11_remove_task_and_file(self):
        self.server = RecordingServer()
        engine = self.make_engine()
        task = engine.add_task(self.server.url, "remove.bin", 1024)
        path = task.file_path
        self.assertTrue(os.path.exists(path))
        self.assertTrue(engine.remove(task.id, delete_file=True))
        self.assertIsNone(engine.get(task.id))
        self.assertFalse(os.path.exists(path))
        print("\n  删除任务：记录与文件同步清理")

    # ---------- 链接、Cookie、百度解析 ----------

    def test_12_link_parser(self):
        links = parse("见 https://pan.baidu.com/s/1AbCdEf?pwd=1234 提取码:5678，谢谢")
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0].provider, "baidu")
        self.assertEqual(links[0].share_code, "1234")
        self.assertEqual(baidu_surl("https://pan.baidu.com/s/1AbCdEf"), "AbCdEf")
        self.assertEqual(parse("https://example.com/a.pdf")[0].provider, "direct")
        print("\n  链接解析：surl 去 1、提取码、来源识别均正确")

    def test_13_cookie_roundtrip(self):
        save_cookies({"BDUSS": "abc", "STOKEN": "xyz", "undefined": "bad"})
        loaded = load_cookies()
        self.assertEqual(loaded["BDUSS"], "abc")
        self.assertEqual(loaded["STOKEN"], "xyz")
        self.assertNotIn("undefined", loaded)
        text = Path(self.temp.name, "cookies.txt").read_text()
        self.assertIn("\t", text)
        print("\n  Cookie：Netscape 格式写入/读取正确，脏值被过滤")

    def test_14_baidu_resolver_urls(self):
        seen = []

        def fake_json(self, url, method="GET", headers=None, body=None):
            seen.append((url, method, headers or {}, body))
            if "/share/verify" in url:
                return {"errno": 0}
            if "/share/list" in url:
                return {"errno": 0, "share_id": 123, "uk": 456,
                        "list": [{"server_filename": "book.pdf", "size": 1000,
                                  "isdir": 0, "fs_id": 789}]}
            if "gettemplatevariable" in url:
                return {"errno": 0, "result": {"bdstoken": "tok"}}
            if "/api/search" in url:
                return {"errno": 0, "list": []}
            if "/share/transfer" in url:
                return {"errno": 0, "extra": {"list": [
                    {"to": "/来自分享/book", "to_fsid": 999}]}}
            if "/rest/2.0/xpan/file" in url:
                return {"errno": 0, "info": [{"errno": 0, "dlink": "https://d.pcs.baidu.com/x"}]}
            raise AssertionError("意外的请求：" + url)

        resolver = BaiduResolver({"BDUSS": "fake"})
        with mock.patch.object(PanHTTP, "json", fake_json), \
             mock.patch.object(BaiduResolver, "bootstrap", lambda self: None):
            result = resolver.resolve("https://pan.baidu.com/s/1AbCdEf", "1234")

        urls = [item[0] for item in seen]
        self.assertTrue(any("verify?surl=AbCdEf" in url for url in urls))
        self.assertTrue(any("shorturl=AbCdEf" in url for url in urls))
        token_url = next(url for url in urls if "gettemplatevariable" in url)
        self.assertIn("%5B%22sign%22%2C%22timestamp%22%2C%22bdstoken%22%5D", token_url)
        dlink_url = next(url for url in urls if "xpan/file" in url)
        self.assertIn("fsids=%5B999%5D", dlink_url)
        self.assertNotIn("%255B", dlink_url)
        self.assertNotIn("access_token", dlink_url)
        self.assertEqual(result.file_name, "book.pdf")
        self.assertEqual(result.size, 1000)
        self.assertEqual(result.headers["User-Agent"], "pan.baidu.com")
        self.assertIn("BDUSS=fake", result.headers["Cookie"])
        self.assertEqual(result.source_url, "https://pan.baidu.com/s/1AbCdEf")
        print("\n  百度解析链路：verify→list→token→transfer→filemetas 参数全部正确，无二次编码")

    def test_14b_baidu_multi_file_tree(self):
        """多文件分享：递归展开目录树、整树转存、按相对路径对齐、批量 dlink。"""
        seen = []

        def fake_json(http_self, url, method="GET", headers=None, body=None):
            seen.append((url, method, body))
            if "/share/verify" in url:
                return {"errno": 0}
            if "/share/list" in url:
                if "root=1" in url:
                    return {"errno": 0, "share_id": 1, "uk": 2, "list": [
                        {"server_filename": "资料", "isdir": 1, "fs_id": 10,
                         "path": "/我的分享/资料", "size": 0},
                        {"server_filename": "readme.txt", "isdir": 0, "fs_id": 11,
                         "path": "/我的分享/readme.txt", "size": 10},
                    ]}
                return {"errno": 0, "share_id": 1, "uk": 2, "list": [
                    {"server_filename": "a.pdf", "isdir": 0, "fs_id": 12,
                     "path": "/我的分享/资料/a.pdf", "size": 100},
                    {"server_filename": "b.pdf", "isdir": 0, "fs_id": 13,
                     "path": "/我的分享/资料/b.pdf", "size": 200},
                ]}
            if "gettemplatevariable" in url:
                return {"errno": 0, "result": {"bdstoken": "tok"}}
            if "/share/transfer" in url:
                return {"errno": 0, "extra": {"list": []}}
            if "/api/list" in url:
                directory = unquote(url).split("dir=")[1].split("&")[0]
                if directory.endswith("/资料"):
                    return {"errno": 0, "list": [
                        {"server_filename": "a.pdf", "isdir": 0, "fs_id": 22,
                         "path": "/来自分享/我的分享/资料/a.pdf", "size": 100},
                        {"server_filename": "b.pdf", "isdir": 0, "fs_id": 23,
                         "path": "/来自分享/我的分享/资料/b.pdf", "size": 200},
                    ]}
                return {"errno": 0, "list": [
                    {"server_filename": "资料", "isdir": 1, "fs_id": 20,
                     "path": "/来自分享/我的分享/资料", "size": 0},
                    {"server_filename": "readme.txt", "isdir": 0, "fs_id": 21,
                     "path": "/来自分享/我的分享/readme.txt", "size": 10},
                ]}
            if "/rest/2.0/xpan/file" in url:
                ids = unquote(url).split("fsids=[")[1].split("]")[0].split(",")
                return {"errno": 0, "info": [
                    {"errno": 0, "fs_id": int(item), "dlink": f"https://d.pcs.baidu.com/{item}"}
                    for item in ids]}
            raise AssertionError("意外的请求：" + url)

        resolver = BaiduResolver({"BDUSS": "fake"})
        with mock.patch.object(PanHTTP, "json", fake_json), \
             mock.patch.object(BaiduResolver, "bootstrap", lambda self: None):
            results = resolver.resolve_all("https://pan.baidu.com/s/1AbCdEf", "1234")

        self.assertEqual(len(results), 3)
        by_name = {item.file_name: item for item in results}
        self.assertEqual(by_name["readme.txt"].relative_path, "我的分享/readme.txt")
        self.assertEqual(by_name["a.pdf"].relative_path, "我的分享/资料/a.pdf")
        self.assertEqual(by_name["b.pdf"].relative_path, "我的分享/资料/b.pdf")
        self.assertEqual(by_name["readme.txt"].pan_fs_id, "21")
        self.assertEqual(by_name["a.pdf"].pan_fs_id, "22")
        self.assertEqual(by_name["a.pdf"].size, 100)

        # 转存：顶层目录+文件一批传，fsidlist 不做二次编码，path 保留目录结构
        transfer_calls = [(url, body.decode() if body else "")
                          for url, method, body in seen if url and "/share/transfer" in url]
        self.assertEqual(len(transfer_calls), 1)
        self.assertIn("fsidlist=%5B10,11%5D", transfer_calls[0][1])
        self.assertIn("path=/%E6%9D%A5%E8%87%AA%E5%88%86%E4%BA%AB/", transfer_calls[0][1])

        # 批量 dlink：一次请求带全部 3 个 fs_id
        dlink_urls = [url for url, _, _ in seen if "/rest/2.0/xpan/file" in url]
        self.assertEqual(len(dlink_urls), 1)
        self.assertIn("fsids=%5B21,22,23%5D", dlink_urls[0])
        self.assertNotIn("%255B", dlink_urls[0])
        print("\n  百度多文件：递归展开 3 文件、整树转存一批、相对路径对齐、批量 dlink")

    def test_14c_multi_file_task_roundtrip(self):
        """多文件任务：子目录落盘 + pan_fs_id 持久化往返。"""
        engine = self.make_engine()
        sub_dir = os.path.join(engine.settings["download_directory"], "我的分享", "sub")
        task = engine.add_task("https://d.pcs.baidu.com/x", "a.pdf", 100,
                               directory=sub_dir, pan_fs_id="22")
        self.assertEqual(task.pan_fs_id, "22")
        self.assertTrue(os.path.isdir(sub_dir))
        restored = Task.from_dict(task.to_dict())
        self.assertEqual(restored.pan_fs_id, "22")
        self.assertEqual(restored.file_path, os.path.join(sub_dir, "a.pdf"))
        print("\n  多文件任务：子目录创建与 pan_fs_id 持久化往返正确")

    def test_14d_refresh_dlink_by_pan_fs_id(self):
        """直链过期刷新：带 pan_fs_id 的任务按网盘文件重取，不再依赖分享重解析。"""

        def fake_json(http_self, url, method="GET", headers=None, body=None):
            if "gettemplatevariable" in url:
                return {"errno": 0, "result": {"bdstoken": "tok"}}
            if "/rest/2.0/xpan/file" in url:
                self.assertIn("fsids=%5B999%5D", url)
                return {"errno": 0, "info": [
                    {"errno": 0, "fs_id": 999, "dlink": "https://d.pcs.baidu.com/new"}]}
            raise AssertionError("意外的请求：" + url)

        resolver = BaiduResolver({"BDUSS": "fake"})
        with mock.patch.object(PanHTTP, "json", fake_json):
            url = resolver.refresh_dlink("999")
        self.assertEqual(url, "https://d.pcs.baidu.com/new")
        headers = resolver.download_headers()
        self.assertEqual(headers["User-Agent"], "pan.baidu.com")
        print("\n  直链刷新：按 pan_fs_id 重取 dlink 与请求头正确")

    # ---------- Web 与 CLI ----------

    def test_15_web_api(self):
        self.server = RecordingServer()
        engine = self.make_engine()
        app = WebApp(engine, port=0)
        app.start()
        try:
            base = f"http://127.0.0.1:{app.port}"

            def request(path, body=None):
                data = json.dumps(body).encode() if body is not None else None
                req = urllib.request.Request(base + path, data=data,
                                             headers={"Content-Type": "application/json"},
                                             method="POST" if data else "GET")
                with urllib.request.urlopen(req, timeout=10) as response:
                    return json.loads(response.read().decode())

            state = request("/api/state")
            self.assertEqual(state["version"], __version__)
            added = request("/api/tasks", {"link": self.server.url, "code": ""})
            self.assertTrue(added["ok"])
            self.assertEqual(added["added"], 1)
            state = request("/api/state")
            self.assertEqual(len(state["tasks"]), 1)
            task_id = state["tasks"][0]["id"]
            self.assertIn("progress", state["tasks"][0])
            self.assertTrue(request("/api/settings", {"connections": 2})["ok"])
            self.assertEqual(request("/api/state")["settings"]["connections"], 2)
            self.assertTrue(request(f"/api/tasks/{task_id}/pause", {})["ok"])
            self.assertTrue(request(f"/api/tasks/{task_id}/resume", {})["ok"])
            self.assertTrue(request(f"/api/tasks/{task_id}/rm", {})["ok"])
            self.assertEqual(len(request("/api/state")["tasks"]), 0)
            print(f"\n  Web API：state/add/settings/pause/resume/delete 全部通过")
        finally:
            app.stop()

    def test_16_cli_subprocess(self):
        env = dict(os.environ, YUNX_CONFIG_DIR=self.temp.name)
        output = subprocess.run([sys.executable, str(ROOT / "yunx.py"), "--version"],
                                capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(output.returncode, 0)
        self.assertIn(__version__, output.stdout)
        output = subprocess.run([sys.executable, str(ROOT / "yunx.py"), "ls", "--json"],
                                capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(output.returncode, 0)
        self.assertEqual(json.loads(output.stdout), [])
        print("\n  CLI：--version / ls --json 子进程调用通过")


if __name__ == "__main__":
    unittest.main(verbosity=2)
