"""下载引擎：分片、断点续传、限速、空响应识别与自动重试。

设计要点（与 Mac 版 v1.3.0 对齐）：
- 每个分片独立线程，用 os.pwrite 写各自区间，互不争抢文件游标。
- 新建连接强制间隔（默认 0.4s），把开局那一波并发打散，避免一上来就踩限流。
- 百度限流回的是 206 + 0 字节，不是 429。空响应单独计数，绝不消耗 30 次重连额度。
- 退避是"到期时间戳"，不是 sleep；一个分片等待不会拖住其余分片。
- 有进展的连接几乎不退避（0.25s），否则串行时每段都白等。
- 连接超时即僵死判定（默认 60s），到期自动重连。
"""

from __future__ import annotations

import math
import os
import random
import socket
import threading
import time
from typing import Callable, Dict, List, Optional

from . import config
from .http_client import HttpClient, StatusError, parse_content_range
from .models import (ACTIVE_STATUSES, CANCELLED, COMPLETED, FAILED, PAUSED,
                     QUEUED, RUNNING, WAITING_RETRY, Segment, Task,
                     make_segments, new_task_id)

TRANSIENT_STATUS = {408, 425, 429, 500, 502, 503, 504}
FATAL_STATUS = {401, 403, 404, 410, 416}


class Timing:
    """所有等待时间集中在这里，测试时用 fast=True 等比缩小。"""

    def __init__(self, fast: bool = False):
        self.fast = fast
        self.backoff_base = 0.1 if fast else 1.0
        self.backoff_cap = 1.0 if fast else 30.0
        self.empty_base = 0.2 if fast else 30.0
        self.empty_cap = 2.0 if fast else 180.0
        self.progress_backoff = 0.01 if fast else 0.25
        self.spawn_interval = 0.01 if fast else 0.4
        self.stall_timeout = 2.0 if fast else 60.0
        self.ramp_step = 64 * 1024 if fast else 4 * 1024 * 1024
        self.task_retry_base = 0.1 if fast else 2.0
        self.task_retry_cap = 0.5 if fast else 300.0
        self.poll_interval = 0.01 if fast else 0.1
        self.monitor_interval = 0.05 if fast else 0.5
        self.save_interval = 0.2 if fast else 2.0
        self.speed_interval = 0.2 if fast else 0.5
        self.http_timeout = 3.0 if fast else 30.0


class RateLimiter:
    """令牌桶限速；�ait 可被停止事件打断。"""

    def __init__(self, rate: int = 0):
        self.rate = max(0, int(rate))
        self.tokens = float(self.rate)
        self.updated = time.monotonic()
        self.lock = threading.Lock()

    def set_rate(self, rate: int) -> None:
        with self.lock:
            self.rate = max(0, int(rate))
            self.tokens = float(min(self.tokens, self.rate))

    def acquire(self, size: int, stop: threading.Event) -> bool:
        if self.rate <= 0:
            return True
        while size > 0:
            with self.lock:
                now = time.monotonic()
                self.tokens = min(float(self.rate),
                                  self.tokens + (now - self.updated) * self.rate)
                self.updated = now
                if self.tokens >= size:
                    self.tokens -= size
                    return True
                delay = (size - self.tokens) / self.rate
            if stop.wait(min(delay, 0.5)):
                return False
        return True


