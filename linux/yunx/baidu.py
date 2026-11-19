"""百度网盘分享解析（Python 版，逐条对齐 Mac 版 BaiduPanResolver）。

关键事实（都是实测得来的，不要"顺手优化"）：
1. 分享链接里的 surl 要去掉开头那个 1，才能用于 share/list 与 share/verify。
2. 百度早就不给"未转存分享文件"的直链了，/api/sharedownload 一律 errno 2。
   必须 /share/transfer 转存到自己网盘，再取自己文件的 dlink。
3. bdstoken 要一次请求 sign,timestamp,bdstoken 三个字段；只请求 bdstoken 会回 errno 2。
4. dlink 必须走 /rest/2.0/xpan/file?method=filemetas；/api/filemetas 会回 31021。
   而且不能带空的 access_token，带了回 9019。
5. 任何查询串都不许二次编码：%5B 变成 %255B 后 fsids 就解析失败。
"""

from __future__ import annotations

import json
import posixpath
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
from urllib.parse import quote

from .http_client import HttpClient, Response, USER_AGENT, cookie_header, parse_cookie_header
from .linkparser import baidu_surl

BASE_QUERY = "channel=chunlei&web=1&app_id=250528&clienttype=0"
TRANSFER_ROOT = "/来自分享"


class PanError(Exception):
    pass


@dataclass
class PanShareEntry:
    name: str
    size: int = 0
    is_directory: bool = False
    fs_id: str = ""
    share_path: str = ""      # 分享内绝对路径，如 /分享名/子目录
    relative_path: str = ""   # 相对分享根目录，如 子目录/文件.mp4


@dataclass
class ResolvedFile:
    url: str
    file_name: str
    size: int
    headers: Dict[str, str] = field(default_factory=dict)
    provider: str = "baidu"
    note: Optional[str] = None
    source_url: Optional[str] = None
    share_code: Optional[str] = None
    # 多文件分享：相对下载根目录的路径（含分享名，如 分享名/子目录/文件.mp4）
    relative_path: Optional[str] = None
    # 转存到自己网盘后的 fs_id，直链过期刷新时按它重取，避免拿到别的文件的直链
    pan_fs_id: Optional[str] = None


class PanHTTP:
    """自己管 cookie 的轻量客户端，不污染全局状态。"""

    def __init__(self, cookies: Optional[Dict[str, str]] = None, timeout: float = 25.0):
        self.client = HttpClient(timeout=timeout)
        self.cookies: Dict[str, str] = {}
        self.set_cookies(cookies or {})

    def set_cookies(self, values: Dict[str, str]) -> None:
        for name, value in values.items():
            if name and name != "undefined" and value is not None:
                self.cookies[name] = value

    def _absorb(self, response: Response) -> None:
        try:
            values = response.raw.msg.get_all("Set-Cookie") or []
        except AttributeError:
            values = []
        for raw in values:
            self.set_cookies(parse_cookie_header(raw))

    def send(self, url: str, method: str = "GET", headers=None, body=None) -> Response:
        outbound = dict(headers or {})
        outbound.setdefault("User-Agent", USER_AGENT)
        header = cookie_header(self.cookies)
        if header:
            outbound["Cookie"] = header
        response = self.client.request(url, method, outbound, body)
        self._absorb(response)
        return response

    def json(self, url: str, method: str = "GET", headers=None, body=None) -> dict:
        response = self.send(url, method, headers, body)
        try:
            raw = response.read()
            try:
                value = json.loads(raw.decode("utf-8", "replace"))
            except ValueError as exc:
                preview = raw[:200].decode("utf-8", "replace")
                raise PanError(f"接口返回的不是 JSON：{preview}") from exc
            if not isinstance(value, dict):
                raise PanError("接口返回的 JSON 结构异常")
            return value
        finally:
            response.close()


def _safe_name(name: str) -> str:
    value = str(name).replace("/", "_").replace(":", "_").replace("\x00", "").strip()
    return value[:180] if value and value not in (".", "..") else "下载文件"


def _errno(payload: dict) -> int:
    """注意不能用 `errno or -1`：errno 为 0 时会被误判成失败。"""
    value = payload.get("errno", -1)
    try:
        return int(value)
    except (TypeError, ValueError):
        return -1


def _err(payload: dict, fallback: str = "百度网盘返回错误") -> str:
    return str(payload.get("show_msg") or payload.get("error_msg") or
               fallback + f"（errno {payload.get('errno', -1)}）")


