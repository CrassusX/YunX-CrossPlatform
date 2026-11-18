"""本地网页面板：任务列表、新建任务、设置、扫码登录状态。

只绑定 127.0.0.1，不暴露到局域网；无第三方框架，用标准库 http.server。
"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

from . import __version__, cookiestore
from .cli import add_links
from .engine import Engine


PAGE = r"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>YunX Linux</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--line:#e3e6eb;--text:#1c2430;--muted:#6b7583;--accent:#2563eb;--ok:#16a34a;--warn:#d97706;--bad:#dc2626}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
header{background:var(--card);border-bottom:1px solid var(--line);padding:14px 24px;display:flex;align-items:center;gap:14px;position:sticky;top:0;z-index:2}
h1{font-size:17px;margin:0}.tag{font-size:12px;color:var(--muted)}.spacer{flex:1}
button{border:1px solid var(--line);background:#fff;color:var(--text);border-radius:6px;padding:6px 12px;cursor:pointer;font-size:13px}
button:hover{border-color:var(--accent);color:var(--accent)}button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
button:disabled{opacity:.45;cursor:not-allowed}input,select{border:1px solid var(--line);border-radius:6px;padding:7px 9px;font-size:13px;background:#fff;color:var(--text)}
main{max-width:1120px;margin:22px auto;padding:0 18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:18px;margin-bottom:16px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}.grow{flex:1;min-width:260px}
label{color:var(--muted);font-size:12px;display:block;margin-bottom:4px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px 8px;border-bottom:1px solid var(--line);font-size:13px;vertical-align:middle}
th{color:var(--muted);font-weight:500;white-space:nowrap}tr:last-child td{border-bottom:0}
.bar{height:7px;background:#edf0f4;border-radius:4px;overflow:hidden;min-width:120px}.bar>i{display:block;height:100%;background:var(--accent)}
.st{font-size:12px;padding:2px 8px;border-radius:10px;background:#eef2f7;white-space:nowrap}.st.running{color:var(--accent)}.st.completed{color:var(--ok)}.st.waitingRetry,.st.paused{color:var(--warn)}.st.failed{color:var(--bad)}
.msg{font-size:12px;color:var(--muted);margin-top:4px;word-break:break-all}
.code{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:var(--muted)}
#notice{position:fixed;right:18px;bottom:18px;background:#1f2937;color:#fff;padding:10px 14px;border-radius:8px;opacity:0;transition:opacity .25s;pointer-events:none;z-index:5}
#notice.show{opacity:1}
</style></head><body>
<header><h1>YunX Linux</h1><span class="tag">v__VERSION__</span><span class="spacer"></span>
<span class="tag" id="loginTag">百度：未检测</span><button id="loginBtn">扫码登录</button></header>
<main>
<section class="card"><div class="row">
  <div class="grow"><label>分享链接 / 直链（可一次粘贴多条，每行一条）</label><input id="link" placeholder="https://pan.baidu.com/s/1xxxx?pwd=abcd" style="width:100%"></div>
  <div><label>提取码</label><input id="code" placeholder="可选" style="width:100px"></div>
  <div><label>下载目录</label><input id="directory" placeholder="留空用默认" style="width:180px"></div>
  <button class="primary" id="addBtn">添加任务</button>
</div><div class="msg" id="hint">百度链接需先登录；登录态只保存在本机 ~/.config/yunx</div></section>

<section class="card"><div class="row"><strong>任务列表</strong><span class="spacer"></span>
<button id="pauseAll">全部暂停</button><button id="resumeAll">全部继续</button><button id="refresh">刷新</button></div>
<table><thead><tr><th style="width:36%">文件</th><th style="width:22%">进度</th><th>状态</th><th>速度</th><th style="width:130px">操作</th></tr></thead>
<tbody id="rows"><tr><td colspan="5" class="msg">加载中…</td></tr></tbody></table></section>

<section class="card"><strong>设置</strong><div class="row" style="margin-top:12px">
<div><label>并发连接数</label><input id="connections" type="number" min="1" max="32" style="width:90px"></div>
<div><label>限速 KB/s（0 不限）</label><input id="speed" type="number" min="0" style="width:120px"></div>
<label style="display:flex;align-items:center;gap:6px;margin-top:18px"><input id="autoRetry" type="checkbox"> 断线自动重试</label>
<button class="primary" id="saveSettings">保存设置</button></div></section>
</main><div id="notice"></div>
<script>
const $ = id => document.getElementById(id);
let lastSettings = '';
function size(n){n=Number(n)||0;for(const u of ['B','KB','MB','GB']){if(n<1024||u==='GB')return u==='B'?Math.round(n)+' B':n.toFixed(1)+' '+u;n/=1024}return n.toFixed(1)+' GB'}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function toast(t){const n=$('notice');n.textContent=t;n.classList.add('show');clearTimeout(n.timer);n.timer=setTimeout(()=>n.classList.remove('show'),2600)}
async function api(path, body){const r=await fetch(path,{method:body?'POST':'GET',headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});return r.json()}
function render(d){
  const login=d.login||{};const logged=!!d.loggedIn;
  $('loginTag').textContent=logged?'百度：已登录':'百度：未登录';
  $('loginBtn').textContent=login.state==='waiting'?'等待登录…':(login.state==='starting'?'启动中…':'扫码登录');
  $('loginBtn').disabled=login.state==='starting'||login.state==='waiting';
  if(login.message && login.state==='error') $('hint').textContent=login.message;
  if(login.state==='success'){toast(login.message);$('hint').textContent='登录成功，可以直接添加百度分享链接';}
  const rows=$('rows');
  if(!d.tasks.length){rows.innerHTML='<tr><td colspan="5" class="msg">还没有任务，在上方粘贴链接即可开始</td></tr>';}
  else rows.innerHTML=d.tasks.map(t=>{
    const p=Math.round((t.progress||0)*100);
    let detail='';
    if(t.status==='waitingRetry') detail=`第 ${t.retry_count} 次 · ${Math.max(0,Math.round(t.nextRetryIn))} 秒后重试`;
    else if(t.status==='failed') detail=t.error||'';
    else if(t.note) detail=t.note;
    const btns=t.status==='running'?`<button data-act="pause" data-id="${t.id}">暂停</button>`:
      (t.status==='completed'?'':`<button data-act="resume" data-id="${t.id}">继续</button>`)+
      `<button data-act="rm" data-id="${t.id}">删除</button>`;
    return `<tr><td><div>${esc(t.file_name)}</div><div class="msg">${size(t.received)} / ${size(t.total_size)} <span class="code">${t.id.slice(0,8)}</span></div></td>
    <td><div class="bar"><i style="width:${p}%"></i></div><div class="msg">${p}%</div></td>
    <td><span class="st ${t.status}">${esc(t.statusLabel)}</span>${detail?`<div class="msg">${esc(detail)}</div>`:''}</td>
    <td>${t.speed?size(t.speed)+'/s':'—'}</td><td>${btns}</td></tr>`;
  }).join('');
  const key=JSON.stringify(d.settings);
  if(key!==lastSettings){lastSettings=key;$('connections').value=d.settings.connections;$('speed').value=d.settings.speed_limit_kbps;$('autoRetry').checked=!!d.settings.auto_retry;}
}
async function refresh(){try{render(await api('/api/state'))}catch(e){toast('无法连接本地服务：'+e)}}
$('addBtn').onclick=async()=>{const body={link:$('link').value.trim(),code:$('code').value.trim(),directory:$('directory').value.trim()};if(!body.link)return toast('请先粘贴链接');toast('正在解析…');const r=await api('/api/tasks',body);toast(r.ok?'已添加 '+r.added+' 个任务':r.error);if(r.ok){$('link').value='';$('code').value='';refresh()}};
$('loginBtn').onclick=async()=>{const r=await api('/api/login',{});toast(r.ok?'请在弹出的浏览器中扫码登录':r.error);refresh()};
$('pauseAll').onclick=async()=>{await api('/api/tasks/all/pause',{});refresh()};
$('resumeAll').onclick=async()=>{await api('/api/tasks/all/resume',{});refresh()};
$('refresh').onclick=refresh;
$('saveSettings').onclick=async()=>{const r=await api('/api/settings',{connections:+$('connections').value,speed_limit_kbps:+$('speed').value,auto_retry:$('autoRetry').checked});toast(r.ok?'设置已保存':r.error);refresh()};
$('rows').onclick=async e=>{const b=e.target.closest('button[data-act]');if(!b)return;const r=await api('/api/tasks/'+encodeURIComponent(b.dataset.id)+'/'+b.dataset.action,{});if(!r.ok)toast(r.error);refresh()};
refresh();setInterval(refresh,1000);
</script></body></html>""".replace("__VERSION__", __version__)