class Engine:
    def __init__(self, settings: Optional[dict] = None, timing: Optional[Timing] = None,
                 logger: Optional[Callable[[str], None]] = None):
        self.settings = dict(settings or config.load_settings())
        # 路径在初始化时定死：长驻线程的 monitor 不应受进程环境后续变化影响
        self.tasks_path = config.tasks_file()
        self.timing = timing or Timing(fast=bool(os.environ.get("YUNX_TEST_FAST")))
        self.logger = logger or (lambda message: None)
        self.lock = threading.RLock()
        self.tasks: Dict[str, Task] = {}
        self.runners: Dict[str, "_TaskRunner"] = {}
        self.listeners: List[Callable[[str, dict], None]] = []
        self.rate = RateLimiter()
        self.stop = threading.Event()
        self.monitor: Optional[threading.Thread] = None
        self._last_received: Dict[str, int] = {}
        self._last_speed_at = time.monotonic()
        self._last_saved_at = 0.0
        self.load()

    # ---------- 生命周期 ----------

    def start(self) -> None:
        if self.monitor and self.monitor.is_alive():
            return
        self.stop.clear()
        self.monitor = threading.Thread(target=self._monitor_loop, name="yunx-monitor", daemon=True)
        self.monitor.start()
        self.pump()

    def shutdown(self) -> None:
        self.logger("正在停止下载引擎…")
        for runner in list(self.runners.values()):
            runner.stop.set()
        self.stop.set()
        for runner in list(self.runners.values()):
            runner.request_join(3.0)
        self.save()
        self.logger("引擎已停止")

    # ---------- 任务管理 ----------

    def load(self) -> None:
        raw = config.read_json(self.tasks_path, [])
        if not isinstance(raw, list):
            raw = []
        with self.lock:
            self.tasks = {}
            for item in raw:
                if not isinstance(item, dict) or not item.get("id"):
                    continue
                try:
                    task = Task.from_dict(item)
                except Exception as exc:
                    self.logger(f"跳过损坏的任务记录 {item.get('id')}: {exc}")
                    continue
                self.tasks[task.id] = task

    def save(self) -> None:
        with self.lock:
            payload = [task.to_dict() for task in self.tasks.values()]
        config.atomic_write_json(self.tasks_path, payload)
        self._last_saved_at = time.monotonic()

    def all_tasks(self) -> List[Task]:
        with self.lock:
            return list(self.tasks.values())

    def get(self, task_id: str) -> Optional[Task]:
        with self.lock:
            return self.tasks.get(task_id)

    def add_task(
        self,
        url: str,
        file_name: str,
        total_size: int,
        directory: Optional[str] = None,
        headers: Optional[dict] = None,
        source_url: Optional[str] = None,
        share_code: Optional[str] = None,
        provider: str = "direct",
        note: Optional[str] = None,
        pan_fs_id: Optional[str] = None,
        supports_range: bool = True,
        connections: Optional[int] = None,
    ) -> Task:
        directory = directory or str(self.settings.get("download_directory"))
        os.makedirs(directory, exist_ok=True)
        task = Task(
            id=new_task_id(),
            url=url,
            file_name=file_name,
            directory=directory,
            total_size=max(0, int(total_size)),
            request_headers=dict(headers or {}),
            status=QUEUED,
            source_url=source_url,
            share_code=share_code,
            provider=provider,
            note=note,
            pan_fs_id=pan_fs_id,
            supports_range=supports_range,
            connections=int(connections or self.settings.get("connections") or 8),
            speed_limit_bps=int(self.settings.get("speed_limit_kbps") or 0) * 1024,
            auto_retry=bool(self.settings.get("auto_retry", True)),
        )
        task.segments = make_segments(task.total_size, task.connections) if supports_range else [
            Segment(0, max(0, task.total_size - 1), 0)
        ]
        self._prepare_file(task)
        with self.lock:
            self.tasks[task.id] = task
        self.save()
        self.pump()
        self._notify("added", {"id": task.id})
        return task

    def _prepare_file(self, task: Task) -> None:
        os.makedirs(task.directory, exist_ok=True)
        fd = os.open(task.file_path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            if os.fstat(fd).st_size != task.total_size:
                os.ftruncate(fd, task.total_size)
        finally:
            os.close(fd)

    def pause(self, task_id: str) -> bool:
        task = self.get(task_id)
        if not task or task.status in (COMPLETED, CANCELLED, FAILED):
            return False
        runner = self.runners.get(task_id)
        if runner:
            runner.stop.set()
            runner.request_join(2.0)
        task.status = PAUSED
        task.speed = 0
        self.save()
        self._notify("paused", {"id": task_id})
        return True

    def resume(self, task_id: str, start: bool = True) -> bool:
        task = self.get(task_id)
        if not task or task.status in (COMPLETED, CANCELLED):
            return False
        task.status = QUEUED
        task.error = None
        task.next_retry_at = 0
        self.save()
        if start:
            self.pump()
        self._notify("resumed", {"id": task_id})
        return True

    def retry_now(self, task_id: str, start: bool = True) -> bool:
        task = self.get(task_id)
        if not task or task.status not in (WAITING_RETRY, FAILED, PAUSED):
            return False
        task.retry_count = 0 if task.status == FAILED else task.retry_count
        task.next_retry_at = 0
        task.status = QUEUED
        task.error = None
        self.save()
        if start:
            self.pump()
        return True

    def remove(self, task_id: str, delete_file: bool = False) -> bool:
        task = self.get(task_id)
        if not task:
            return False
        runner = self.runners.get(task_id)
        if runner:
            runner.stop.set()
            runner.request_join(2.0)
        with self.lock:
            self.tasks.pop(task_id, None)
        if delete_file:
            try:
                os.unlink(task.file_path)
            except OSError:
                pass
        self.save()
        self._notify("removed", {"id": task_id})
        return True

    def update_settings(self, values: dict) -> dict:
        for key in ("download_directory", "connections", "speed_limit_kbps", "auto_retry",
                    "max_segment_attempts", "max_empty_responses", "stall_timeout",
                    "web_port", "web_bind"):
            if key in values:
                self.settings[key] = values[key]
        config.save_settings(self.settings)
        self.rate.set_rate(int(self.settings.get("speed_limit_kbps") or 0) * 1024)
        return dict(self.settings)

    # ---------- 内部：调度 ----------

    def pump(self) -> None:
        with self.lock:
            pending = [task for task in self.tasks.values()
                       if task.status in (QUEUED, RUNNING) and task.id not in self.runners]
        for task in pending:
            task.status = RUNNING
            runner = _TaskRunner(self, task)
            self.runners[task.id] = runner
            runner.start()

    def _monitor_loop(self) -> None:
        while not self.stop.wait(self.timing.monitor_interval):
            now = time.monotonic()
            # 速度采样
            if now - self._last_speed_at >= self.timing.speed_interval:
                elapsed = now - self._last_speed_at
                for task in self.all_tasks():
                    current = task.received
                    previous = self._last_received.get(task.id, current)
                    task.speed = max(0, current - previous) / elapsed if task.status == RUNNING else 0
                    self._last_received[task.id] = current
                self._last_speed_at = now
            # 等待重试的任务到点后自动续跑
            due = []
            with self.lock:
                for task in self.tasks.values():
                    if (task.status == WAITING_RETRY and task.auto_retry and
                            time.time() >= task.next_retry_at):
                        task.status = QUEUED
                        task.next_retry_at = 0
                        due.append(task.id)
            if due:
                for task_id in due:
                    self._notify("retry", {"id": task_id, "attempt": (self.get(task_id).retry_count
                                                                       if self.get(task_id) else 0)})
                self.pump()
            if now - self._last_saved_at >= self.timing.save_interval:
                try:
                    self.save()
                except OSError as exc:
                    self.logger(f"保存任务状态失败：{exc}")

    def on_change(self, callback: Callable[[str, dict], None]) -> None:
        self.listeners.append(callback)

    def _notify(self, event: str, payload: dict) -> None:
        for listener in list(self.listeners):
            try:
                listener(event, payload)
            except Exception:
                pass

    def _log(self, task: Task, message: str) -> None:
        self.logger(f"[{task.file_name}] {message}")


class _TaskRunner(threading.Thread):
    """一个任务一个调度线程：挑分片、控并发、处理重试结果。"""

    def __init__(self, engine: Engine, task: Task):
        super().__init__(name=f"yunx-runner-{task.id[:8]}", daemon=True)
        self.engine = engine
        self.task = task
        self.timing = engine.timing
        self.stop = threading.Event()
        self.active: Dict[int, "_SegmentAttempt"] = {}
        self.retry_after: Dict[int, float] = {}
        self.attempts: Dict[int, int] = {}
        self.empty_counts: Dict[int, int] = {}
        self.empty_total = 0
        self.ceiling = max(1, int(task.connections or 8))
        self.bytes_since_ramp = 0
        self.spawn_gate = 0.0
        self.fd: Optional[int] = None
        self.last_data_at = time.monotonic()
        self.has_empty_history = False
        self.local_limiter = RateLimiter(task.speed_limit_bps)

    def request_join(self, timeout: float) -> None:
        self.join(timeout=min(timeout, 2.0))

    def report_progress(self, size: int) -> None:
        self.last_data_at = time.monotonic()
        self.bytes_since_ramp += size
        if self.has_empty_history and self.bytes_since_ramp >= self.timing.ramp_step:
            if self.ceiling < max(1, self.task.connections):
                self.ceiling += 1
                self.engine._log(self.task, f"限流解除，并发恢复到 {self.ceiling}")
            self.bytes_since_ramp = 0

    # ---------- 主循环 ----------

    def run(self) -> None:
        try:
            self.fd = os.open(self.task.file_path, os.O_RDWR)
            while not self.stop.is_set():
                if self.task.status not in (RUNNING, QUEUED):
                    break
                self._reap()
                if self._all_done():
                    self._complete()
                    break
                now = time.monotonic()
                if len(self.active) < self.ceiling and now >= self.spawn_gate:
                    index = self._next_index(now)
                    if index is not None:
                        self._spawn(index, now)
                self.stop.wait(self.timing.poll_interval)
        except Exception as exc:
            self._fail(f"下载线程异常：{exc}")
        finally:
            for attempt in list(self.active.values()):
                attempt.stop.set()
            if self.fd is not None:
                try:
                    os.fsync(self.fd)
                    os.close(self.fd)
                except OSError:
                    pass
            self.engine.runners.pop(self.task.id, None)

    def _all_done(self) -> bool:
        return bool(self.task.segments) and all(segment.done for segment in self.task.segments)

    def _next_index(self, now: float) -> Optional[int]:
        candidates = []
        for index, segment in enumerate(self.task.segments):
            if segment.done or index in self.active:
                continue
            if now < self.retry_after.get(index, 0):
                continue
            candidates.append(index)
        if not candidates:
            return None
        # 优先补最靠前的未完成分片，避免长期只啃一个分片
        return min(candidates)

    def _spawn(self, index: int, now: float) -> None:
        segment = self.task.segments[index]
        offset = segment.next_offset
        attempt = _SegmentAttempt(self, index, offset, self.fd)
        self.active[index] = attempt
        attempt.start()
        self.spawn_gate = now + self.timing.spawn_interval

    def _reap(self) -> None:
        for index, attempt in list(self.active.items()):
            if attempt.is_alive():
                continue
            self.active.pop(index, None)
            kind = attempt.kind
            got = attempt.received_delta

            if kind == "done":
                self.retry_after.pop(index, None)
                self.attempts[index] = 0
                self.empty_counts[index] = 0
                continue

            if kind == "range_ignored":
                # 服务器无视 Range：退回单连接从头下，其余线程全部停掉
                for other in list(self.active.values()):
                    other.stop.set()
                self._reset_single_segment()
                return

            if kind == "fatal":
                if attempt.status == 403 and self._try_refresh_dlink():
                    self.retry_after[index] = time.monotonic() + self.timing.progress_backoff
                    continue
                self._fail(attempt.error or f"服务器返回 {attempt.status}")
                return

            if kind == "empty":
                self.empty_counts[index] = self.empty_counts.get(index, 0) + 1
                self.empty_total += 1
                self.has_empty_history = True
                count = self.empty_counts[index]
                self.engine._log(self.task, f"分片 {index} 收到空响应（第 {count} 次），判定为限流")
                if self.empty_counts[index] > int(self.engine.settings.get("max_empty_responses", 80)):
                    self._exhaust(f"连续 {count} 次空响应，疑似长时间限流")
                    return
                if self.empty_counts[index] >= 2:
                    self.ceiling = 1   # 直接压到 1，逐次减半只会多触发几轮
                delay = self.timing.empty_base * min(1.7 ** (count - 1),
                                                     self.timing.empty_cap / self.timing.empty_base)
                delay += random.uniform(0, delay * 0.15)
                self.retry_after[index] = time.monotonic() + min(delay, self.timing.empty_cap)
                continue

            # progress / transient
            if got > 0:
                self.attempts[index] = 0
                self.empty_counts[index] = 0
                delay = self.timing.progress_backoff
            else:
                self.attempts[index] = self.attempts.get(index, 0) + 1
                if self.attempts[index] > int(self.engine.settings.get("max_segment_attempts", 30)):
                    self._exhaust(f"分片 {index} 连续中断 {self.attempts[index]} 次")
                    return
                delay = min(self.timing.backoff_base *
                            max(1, 1.9 ** max(0, self.attempts[index] - 2)),
                            self.timing.backoff_cap)
                delay += random.uniform(0, 1.2 if not self.timing.fast else 0.1)
            self.retry_after[index] = time.monotonic() + delay

    def _reset_single_segment(self) -> None:
        """Range 被忽略时回到单段重下；文件会被截断。"""
        for attempt in list(self.active.values()):
            attempt.join(1.0)
        self.task.supports_range = False
        self.task.segments = [Segment(0, max(0, self.task.total_size - 1), 0)]
        try:
            os.ftruncate(self.fd, 0)
            os.ftruncate(self.fd, self.task.total_size)
            os.fsync(self.fd)
        except OSError as exc:
            self._fail(f"无法重置下载文件：{exc}")
            return
        self.active.clear()
        self.retry_after.clear()
        self.attempts.clear()
        self.empty_counts.clear()
        self.ceiling = 1
        self.engine._log(self.task, "服务器不支持 Range，已降级为单连接重新下载")
        self.engine.save()

    def _try_refresh_dlink(self) -> bool:
        """直链过期（403）时重新解析。多文件任务记录了网盘内 fs_id，
        直接按它重取，不会拿到分享里别的文件的直链。"""
        if not self.task.source_url or self.task.provider != "baidu":
            return False
        try:
            from .baidu import BaiduResolver
            from .cookiestore import load_cookies
            resolver = BaiduResolver(load_cookies())
            if self.task.pan_fs_id:
                self.task.url = resolver.refresh_dlink(self.task.pan_fs_id)
                self.task.request_headers = resolver.download_headers()
                self.engine._log(self.task, "直链已过期，已按网盘文件重新解析")
            else:
                resolved = resolver.resolve(self.task.source_url, self.task.share_code)
                self.task.url = resolved.url
                self.task.request_headers = dict(resolved.headers)
                self.task.total_size = resolved.size or self.task.total_size
                self.engine._log(self.task, "直链已过期，已自动重新解析")
            self.engine._prepare_file(self.task)
            self.engine.save()
            return True
        except Exception as exc:
            self.engine._log(self.task, f"重新解析直链失败：{exc}")
            return False

    def _exhaust(self, reason: str) -> None:
        self.stop.set()
        for attempt in list(self.active.values()):
            attempt.stop.set()
        task = self.task
        if not task.auto_retry:
            self._fail(reason)
            return
        task.retry_count += 1
        task.status = WAITING_RETRY
        task.error = reason
        delay = min(self.timing.task_retry_base * (2 ** min(task.retry_count - 1, 20)),
                    self.timing.task_retry_cap)
        task.next_retry_at = time.time() + delay
        for index in range(len(task.segments)):
            self.attempts[index] = 0
            self.empty_counts[index] = 0
            self.retry_after[index] = 0
        self.engine._log(task, f"{reason}，{delay:.0f} 秒后自动重试（第 {task.retry_count} 次）")
        self.engine._notify("waiting", {"id": task.id, "seconds": delay,
                                        "attempt": task.retry_count})
        self.engine.save()

    def _complete(self) -> None:
        task = self.task
        os.fsync(self.fd)
        task.status = COMPLETED
        task.completed_at = time.time()
        task.error = None
        task.speed = 0
        self.engine._log(task, "下载完成")
        self.engine._notify("completed", {"id": task.id})
        self.engine.save()

    def _fail(self, reason: str) -> None:
        self.stop.set()
        self.task.status = FAILED
        self.task.error = reason
        self.task.speed = 0
        self.engine._log(self.task, f"失败：{reason}")
        self.engine._notify("failed", {"id": self.task.id, "error": reason})
        self.engine.save()


class _SegmentAttempt(threading.Thread):
    """一条连接只负责一个分片的一段，结束即退出，由调度线程决定是否重连。"""

    def __init__(self, runner: _TaskRunner, index: int, offset: int, fd: int):
        super().__init__(name=f"yunx-seg-{runner.task.id[:8]}-{index}", daemon=True)
        self.runner = runner
        self.task = runner.task
        self.index = index
        self.offset = offset
        self.fd = fd
        self.stop = threading.Event()
        self.kind = "transient"
        self.status: Optional[int] = None
        self.error: Optional[str] = None
        self.received_delta = 0

    def run(self) -> None:
        segment = self.task.segments[self.index]
        if self.offset > segment.end:
            self.kind = "done"
            return
        headers = dict(self.task.request_headers)
        headers["Range"] = f"bytes={self.offset}-{segment.end}"
        client = HttpClient(timeout=self.runner.timing.stall_timeout)
        response = None
        got = 0
        try:
            response = client.request(self.task.url, "GET", headers)
            self.status = response.status
            if response.status in FATAL_STATUS:
                self.kind = "fatal"
                self.error = f"服务器返回 {response.status}"
                return
            if response.status in TRANSIENT_STATUS:
                self.kind = "transient"
                return
            if response.status != 206:
                # 服务器无视 Range 时回的是完整文件，此时继续按分片写会错位
                if self.offset > 0 or (len(self.task.segments) > 1 and
                                       self.task.total_size > segment.length):
                    self.kind = "range_ignored"
                    return
                if response.status >= 400:
                    self.kind = "transient"
                    return
            else:
                parsed = parse_content_range(response.get("Content-Range"))
                if parsed and parsed[0] != self.offset:
                    # 服务器自己调整了起点，按断线重连处理，避免写到错误偏移
                    self.kind = "transient"
                    return

            limiter = (self.runner.local_limiter if self.runner.local_limiter.rate > 0
                       else self.runner.engine.rate)
            chunk_size = 64 * 1024
            needed = segment.end - self.offset + 1
            while not self.stop.is_set() and got < needed:
                chunk = response.read(min(chunk_size, needed - got))
                if not chunk:
                    break
                if not limiter.acquire(len(chunk), self.stop):
                    break
                os.pwrite(self.fd, chunk, self.offset + got)
                got += len(chunk)
                with self.task.lock:
                    segment.received += len(chunk)
                self.runner.report_progress(len(chunk))
            self.received_delta = got
            if segment.done:
                self.kind = "done"
            elif got > 0:
                self.kind = "progress"
            else:
                self.kind = "empty"
        except (socket.timeout, TimeoutError):
            self.received_delta = got
            self.kind = "progress" if got > 0 else "transient"
        except Exception as exc:
            # 网络中断、连接重置、服务器提前关闭都走这里
            self.received_delta = got
            self.error = str(exc)
            self.kind = "progress" if got > 0 else "transient"
        finally:
            if response is not None:
                response.close()