class BaiduResolver:
    def __init__(self, cookies: Optional[Dict[str, str]] = None):
        self.http = PanHTTP(cookies)

    # ---------- 公开入口 ----------

    def bootstrap(self) -> None:
        """首页是为了拿到 BAIDUID，verify 与 list 都依赖它。"""
        try:
            response = self.http.send("https://pan.baidu.com/")
            response.close()
        except Exception:
            pass

    def preview(self, link: str) -> List[PanShareEntry]:
        self.bootstrap()
        return self._list_files(link).entries

    def resolve(self, link: str, share_code: Optional[str] = None) -> ResolvedFile:
        self.bootstrap()
        listed = self._list_files(link, share_code)
        downloadable = [item for item in listed.entries if not item.is_directory]
        if not downloadable:
            raise PanError("分享里没有可下载的文件")
        entry = downloadable[0]
        token = self._fetch_bdtoken()
        saved = self._transfer(link, entry, listed.share_id, listed.uk, token)
        dlink = self._fetch_dlink(saved.fs_id, token)

        headers = self.download_headers()

        note = (f"该文件已在你网盘中：{saved.path}" if saved.reused else
                f"已转存到你网盘的 {saved.path}，可稍后自行清理")
        if len(downloadable) > 1:
            note = f"分享共 {len(downloadable)} 个文件，本次下载第 1 个；" + note

        return ResolvedFile(
            url=dlink,
            file_name=entry.name,
            size=entry.size,
            headers=headers,
            provider="baidu",
            note=note,
            source_url=link,
            share_code=share_code,
            pan_fs_id=saved.fs_id,
        )

    # ---------- 多文件（递归目录树，保持结构下载全部文件） ----------

    MAX_FILES = 200       # 超大分享护栏
    MAX_DIRECTORIES = 60
    BATCH_LIMIT = 100     # 转存 / filemetas 单次请求的 fs_id 数量上限

    def resolve_all(self, link: str, share_code: Optional[str] = None) -> List[ResolvedFile]:
        """递归展开分享目录树，转存整树后每个文件返回一个 ResolvedFile。"""
        self.bootstrap()
        tree = self._list_tree(link, share_code)

        # 空分享 / 单文件分享：走已实测验证的单文件链路，行为与旧版一致
        if len(tree.files) <= 1:
            return [self.resolve(link, share_code)]

        token = self._fetch_bdtoken()
        target_dir = TRANSFER_ROOT + "/" + tree.share_name

        # 1) 整树转存：只转顶层条目（目录+文件混合），百度会原样保留目录结构
        self._transfer_batch(link, tree.top_entries, tree.share_id, tree.uk,
                             token, target_dir)

        # 2) 遍历自己网盘里的落地目录，按相对路径对齐每个文件的 fs_id
        disk_files = self._list_disk_tree(target_dir)
        by_relative = {item.relative_path: item for item in disk_files}
        pending = []
        for entry in tree.files:
            disk = by_relative.get(entry.relative_path)
            if disk and disk.fs_id:
                pending.append((entry, disk))
        if not pending:
            raise PanError(
                f"转存后未能对上文件清单（分享 {len(tree.files)} 个文件，"
                f"网盘侧 {len(disk_files)} 个），请稍后重试")

        # 3) 批量取 dlink
        dlinks = self._fetch_dlinks([disk.fs_id for _, disk in pending], token)

        headers = self.download_headers()
        results: List[ResolvedFile] = []
        for entry, disk in pending:
            dlink = dlinks.get(disk.fs_id)
            if not dlink:
                continue
            relative = tree.share_name + "/" + (entry.relative_path or entry.name)
            results.append(ResolvedFile(
                url=dlink,
                file_name=posixpath.basename(relative),
                size=entry.size,
                headers=headers,
                provider="baidu",
                note=None,
                source_url=link,
                share_code=share_code,
                relative_path=relative,
                pan_fs_id=disk.fs_id,
            ))

        if not results:
            raise PanError("百度网盘没有返回任何可下载地址，可能是分享内容需要会员权限")

        note = (f"已转存整棵分享目录并加入 {len(results)} 个文件（保持目录结构），"
                f"落地在网盘 {target_dir}，可稍后自行清理")
        if tree.truncated:
            note = f"分享过大，本次最多加入前 {len(results)} 个文件；" + note
        elif len(results) < len(tree.files):
            note = f"分享共 {len(tree.files)} 个文件，成功加入 {len(results)} 个；" + note
        results[0].note = note
        return results

    def refresh_dlink(self, pan_fs_id: str) -> str:
        """直链过期时按网盘内 fs_id 重取 dlink（不重新走分享解析）。"""
        token = self._fetch_bdtoken()
        return self._fetch_dlink(pan_fs_id, token)

    def download_headers(self) -> Dict[str, str]:
        headers = {
            "Referer": "https://pan.baidu.com/disk/home",
            "User-Agent": "pan.baidu.com",   # 百度 pcs 对 UA 敏感
        }
        cookie = cookie_header(self.http.cookies)
        if cookie:
            headers["Cookie"] = cookie
        return headers

    # ---------- 各步骤 ----------

    def _list_files(self, link: str, share_code: Optional[str] = None):
        raw = baidu_surl(link)
        if not raw:
            raise PanError("无法从链接里识别出百度网盘分享 ID")
        if share_code:
            if not self._verify(share_code, raw):
                raise PanError("提取码不正确")
        payload = self._fetch_share_list(raw, "/", root=True)
        parsed_share_id, parsed_uk, entries = self._parse_share_list(payload)

        if not entries:
            title = str(payload.get("title") or "")
            name = posixpath.basename(title) if title else ""
            if name:
                entries = [PanShareEntry(name=name)]
            else:
                raise PanError("分享里没有可下载的文件")
        return _Listed(entries=entries, share_id=parsed_share_id, uk=parsed_uk)

    # ---------- 分享目录树（多文件） ----------

    class _Tree:
        def __init__(self, top_entries, files, share_id, uk, share_name, truncated=False):
            self.top_entries = top_entries
            self.files = files
            self.share_id = share_id
            self.uk = uk
            self.share_name = share_name
            self.truncated = truncated

    def _list_tree(self, link: str, share_code: Optional[str] = None) -> "_Tree":
        raw = baidu_surl(link)
        if not raw:
            raise PanError("无法从链接里识别出百度网盘分享 ID")
        if share_code:
            if not self._verify(share_code, raw):
                raise PanError("提取码不正确")

        root_payload = self._fetch_share_list(raw, "/", root=True)
        share_id, uk, top = self._parse_share_list(root_payload)
        if not top:
            raise PanError("分享里没有可下载的文件")

        # 分享名取顶层条目 share_path 的第一段（/分享名/xxx），
        # 保证转存落地目录与分享一一对应
        share_name = ""
        for entry in top:
            if entry.share_path and entry.share_path.count("/") >= 2:
                share_name = entry.share_path.strip("/").split("/")[0]
                break
        if not share_name:
            share_name = _safe_name("分享_" + raw)

        files: List[PanShareEntry] = []
        queue: List[PanShareEntry] = []
        truncated = False
        for entry in top:
            item = PanShareEntry(
                name=entry.name, size=entry.size, is_directory=entry.is_directory,
                fs_id=entry.fs_id,
                share_path=entry.share_path or "/" + entry.name,
                relative_path=entry.name,
            )
            if item.is_directory:
                queue.append(item)
            elif len(files) < self.MAX_FILES:
                files.append(item)
            else:
                truncated = True

        expanded = 0
        while queue:
            directory = queue.pop()
            expanded += 1
            if expanded > self.MAX_DIRECTORIES:
                truncated = True
                break
            sub_payload = self._fetch_share_list(raw, directory.share_path, root=False)
            _, _, sub_entries = self._parse_share_list(sub_payload)
            for entry in sub_entries:
                item = PanShareEntry(
                    name=entry.name, size=entry.size, is_directory=entry.is_directory,
                    fs_id=entry.fs_id,
                    share_path=entry.share_path or directory.share_path + "/" + entry.name,
                    relative_path=directory.relative_path + "/" + entry.name,
                )
                if item.is_directory:
                    queue.append(item)
                elif len(files) < self.MAX_FILES:
                    files.append(item)
                else:
                    truncated = True

        if not files:
            raise PanError("分享里没有可下载的文件")
        return self._Tree(top_entries=top, files=files, share_id=share_id, uk=uk,
                          share_name=_safe_name(share_name), truncated=truncated)

    def _fetch_share_list(self, surl: str, dir_path: str, root: bool) -> dict:
        url = ("https://pan.baidu.com/share/list?shorturl=" + surl +
               "&dir=" + quote(dir_path, safe="/") +
               f"&root={1 if root else 0}&page=1&num=100&order=time&desc=1&" + BASE_QUERY)
        payload = self.http.json(url, headers={
            "Referer": f"https://pan.baidu.com/s/{surl}",
            "X-Requested-With": "XMLHttpRequest",
        })
        errno = _errno(payload)
        if errno == -9:
            raise PanError("提取码不正确")
        if errno in (105, 140):
            raise PanError("分享已失效或被取消")
        if errno == -6:
            raise PanError("百度登录已失效，请重新登录")
        if errno != 0:
            raise PanError("百度网盘返回错误：" + _err(payload))
        return payload

    @staticmethod
    def _parse_share_list(payload: dict) -> Tuple[str, str, List[PanShareEntry]]:
        share_id = str(payload.get("share_id") or "")
        uk = str(payload.get("uk") or "")
        entries = []
        for item in payload.get("list") or []:
            name = str(item.get("server_filename") or "")
            if not name:
                continue
            entries.append(PanShareEntry(
                name=name,
                size=int(item.get("size") or 0),
                is_directory=int(item.get("isdir") or 0) == 1,
                fs_id=str(item.get("fs_id") or ""),
                share_path=str(item.get("path") or ""),
            ))
        return share_id, uk, entries

    def _verify(self, code: str, surl: str) -> bool:
        timestamp = int(time.time())
        url = (f"https://pan.baidu.com/share/verify?surl={surl}&t={timestamp}&" + BASE_QUERY)
        payload = self.http.json(url, method="POST", body=f"pwd={quote(code)}".encode(), headers={
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Referer": f"https://pan.baidu.com/share/init?surl={surl}",
            "X-Requested-With": "XMLHttpRequest",
        })
        errno = _errno(payload)
        if errno == 0:
            return True
        if errno == -9:
            return False
        if errno == 105:
            raise PanError("分享已失效或被取消")
        raise PanError("提取码验证失败：" + _err(payload))

    def _fetch_bdtoken(self) -> str:
        fields = quote('["sign","timestamp","bdstoken"]', safe="")
        url = f"https://pan.baidu.com/api/gettemplatevariable?fields={fields}&{BASE_QUERY}"
        payload = self.http.json(url, headers={"Referer": "https://pan.baidu.com/disk/home"})
        if _errno(payload) == -6:
            raise PanError("百度登录已失效，请重新登录")
        result = payload.get("result") or {}
        token = str(result.get("bdstoken") or "")
        if not token:
            raise PanError(f"未能取到百度网盘操作令牌（errno {payload.get('errno', -1)}）")
        return token

    def _search_existing(self, name: str, size: int) -> Optional[Tuple[str, str]]:
        key = quote(name, safe="")
        url = ("https://pan.baidu.com/api/search?key=" + key +
               "&dir=%2F&recursion=1&page=1&num=50&order=time&desc=1&" +
               "web=1&app_id=250528&channel=chunlei&clienttype=0")
        try:
            payload = self.http.json(url, headers={"Referer": "https://pan.baidu.com/disk/home"})
        except Exception:
            return None
        if _errno(payload) != 0:
            return None
        for item in payload.get("list") or []:
            if item.get("server_filename") != name:
                continue
            item_size = int(item.get("size") or 0)
            if size > 0 and item_size > 0 and item_size != size:
                continue
            fs_id = str(item.get("fs_id") or "")
            if fs_id:
                return fs_id, str(item.get("path") or name)
        return None

    def _find_fs_id(self, path: str) -> Optional[str]:
        directory = posixpath.dirname(path)
        name = posixpath.basename(path)
        url = ("https://pan.baidu.com/api/list?dir=" + quote(directory, safe="/") +
               "&order=time&desc=1&showempty=0&page=1&num=200&" + BASE_QUERY)
        payload = self.http.json(url, headers={"Referer": "https://pan.baidu.com/disk/home"})
        for item in payload.get("list") or []:
            if item.get("server_filename") == name:
                return str(item.get("fs_id") or "") or None
        return None

    def _transfer(self, link: str, entry: PanShareEntry,
                  share_id: str, uk: str, token: str):
        if not share_id or not uk:
            raise PanError("分享信息不完整，缺少 shareid 或 uk")

        target_dir = TRANSFER_ROOT + "/" + _safe_name(posixpath.splitext(entry.name)[0])
        # 幂等：同名同大小说明之前转过，直接复用，不重复写用户网盘
        existing = self._search_existing(entry.name, entry.size)
        if existing:
            return _Transferred(fs_id=existing[0], path=existing[1], reused=True)

        url = ("https://pan.baidu.com/share/transfer?shareid=" + quote(share_id, safe="") +
               "&from=" + quote(uk, safe="") + "&ondup=newcopy&async=1&" +
               BASE_QUERY + "&bdstoken=" + quote(token, safe=""))
        # path 里的 / 必须保留，用 safe="" 会把目录分隔符也编码掉
        body = ("fsidlist=%5B" + str(entry.fs_id) + "%5D&path=" +
                quote(target_dir, safe="/"))
        raw = baidu_surl(link)
        headers = {
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "X-Requested-With": "XMLHttpRequest",
        }
        if raw:
            headers["Referer"] = f"https://pan.baidu.com/s/{raw}"
        payload = self.http.json(url, method="POST", body=body.encode(), headers=headers)
        errno = _errno(payload)
        if errno in (0, 12):
            extra = payload.get("extra") or {}
            items = extra.get("list") or []
            if items:
                to_path = str(items[0].get("to") or target_dir)
                to_fs_id = str(items[0].get("to_fsid") or "")
                if to_fs_id:
                    return _Transferred(fs_id=to_fs_id, path=to_path, reused=False)
                found = self._find_fs_id(to_path)
                if found:
                    return _Transferred(fs_id=found, path=to_path, reused=False)
            raise PanError("转存成功但没拿到文件标识，请稍后重试")
        if errno == -6:
            raise PanError("百度登录已失效，请重新登录")
        if errno == 4:
            raise PanError("该分享不允许转存")
        if errno == -33:
            raise PanError("你的百度网盘空间不足")
        raise PanError("转存失败：" + _err(payload))

    def _fetch_dlink(self, fs_id: str, token: str) -> str:
        url = ("https://pan.baidu.com/rest/2.0/xpan/file?method=filemetas&dlink=1&fsids=%5B" +
               str(fs_id) + "%5D&web=1&app_id=250528&channel=chunlei&clienttype=0&bdstoken=" +
               quote(token, safe=""))
        payload = self.http.json(url, headers={"Referer": "https://pan.baidu.com/disk/home"})
        errno = _errno(payload)
        if errno == -6:
            raise PanError("百度登录已失效，请重新登录")
        if errno != 0:
            raise PanError("取直链失败：" + _err(payload))
        info = payload.get("info") or []
        if not info:
            raise PanError("百度网盘没有返回文件信息")
        first = info[0]
        if int(first.get("errno") or 0) != 0:
            raise PanError(f"百度网盘拒绝提供直链（errno {first.get('errno')}）")
        dlink = first.get("dlink")
        if not dlink:
            raise PanError("百度网盘没有返回下载地址，可能是该文件需要会员权限")
        return str(dlink)

    # ---------- 多文件辅助（整树转存 / 网盘树 / 批量 dlink） ----------

    def _transfer_batch(self, link: str, entries: List[PanShareEntry],
                        share_id: str, uk: str, token: str, target_dir: str) -> None:
        """分批转存顶层条目（目录+文件混合），百度会把目录树原样保留。
        与单文件转存不同：这里不逐个查重，errno 12（部分已存在）视为成功，
        幂等性由「转存后按网盘目录树对齐」这一步天然保证。"""
        if not share_id or not uk:
            raise PanError("分享信息不完整，缺少 shareid 或 uk")
        ids = [entry.fs_id for entry in entries if entry.fs_id]
        if not ids:
            raise PanError("分享条目缺少文件标识，无法转存")

        url = ("https://pan.baidu.com/share/transfer?shareid=" + quote(share_id, safe="") +
               "&from=" + quote(uk, safe="") + "&ondup=newcopy&async=1&" +
               BASE_QUERY + "&bdstoken=" + quote(token, safe=""))
        headers = {
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "X-Requested-With": "XMLHttpRequest",
        }
        raw = baidu_surl(link)
        if raw:
            headers["Referer"] = f"https://pan.baidu.com/s/{raw}"

        for start in range(0, len(ids), self.BATCH_LIMIT):
            batch = ids[start:start + self.BATCH_LIMIT]
            fsidlist = "%5B" + ",".join(batch) + "%5D"
            # path 里的 / 必须保留，用 safe="" 会把目录分隔符也编码掉
            body = "fsidlist=" + fsidlist + "&path=" + quote(target_dir, safe="/")
            payload = self.http.json(url, method="POST", body=body.encode(), headers=headers)
            errno = _errno(payload)
            if errno in (0, 12):
                continue
            if errno == -6:
                raise PanError("百度登录已失效，请重新登录")
            if errno == 4:
                raise PanError("该分享不允许转存")
            if errno == -33:
                raise PanError("你的百度网盘空间不足")
            raise PanError("转存失败：" + _err(payload))

    class _DiskFile:
        def __init__(self, relative_path: str, name: str, size: int, fs_id: str):
            self.relative_path = relative_path
            self.name = name
            self.size = size
            self.fs_id = fs_id

    def _list_disk_tree(self, root: str) -> List["_DiskFile"]:
        """BFS 遍历用户网盘里的落地目录树，收集全部文件（相对 root 的路径）。"""
        files: List[self._DiskFile] = []
        queue: List[Tuple[str, str]] = [(root, "")]
        visited = 0
        while queue:
            absolute, relative = queue.pop()
            visited += 1
            if visited > self.MAX_DIRECTORIES + 5:
                break
            url = ("https://pan.baidu.com/api/list?dir=" + quote(absolute, safe="/") +
                   "&order=time&desc=1&showempty=0&page=1&num=200&" + BASE_QUERY)
            try:
                payload = self.http.json(url, headers={"Referer": "https://pan.baidu.com/disk/home"})
            except Exception:
                continue
            for item in payload.get("list") or []:
                name = str(item.get("server_filename") or "")
                if not name:
                    continue
                child_relative = relative + "/" + name if relative else name
                if int(item.get("isdir") or 0) == 1:
                    child_path = str(item.get("path") or (absolute + "/" + name))
                    queue.append((child_path, child_relative))
                else:
                    files.append(self._DiskFile(
                        relative_path=child_relative,
                        name=name,
                        size=int(item.get("size") or 0),
                        fs_id=str(item.get("fs_id") or ""),
                    ))
        return files

    def _fetch_dlinks(self, fs_ids: List[str], token: str) -> Dict[str, str]:
        """批量取 dlink（filemetas 的 fsids 数组），返回 fs_id -> dlink。"""
        result: Dict[str, str] = {}
        for start in range(0, len(fs_ids), self.BATCH_LIMIT):
            batch = fs_ids[start:start + self.BATCH_LIMIT]
            fsids_param = "%5B" + ",".join(batch) + "%5D"
            url = ("https://pan.baidu.com/rest/2.0/xpan/file?method=filemetas&dlink=1&fsids=" +
                   fsids_param + "&web=1&app_id=250528&channel=chunlei&clienttype=0&bdstoken=" +
                   quote(token, safe=""))
            payload = self.http.json(url, headers={"Referer": "https://pan.baidu.com/disk/home"})
            errno = _errno(payload)
            if errno == -6:
                raise PanError("百度登录已失效，请重新登录")
            if errno != 0:
                raise PanError("取直链失败：" + _err(payload))
            for item in payload.get("info") or []:
                fs_id = str(item.get("fs_id") or "")
                dlink = item.get("dlink")
                if fs_id and dlink and int(item.get("errno") or 0) == 0:
                    result[fs_id] = str(dlink)
        return result

    def clean_transferred(self) -> None:
        """删除 /来自分享，避免长期占用网盘空间。"""
        fields = quote('["sign","timestamp","bdstoken"]', safe="")
        url = f"https://pan.baidu.com/api/gettemplatevariable?fields={fields}&{BASE_QUERY}"
        try:
            payload = self.http.json(url, headers={"Referer": "https://pan.baidu.com/disk/home"})
            token = str((payload.get("result") or {}).get("bdstoken") or "")
        except Exception:
            return
        if not token:
            return
        delete_url = ("https://pan.baidu.com/api/filemanager?opera=delete&async=2&onnest=fail&" +
                      BASE_QUERY + "&bdstoken=" + quote(token, safe=""))
        body = "filelist=%5B%22" + quote(TRANSFER_ROOT, safe="/") + "%22%5D"
        try:
            response = self.http.send(delete_url, method="POST", body=body.encode(), headers={
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": "https://pan.baidu.com/disk/home",
            })
            response.close()
        except Exception:
            pass


class _Listed:
    def __init__(self, entries: List[PanShareEntry], share_id: str, uk: str):
        self.entries = entries
        self.share_id = share_id
        self.uk = uk


class _Transferred:
    def __init__(self, fs_id: str, path: str, reused: bool):
        self.fs_id = fs_id
        self.path = path
        self.reused = reused
