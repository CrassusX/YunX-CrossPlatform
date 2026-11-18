"""从任意文本里抽出链接、识别来源并提取提取码。纯本地规则，不发网络请求。"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import List, Optional
from urllib.parse import parse_qs, urlsplit

HTTP_RE = re.compile(r"https?://[^\s\"'<>\u3000，。、；;）)】\]》”’]+", re.I)
MAGNET_RE = re.compile(r"magnet:\?[^\s\"'<>）)】]+", re.I)
ED2K_RE = re.compile(r"ed2k://[^\s\"'<>）)】]+", re.I)
CODE_RE = re.compile(r"(?:提取码|访问码|密码|口令|pwd|code)\s*[:：=]?\s*([A-Za-z0-9]{4,8})", re.I)

TRAILING = ".,;:!?，。、；：！？)）】]》”’\"'"


@dataclass
class ParsedLink:
    raw: str
    provider: str
    share_code: Optional[str] = None


def _host_matches(host: str, names: List[str]) -> bool:
    return any(host == name or host.endswith("." + name) for name in names)


def detect_provider(raw: str) -> str:
    lower = raw.lower()
    if lower.startswith("magnet:?"):
        return "magnet"
    if lower.startswith("ed2k://"):
        return "ed2k"
    if lower.endswith(".torrent"):
        return "torrent"
    try:
        parts = urlsplit(raw)
        host = (parts.hostname or "").lower()
    except ValueError:
        return "unknown"
    if not host:
        return "unknown"
    if _host_matches(host, ["pan.quark.cn", "quark.cn"]):
        return "quark"
    if _host_matches(host, ["drive.uc.cn", "fast.uc.cn", "uc.cn"]):
        return "uc"
    if _host_matches(host, ["pan.baidu.com", "yun.baidu.com", "eyun.baidu.com"]):
        return "baidu"
    if "lanzou" in host or "lanzt" in host or "ilanzou" in host:
        return "lanzou"
    if _host_matches(host, ["123pan.cn", "123684.com", "123865.com", "123912.com", "123pan.com"]):
        return "pan123"
    if _host_matches(host, ["115.com", "anxia.com", "115cdn.com"]):
        return "pan115"
    if _host_matches(host, ["pan.xunlei.com", "xunlei.com"]):
        return "xunlei"
    if _host_matches(host, ["cloud.139.com", "caiyun.139.com"]):
        return "cloud139"
    if _host_matches(host, ["aliyundrive.com", "alipan.com"]):
        return "aliyun"
    if _host_matches(host, ["github.com", "raw.githubusercontent.com", "gist.github.com"]):
        return "github"
    if looks_like_file(raw):
        return "direct"
    return "unknown"


def looks_like_file(raw: str) -> bool:
    try:
        name = urlsplit(raw).path.rsplit("/", 1)[-1]
    except ValueError:
        return False
    if "." not in name or name.startswith("."):
        return False
    ext = name.rsplit(".", 1)[-1].lower()
    return 1 <= len(ext) <= 6 and ext.isalnum()


def _extract_code(raw: str, text: str) -> Optional[str]:
    try:
        query = parse_qs(urlsplit(raw).query, keep_blank_values=False)
        for key in ("pwd", "passcode", "password", "code"):
            values = query.get(key)
            if values and values[0]:
                return values[0]
    except ValueError:
        pass
    position = text.find(raw)
    if position >= 0:
        tail = text[position + len(raw): position + len(raw) + 120]
        match = CODE_RE.search(tail)
        if match:
            return match.group(1)
    match = CODE_RE.search(text)
    return match.group(1) if match else None


def parse(text: str) -> List[ParsedLink]:
    if not text or not text.strip():
        return []
    text = text.strip()
    found = []
    for regex in (HTTP_RE, MAGNET_RE, ED2K_RE):
        for match in regex.finditer(text):
            found.append((match.start(), match.group(0)))
    found.sort(key=lambda item: item[0])

    results: List[ParsedLink] = []
    seen = set()
    for _, raw in found:
        raw = raw.rstrip(TRAILING)
        key = raw.lower()
        if key in seen:
            continue
        seen.add(key)
        provider = detect_provider(raw)
        code = _extract_code(raw, text) if provider in ("baidu", "quark", "uc") else None
        results.append(ParsedLink(raw=raw, provider=provider, share_code=code))
    return results


def parse_first(text: str) -> Optional[ParsedLink]:
    links = parse(text)
    return links[0] if links else None


def baidu_raw_token(url: str) -> Optional[str]:
    """保留开头 1 的原始 token（tplconfig 用）。"""
    try:
        parts = urlsplit(url)
        query = parse_qs(parts.query)
        for key in ("surl",):
            if query.get(key) and query[key][0]:
                return query[key][0]
    except ValueError:
        pass
    marker = parts.path.find("/s/")
    if marker < 0:
        return None
    token = parts.path[marker + 3:].split("/", 1)[0]
    return token or None


def baidu_surl(url: str) -> Optional[str]:
    """share/list、verify 用的短 ID：去掉开头那个 1。"""
    raw = baidu_raw_token(url)
    if not raw:
        return None
    return raw[1:] if len(raw) > 1 and raw.startswith("1") else raw


def quark_pwd_id(url: str) -> Optional[str]:
    try:
        path = urlsplit(url).path
    except ValueError:
        return None
    marker = path.find("/s/")
    if marker < 0:
        return None
    return path[marker + 3:].split("/", 1)[0] or None
