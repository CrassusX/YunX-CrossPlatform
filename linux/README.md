# YunX Linux

Mac 版下载引擎的 Linux 移植：**纯 Python 标准库，零第三方依赖**，Python 3.8+ 即可运行。
提供命令行与本地网页面板，支持百度网盘分享链接和 http(s) 直链。

## 安装

从统一 Release 下载 Linux 包（与 macOS 版在同一个 tag 下）：

```bash
# https://github.com/CrassusX/YunX-CrossPlatform/releases/latest
# 下载 YunX-Linux-<版本>.tar.gz 与同名 .sha256，先校验再解压
sha256sum -c YunX-Linux-1.5.0.tar.gz.sha256

tar -xzf YunX-Linux-1.5.0.tar.gz
cd YunX-Linux-1.5.0
./scripts/install.sh          # 默认装到 ~/.local，不需要 root
yunx doctor                   # 检查环境
```

装到其他位置：`YUNX_PREFIX=/opt/yunx ./scripts/install.sh`。
卸载：`./scripts/uninstall.sh`（不会删除你的登录态、任务记录和下载文件）。

## 登录（浏览器扫码）

```bash
yunx login                    # 打开浏览器，扫码/输密码，自动抓取 Cookie
yunx login --firefox          # 若已在 Firefox 登录，可直接导入
```

自动登录需要本机有浏览器驱动：

```bash
# Debian / Ubuntu
sudo apt install chromium-driver
# Fedora
sudo dnf install chromedriver
# Firefox
sudo apt install firefox-esr firefox-geckodriver
```

驱动版走完整的浏览器登录流程，扫码即可；无头服务器没有图形界面时请用
`yunx login --firefox` 从已登录的 Firefox 导入。`yunx login --headless-driver`
只能应付纯密码登录，扫不了码。

Cookie 保存在 `~/.config/yunx/cookies.txt`（Netscape 格式，权限 600）。

## 使用

```bash
yunx add 'https://pan.baidu.com/s/1AbCdEf?pwd=1234'
yunx ls
yunx run                      # 前台长驻，Ctrl-C 保存断点退出
yunx run --web                # 同时打开本地面板 http://127.0.0.1:8899
yunx pause <任务ID前缀>
yunx resume <任务ID前缀>
yunx rm <任务ID前缀> --delete-file
yunx settings --connections 8 --speed 500
yunx clean                    # 清理网盘里的 /来自分享
```

网页面板支持粘贴链接、查看进度/速度/重试次数、暂停/继续/删除、修改并发与限速、
以及点击「扫码登录」。面板只绑定 `127.0.0.1`。

想后台常驻可用 `systemd/yunx.service`（用户级）：

```bash
mkdir -p ~/.config/systemd/user
cp systemd/yunx.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now yunx
```

## 下载引擎

和 Mac 版 v1.5.0 同一套策略：

- 多分片并发、每片独立 `pwrite`，退出/重启后从断点续传
- **多文件分享递归下载**：自动展开整棵目录树，转存整树后每个文件一个任务，
  本地按 `下载目录/<分享名>/<子目录>/` 保持目录结构；直链过期按网盘文件重取，不会拿错文件
- 限速令牌桶，等待可被暂停打断
- **把限流的「206 + 0 字节」单独识别**：不消耗 30 次重连额度，退避 30 s 起、最长 180 s
- 连续空响应直接把并发压到 1，新建连接间隔 0.4 s，从源头减少踩限流
- 连接 60 s 零字节判定僵死并重连；5xx / 408 / 425 / 429 重试，403 / 404 / 410 直接失败
- 直链过期（403）时若保留了原始分享链接，会自动重新解析
- 任务级退避 2 s 起、封顶 5 分钟，恢复后自动继续

## 测试

```bash
python3 -m unittest discover -s tests -v
```

19 项测试全部通过，覆盖：正常分片、每 16 KB 强断重连、空响应限流、5xx 重试、
403 不重试、Range 被忽略降级、断点续传、限速精度、任务级重试、暂停与重启恢复、
删除、链接解析、Cookie 往返、百度五步接口参数（含二次编码陷阱）、
**百度多文件递归（目录树展开 / 整树转存 / 相对路径对齐 / 批量 dlink / 子目录落盘 / pan_fs_id 刷新）**、
Web API 与 CLI。

## 已知限制

- 目前只实现百度分享 + 直链；夸克/UC 尚未移植（Mac 版本身也未做真机验证）
- 百度免费账号限制的是**账号/IP 总速**（约 100 KB/s），加并发不会提速
- 自动登录依赖本机浏览器驱动；没有图形界面时无法扫码
- 下载网盘文件时建议关闭代理：代理一断会让所有分片同时断，重连风暴又容易触发限流
- 多文件分享递归上限 200 个文件 / 60 个目录，超大分享会截断并在任务备注里提示
