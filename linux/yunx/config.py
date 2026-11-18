"""配置与持久化路径。

配置放在 ~/.config/yunx（可用 YUNX_CONFIG_DIR 覆盖）。
所有 JSON 都以「临时文件 + fsync + atomic rename」写入，避免断电或并发写坏任务表。
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any, Dict


def config_dir() -> Path:
    override = os.environ.get("YUNX_CONFIG_DIR")
    return Path(override).expanduser() if override else Path.home() / ".config" / "yunx"


def tasks_file() -> Path:
    return config_dir() / "tasks.json"


def settings_file() -> Path:
    return config_dir() / "settings.json"


def cookies_file() -> Path:
    return config_dir() / "cookies.txt"


def log_file() -> Path:
    return config_dir() / "yunx.log"


DEFAULT_SETTINGS: Dict[str, Any] = {
    "download_directory": str(Path.home() / "Downloads" / "YunX"),
    "connections": 8,
    "speed_limit_kbps": 0,          # 0 = 不限速
    "auto_retry": True,
    "max_segment_attempts": 30,
    "max_empty_responses": 80,
    "stall_timeout": 60,
    "web_port": 8899,
    "web_bind": "127.0.0.1",
}


def ensure_dirs() -> None:
    config_dir().mkdir(parents=True, exist_ok=True)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path: Path, default: Any) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def load_settings() -> Dict[str, Any]:
    stored = read_json(settings_file(), {})
    if not isinstance(stored, dict):
        stored = {}
    merged = dict(DEFAULT_SETTINGS)
    # 老版本可能缺少新增字段，逐个合并而不是整份替换
    for key, value in stored.items():
        if key in merged:
            merged[key] = value
    return merged


def save_settings(settings: Dict[str, Any]) -> None:
    atomic_write_json(settings_file(), settings)