class WebApp:
    def __init__(self, engine: Engine, port: int = 8899, bind: str = "127.0.0.1",
                 logger=None):
        self.engine = engine
        self.port = int(port)
        self.bind = bind
        self.logger = logger or (lambda message: None)
        app = self

        class Handler(BaseHTTPRequestHandler):
            server_version = "YunX/1.0"

            def log_message(self, fmt, *args):
                app.logger("web: " + (fmt % args))

            def _json(self, value, status=200):
                body = json.dumps(value, ensure_ascii=False).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def _body(self) -> dict:
                try:
                    length = int(self.headers.get("Content-Length") or 0)
                    if not length:
                        return {}
                    value = json.loads(self.rfile.read(length).decode("utf-8"))
                    return value if isinstance(value, dict) else {}
                except Exception:
                    return {}

            def do_GET(self):
                path = urlsplit(self.path).path
                if path in ("/", "/index.html"):
                    body = PAGE.encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                elif path == "/api/state":
                    self._json(app.state())
                else:
                    self._json({"error": "not found"}, 404)

            def do_POST(self):
                path = urlsplit(self.path).path
                body = self._body()
                try:
                    if path == "/api/tasks":
                        engine, added = add_links(body.get("link", ""), body.get("code"),
                                                  body.get("directory"), engine=app.engine)
                        self._json({"ok": True, "added": len(added),
                                    "notes": [note for _, note in added if note]})
                    elif path.startswith("/api/tasks/"):
                        parts = [unquote(part) for part in path.split("/") if part]
                        # parts = ["api", "tasks", "<id>", "<action>"]
                        if len(parts) != 4:
                            self._json({"error": "bad path"}, 400)
                            return
                        task_id, action = parts[2], parts[3]
                        targets = (app.engine.all_tasks() if task_id == "all" else
                                   [next((t for t in app.engine.all_tasks()
                                          if t.id.startswith(task_id)), None)])
                        count = 0
                        for task in targets:
                            if not task:
                                continue
                            if action == "pause":
                                count += 1 if app.engine.pause(task.id) else 0
                            elif action == "resume":
                                count += 1 if app.engine.resume(task.id) else 0
                            elif action == "rm":
                                count += 1 if app.engine.remove(task.id) else 0
                        self._json({"ok": count > 0, "count": count})
                    elif path == "/api/settings":
                        self._json({"ok": True, "settings": app.engine.update_settings(body)})
                    elif path == "/api/login":
                        cookiestore.login_auto_async(headless=bool(body.get("headless")))
                        self._json({"ok": True})
                    elif path == "/api/login/status":
                        self._json(cookiestore.login_status())
                    else:
                        self._json({"error": "not found"}, 404)
                except Exception as exc:
                    self._json({"ok": False, "error": str(exc)})

        self.server = ThreadingHTTPServer((bind, self.port), Handler)
        self.port = self.server.server_address[1]  # 端口 0 时拿到实际端口（测试用）
        self.thread = None

    def state(self) -> dict:
        tasks = []
        now = time.time()
        for task in sorted(self.engine.all_tasks(), key=lambda t: t.created_at, reverse=True):
            data = task.to_dict()
            data.update(speed=task.speed, progress=task.progress, received=task.received,
                        statusLabel=task.status_label,
                        nextRetryIn=max(0, task.next_retry_at - now))
            tasks.append(data)
        login = cookiestore.login_status()
        return {
            "version": __version__,
            "settings": dict(self.engine.settings),
            "tasks": tasks,
            "login": login,
            "loggedIn": cookiestore.has_login(),
        }

    def start(self) -> None:
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       name="yunx-web", daemon=True)
        self.thread.start()

    def run_forever(self) -> None:
        self.start()
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            self.stop()

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
