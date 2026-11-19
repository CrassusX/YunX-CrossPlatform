"""YunX Linux 命令行入口。"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from urllib.parse import urlsplit, unquote

from . import __version__, config, cookiestore
from .baidu import BaiduResolver, PanError
from .engine import Engine, Timing
from .http_client import HttpClient, HttpError, parse_content_range
from .linkparser import parse as parse_links
from .models import STATUS_LABELS


def fmt_size(value: float) -> str:
    value = float(value or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def fmt_speed(value: float) -> str:
    return f"{fmt_size(value)}/s" if value else "—"


def fmt_time(value) -> str:
    if not value:
        return "—"
    return time.strftime("%m-%d %H:%M", time.localtime(float(value)))


def progress_bar(ratio: float, width: int = 20) -> str:
    filled = int(max(0, min(1, ratio)) * width)
    return "█" * filled + "░" * (width - filled)


# ---------- 直链探测 ----------

def probe_direct(url: str):
    client = HttpClient(timeout=20)
    response = client.request(url, "GET", {"Range": "bytes=0-0"})
    try:
        content_range = parse_content_range(response.get("Content-Range"))
        if content_range and content_range[2] > 0:
            total, supports_range = content_range[2], True
        else:
            length = response.get("Content-Length")
            total, supports_range = (int(length) if length and length.isdigit() else 0), False
        disposition = response.get("Content-Disposition") or ""
        name = ""
        if "filename*=UTF-8''" in disposition:
            name = unquote(disposition.split("filename*=UTF-8''", 1)[1].split(";", 1)[0])
        elif "filename=" in disposition:
            name = disposition.split("filename=", 1)[1].strip().strip('"')
        name = os.path.basename(name) if name else os.path.basename(urlsplit(url).path)
        return name or "download", total, supports_range
    finally:
        response.close()


# ---------- 命令 ----------

def cmd_login(args) -> int:
    if args.firefox:
        cookies = cookiestore.from_firefox()
        if not cookiestore.has_login(cookies):
            print("Firefox 里没有找到百度登录态，请先在浏览器登录 pan.baidu.com", file=sys.stderr)
            return 1
        cookiestore.save_cookies(cookies)
        print("已从 Firefox 导入百度登录态")
        return 0
    if args.status:
        state = cookiestore.login_status()
        print(f"{state['state']}: {state['message']}")
        return 0
    if args.headless_driver:
        print("提示：无头模式下无法扫码，只能使用账号密码登录。")
    try:
        cookiestore.login_auto(timeout=args.timeout, headless=args.headless_driver,
                               on_status=lambda text: print(text, flush=True))
        print(f"登录成功，凭证已保存到 {config.cookies_file()}")
        return 0
    except Exception as exc:
        print(f"登录失败：{exc}", file=sys.stderr)
        return 1


def add_links(text: str, code: str = None, directory: str = None,
              name: str = None, engine=None):
    """添加一条或多条链接；返回 (engine, [(task, note)])，失败时抛异常。"""
    links = parse_links(text)
    if not links:
        raise PanError("没有识别到链接")
    engine = engine or Engine()
    cookies = cookiestore.load_cookies()
    added = []
    for link in links:
        if link.provider == "baidu":
            if not cookiestore.has_login(cookies):
                raise PanError("尚未登录百度，请先执行 yunx login")
            resolved_list = BaiduResolver(cookies).resolve_all(
                link.raw, code or link.share_code)
            for index, resolved in enumerate(resolved_list):
                # 多文件分享保持目录结构：相对路径落到下载目录（或用户指定目录）的子目录里
                task_directory = directory
                if resolved.relative_path:
                    parent = os.path.dirname(resolved.relative_path)
                    if parent:
                        base = directory or str(engine.settings.get("download_directory"))
                        task_directory = os.path.join(base, parent)
                # 总结性说明只挂在第一个任务上，避免每行都重复
                note = resolved.note if index == 0 else None
                task = engine.add_task(
                    url=resolved.url, file_name=resolved.file_name,
                    total_size=resolved.size, directory=task_directory,
                    headers=resolved.headers, source_url=resolved.source_url,
                    share_code=resolved.share_code, provider="baidu",
                    note=note, pan_fs_id=resolved.pan_fs_id,
                )
                added.append((task, note))
        elif link.provider == "direct":
            direct_name, size, support_range = probe_direct(link.raw)
            task = engine.add_task(
                url=link.raw, file_name=name or direct_name, total_size=size,
                directory=directory, supports_range=support_range,
            )
            added.append((task, None))
        else:
            raise PanError(f"暂不支持的来源：{link.provider}（目前支持百度分享与直链）")
    return engine, added


def cmd_add(args) -> int:
    try:
        engine, added = add_links(args.link, args.code, args.directory, args.name)
    except Exception as exc:
        print(f"添加失败：{exc}", file=sys.stderr)
        return 1
    for task, note in added:
        print(f"已加入任务 {task.id[:8]}  {task.file_name}  ({fmt_size(task.total_size)})")
        if note:
            print("  " + note)
    return 0


def cmd_ls(args) -> int:
    engine = Engine()
    tasks = engine.all_tasks()
    if args.json:
        print(json.dumps([task.to_dict() for task in tasks], ensure_ascii=False, indent=2))
        return 0
    if not tasks:
        print("还没有任务。用 yunx add <链接> 添加。")
        return 0
    print(f"{'ID':<10} {'状态':<10} {'进度':<24} {'大小':>10} {'速度':>12}  文件名")
    for task in tasks:
        extra = ""
        if task.status == "waitingRetry":
            left = max(0, task.next_retry_at - time.time())
            extra = f" ({task.retry_count} 次，{left:.0f}s 后)"
        elif task.error:
            extra = " " + str(task.error)[:40]
        print(f"{task.id[:8]:<10} {task.status_label + extra:<10} "
              f"{progress_bar(task.progress):<24} {fmt_size(task.received)+'/'+fmt_size(task.total_size):>10} "
              f"{fmt_speed(task.speed):>12}  {task.file_name}")
    return 0


def cmd_run(args) -> int:
    engine = Engine()
    engine.start()
    running = [task for task in engine.all_tasks() if task.status in ("paused", "failed")]
    if running and not args.no_auto_resume:
        for task in running:
            engine.resume(task.id)
        print(f"已自动续传 {len(running)} 个未完成任务")
    print(f"下载引擎已启动，配置目录 {config.config_dir()}")
    if args.web:
        from .web import WebApp
        app = WebApp(engine, port=args.port or int(engine.settings.get("web_port", 8899)),
                     bind=args.bind or engine.settings.get("web_bind", "127.0.0.1"))
        print(f"网页面板：http://{app.bind}:{app.port}")
        app.run_forever()
    else:
        print("按 Ctrl-C 退出（任务会保存断点）")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print()
    engine.shutdown()
    return 0


def _find_task(engine: Engine, key: str):
    direct = engine.get(key)
    if direct:
        return direct
    matches = [task for task in engine.all_tasks() if task.id.startswith(key)]
    return matches[0] if len(matches) == 1 else None


def cmd_pause(args) -> int:
    engine = Engine()
    targets = engine.all_tasks() if args.task_id == "all" else [_find_task(engine, args.task_id)]
    count = 0
    for task in targets:
        if task and engine.pause(task.id):
            count += 1
    print(f"已暂停 {count} 个任务")
    return 0 if count else 1


def cmd_resume(args) -> int:
    engine = Engine()
    targets = engine.all_tasks() if args.task_id == "all" else [_find_task(engine, args.task_id)]
    count = 0
    for task in targets:
        if task and engine.resume(task.id, start=False):
            count += 1
    print(f"已标记继续 {count} 个任务，运行 yunx run 后生效")
    return 0 if count else 1


def cmd_rm(args) -> int:
    engine = Engine()
    task = _find_task(engine, args.task_id)
    ok = engine.remove(task.id, delete_file=args.delete_file) if task else False
    print("已删除任务" if ok else "找不到该任务")
    return 0 if ok else 1


def cmd_settings(args) -> int:
    engine = Engine()
    updates = {}
    if args.directory is not None:
        updates["download_directory"] = os.path.abspath(os.path.expanduser(args.directory))
    if args.connections is not None:
        updates["connections"] = max(1, min(32, args.connections))
    if args.speed is not None:
        updates["speed_limit_kbps"] = max(0, args.speed)
    if args.auto_retry is not None:
        updates["auto_retry"] = args.auto_retry == "on"
    if updates:
        settings = engine.update_settings(updates)
    else:
        settings = engine.settings
    print(json.dumps(settings, ensure_ascii=False, indent=2))
    return 0


def cmd_clean(args) -> int:
    cookies = cookiestore.load_cookies()
    if not cookiestore.has_login(cookies):
        print("尚未登录百度", file=sys.stderr)
        return 1
    BaiduResolver(cookies).clean_transferred()
    print("已请求清理网盘中的 /来自分享 目录")
    return 0


def cmd_doctor(args) -> int:
    print(f"YunX Linux {__version__}")
    print(f"  Python      {sys.version.split()[0]}  ({sys.executable})")
    print(f"  配置目录    {config.config_dir()}")
    print(f"  任务记录    {config.tasks_file()}  "
          f"{'存在' if config.tasks_file().exists() else '尚未创建'}")
    print(f"  百度登录    {'已保存' if cookiestore.has_login() else '未登录'}")
    for name in ("chromedriver", "geckodriver", "chromium-driver"):
        path = shutil.which(name)
        if path:
            print(f"  浏览器驱动  {name} -> {path}")
    if not any(shutil.which(name) for name in ("chromedriver", "geckodriver", "chromium-driver")):
        print("  浏览器驱动  未安装（自动登录不可用，可用 --firefox 导入）")
    try:
        client = HttpClient(timeout=6)
        response = client.request("https://pan.baidu.com/", "GET")
        print(f"  百度连通性  HTTP {response.status}")
        response.close()
    except Exception as exc:
        print(f"  百度连通性  失败：{exc}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="yunx", description="YunX Linux — 网盘/直链下载器（分片、断点续传、自动重试）")
    parser.add_argument("-v", "--version", action="version", version=f"yunx {__version__}")
    sub = parser.add_subparsers(dest="command")

    login = sub.add_parser("login", help="浏览器扫码登录并保存 Cookie")
    login.add_argument("--firefox", action="store_true", help="直接从 Firefox 导入")
    login.add_argument("--status", action="store_true", help="查看自动登录状态")
    login.add_argument("--headless-driver", action="store_true", help="无头模式（只能密码登录）")
    login.add_argument("--timeout", type=int, default=300, help="等待登录秒数")
    login.set_defaults(func=cmd_login)

    add = sub.add_parser("add", help="添加下载任务")
    add.add_argument("link", help="百度分享链接或 http(s) 直链")
    add.add_argument("--code", help="提取码（也可写在链接 ?pwd= 后）")
    add.add_argument("--directory", help="下载目录")
    add.add_argument("--name", help="直链保存文件名")
    add.set_defaults(func=cmd_add)

    ls = sub.add_parser("ls", help="查看任务列表")
    ls.add_argument("--json", action="store_true", help="输出 JSON")
    ls.set_defaults(func=cmd_ls)

    run = sub.add_parser("run", help="启动下载引擎（后台式长驻）")
    run.add_argument("--web", action="store_true", help="同时启动本地网页面板")
    run.add_argument("--port", type=int, help="网页面板端口（默认 8899）")
    run.add_argument("--bind", help="网页面板监听地址（默认 127.0.0.1）")
    run.add_argument("--no-auto-resume", action="store_true", help="不自动续传未完成的任务")
    run.set_defaults(func=cmd_run)

    pause = sub.add_parser("pause", help="暂停任务")
    pause.add_argument("task_id", help="任务 ID 前缀或 all")
    pause.set_defaults(func=cmd_pause)

    resume = sub.add_parser("resume", help="标记任务继续（下次 run 时生效）")
    resume.add_argument("task_id", help="任务 ID 前缀或 all")
    resume.set_defaults(func=cmd_resume)

    rm = sub.add_parser("rm", help="删除任务")
    rm.add_argument("task_id")
    rm.add_argument("--delete-file", action="store_true", help="同时删除已下载文件")
    rm.set_defaults(func=cmd_rm)

    settings = sub.add_parser("settings", help="查看或修改设置")
    settings.add_argument("--directory")
    settings.add_argument("--connections", type=int)
    settings.add_argument("--speed", type=int, help="限速 KB/s，0 = 不限速")
    settings.add_argument("--auto-retry", choices=["on", "off"])
    settings.set_defaults(func=cmd_settings)

    clean = sub.add_parser("clean", help="清理网盘 /来自分享 目录")
    clean.set_defaults(func=cmd_clean)

    doctor = sub.add_parser("doctor", help="检查运行环境")
    doctor.set_defaults(func=cmd_doctor)
    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        parser.print_help()
        return 0
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
    except (PanError, HttpError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
