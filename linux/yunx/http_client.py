"""轻量 HTTP 客户端：支持 Range、自定义请求头、重定向与流式读取。

用标准库 http.client 而不是 requests，这样安装包不需要任何第三方依赖。
"""

from __future__ import annotations

import http.client
import re
import socket
import ssl
import threading
from dataclasses import dataclass
from typing import Dict, Optional, Tuple
from urllib.parse import urlsplit, urlunsplit

USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

COOKIE_SPLIT_RE = re.compile(r",\s*(?=[A-Za-z0-9_\-]+=)")


class HttpError(Exception):
    pass


class StatusError(HttpError):
    def __init__(self, status: int, message: str = ""):
        super().__init__(message or f"HTTP {status}")
        self.status = status


@dataclass
class Response:
    status: int
    headers: object
    final_url: str
    connection: http.client.HTTPConnection
    raw: http.client.HTTPResponse

    def get(self, name: str, default: Optional[str] = None) -> Optional[str]:
        return self.raw.getheader(name, default)

    def read(self, size: int) -> bytes:
        return self.raw.read(size)

    def close(self) -> None:
        try:
            self.raw.close()
        except Exception:
            pass
        try:
            self.connection.close()
        except Exception:
            pass


def parse_cookie_header(raw: str) -> Dict[str, str]:
    """Set-Cookie 可能把多条塞在一起；只在「逗号 + name=」处切开。"""
    pieces = COOKIE_SPLIT_RE.split(raw)
    cookies: Dict[str, str] = {}
    for piece in pieces:
        first = piece.split(";", 1)[0].strip()
        if "=" not in first:
            continue
        name, value = first.split("=", 1)
        name = name.strip()
        if name and name != "undefined":
            cookies[name] = value.strip()
    return cookies


def cookie_header(cookies: Dict[str, str]) -> str:
    return "; ".join(f"{key}={value}" for key, value in sorted(cookies.items())
                     if key and value is not None and key != "undefined")


def parse_content_range(value: Optional[str]) -> Optional[Tuple[int, int, int]]:
    if not value:
        return None
    match = re.search(r"bytes\s+(\d+)-(\d+)/(\d+|\*)", value, re.I)
    if not match:
        return None
    total = match.group(3)
    return int(match.group(1)), int(match.group(2)), -1 if total == "*" else int(total)


class HttpClient:
    def __init__(self, timeout: float = 30.0, max_redirects: int = 5):
        self.timeout = timeout
        self.max_redirects = max_redirects
        self._context = ssl.create_default_context()
        self._context.check_hostname = True
        self._context.verify_mode = ssl.CERT_REQUIRED

    @staticmethod
    def _target(url: str) -> Tuple[str, str, int, bool]:
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https"):
            raise HttpError(f"不支持的协议：{parts.scheme}")
        try:
            port = parts.port or (443 if parts.scheme == "https" else 80)
        except ValueError as exc:
            raise HttpError(f"端口无效：{exc}") from exc
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        return parts.hostname or "", path, port, parts.scheme == "https"

    def request(
        self,
        url: str,
        method: str = "GET",
        headers: Optional[Dict[str, str]] = None,
        body: Optional[bytes] = None,
    ) -> Response:
        current = url
        for _ in range(self.max_redirects + 1):
            host, path, port, secure = self._target(current)
            outbound = dict(headers or {})
            outbound.setdefault("User-Agent", USER_AGENT)
            outbound.setdefault("Accept", "*/*")
            if body is not None:
                outbound["Content-Length"] = str(len(body))
            connection = (
                http.client.HTTPSConnection(host, port, timeout=self.timeout, context=self._context)
                if secure else http.client.HTTPConnection(host, port, timeout=self.timeout)
            )
            try:
                connection.request(method, path, body=body, headers=outbound)
                raw = connection.getresponse()
                location = raw.getheader("Location")
                if raw.status in (301, 302, 303, 307, 308) and location:
                    # 302 之后应改用 GET；307/308 保留方法与 body
                    if raw.status == 303 or (raw.status == 302 and method == "POST"):
                        method, body = "GET", None
                    raw.close()
                    connection.close()
                    if location.startswith("/"):
                        parts = urlsplit(current)
                        current = urlunsplit((parts.scheme, parts.netloc, location, "", ""))
                    else:
                        current = location
                    continue
                return Response(raw.status, raw.msg, current, connection, raw)
            except (socket.timeout, socket.error, http.client.HTTPException):
                connection.close()
                raise
        raise HttpError(f"重定向次数超过 {self.max_redirects} 次")

    def json(self, url: str, method: str = "GET", headers=None, body=None) -> dict:
        import json
        response = self.request(url, method, headers, body)
        try:
            payload = response.read()
            return json.loads(payload.decode("utf-8", "replace"))
        finally:
            response.close()
