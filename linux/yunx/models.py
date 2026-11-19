"""任务与分片的数据模型。"""

from __future__ import annotations

import os
import threading
import time
import uuid
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional


QUEUED = "queued"
RUNNING = "running"
PAUSED = "paused"
WAITING_RETRY = "waitingRetry"
COMPLETED = "completed"
FAILED = "failed"
CANCELLED = "cancelled"

ACTIVE_STATUSES = (QUEUED, RUNNING, WAITING_RETRY)
TERMINAL_STATUSES = (COMPLETED, FAILED, CANCELLED)

STATUS_LABELS = {
    QUEUED: "排队中",
    RUNNING: "下载中",
    PAUSED: "已暂停",
    WAITING_RETRY: "等待重试",
    COMPLETED: "已完成",
    FAILED: "失败",
    CANCELLED: "已取消",
}


@dataclass
class Segment:
    start: int
    end: int
    received: int = 0

    @property
    def length(self) -> int:
        return max(0, self.end - self.start + 1)

    @property
    def done(self) -> bool:
        return self.received >= self.length

    @property
    def next_offset(self) -> int:
        return min(self.end + 1, self.start + self.received)


@dataclass
class Task:
    id: str
    url: str
    file_name: str
    directory: str
    total_size: int = 0
    segments: List[Segment] = field(default_factory=list)
    request_headers: Dict[str, str] = field(default_factory=dict)
    status: str = QUEUED
    error: Optional[str] = None
    retry_count: int = 0
    next_retry_at: float = 0.0
    created_at: float = field(default_factory=time.time)
    completed_at: Optional[float] = None
    auto_retry: bool = True
    speed_limit_bps: int = 0
    connections: int = 8
    supports_range: bool = True
    etag: Optional[str] = None
    last_modified: Optional[str] = None
    source_url: Optional[str] = None
    share_code: Optional[str] = None
    provider: str = "direct"
    note: Optional[str] = None
    # 百度多文件任务：转存到自己网盘后的 fs_id，直链过期刷新时按它重取
    pan_fs_id: Optional[str] = None

    # 运行时字段，不序列化
    speed: float = 0.0
    lock: threading.RLock = field(default_factory=threading.RLock, repr=False, compare=False)

    @property
    def received(self) -> int:
        return sum(segment.received for segment in self.segments)

    @property
    def progress(self) -> float:
        if self.total_size <= 0:
            return 0.0
        return min(1.0, self.received / self.total_size)

    @property
    def file_path(self) -> str:
        return os.path.join(self.directory, sanitize(self.file_name))

    @property
    def status_label(self) -> str:
        return STATUS_LABELS.get(self.status, self.status)

    def to_dict(self) -> Dict[str, Any]:
        # 不用 dataclasses.asdict：它会 deepcopy 运行时的 RLock 而报错
        data: Dict[str, Any] = {}
        for name in Task.__dataclass_fields__:
            if name in ("lock", "speed"):
                continue
            value = getattr(self, name)
            if name == "segments":
                value = [asdict(segment) for segment in self.segments]
            data[name] = value
        return data

    @staticmethod
    def from_dict(raw: Dict[str, Any]) -> "Task":
        data = dict(raw)
        segments = [Segment(**item) for item in data.pop("segments", [])]
        data.pop("speed", None)
        data.pop("lock", None)
        task = Task(**{k: v for k, v in data.items() if k in Task.__dataclass_fields__})
        task.segments = segments
        # 上次退出时还在跑的，重启后一律视为暂停，由用户/守护进程显式续传
        if task.status in ACTIVE_STATUSES:
            task.status = PAUSED
        return task


def sanitize(name: str) -> str:
    """把网盘返回的文件名变成安全的本地文件名。"""
    value = str(name).replace("/", "_").replace(":", "_").replace("\x00", "")
    value = value.strip()
    if not value or value in (".", ".."):
        return "下载文件"
    return value[:180]


def make_segments(total_size: int, connections: int) -> List[Segment]:
    """尽量均匀分片，避免出现 0 长度分片。"""
    if total_size <= 0:
        return [Segment(0, 0, 0)]
    count = max(1, min(int(connections or 1), total_size))
    base, extra = divmod(total_size, count)
    segments: List[Segment] = []
    cursor = 0
    for index in range(count):
        size = base + (1 if index < extra else 0)
        segments.append(Segment(cursor, cursor + size - 1, 0))
        cursor += size
    return segments


def new_task_id() -> str:
    return uuid.uuid4().hex
