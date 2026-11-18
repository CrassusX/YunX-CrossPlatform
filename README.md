# 云析 · macOS 版

> 粘贴链接，直接高速下载 —— 参考 [YunX-Desktop](https://github.com/tidain/YunX-Desktop) 的设计，用 Swift + SwiftUI 原生重写的 macOS 客户端。

通用二进制，**Apple 芯片（arm64）与 Intel 芯片（x86_64）同包原生运行**，单个 DMG 1.3 MB。

![主界面](docs/screenshot-main.png)

---

## 这是什么

原项目 [YunX-Desktop](https://github.com/tidain/YunX-Desktop) 是基于 Kotlin + Compose Multiplatform 的 **Windows** 桌面端，深度绑定 Windows 运行时（JNA 调 Win32、`darkmode.dll`、JCEF Windows 原生库、Inno Setup 打包）。

本项目不是简单的「改个构建目标」，而是用 Swift + SwiftUI **从零重写** 一个 macOS 原生实现，保留核心的下载能力与交互形态，去掉所有 Windows 依赖：

| | YunX-Desktop | 本项目 |
|---|---|---|
| 语言 / UI | Kotlin + Compose Multiplatform | Swift + SwiftUI |
| 运行时 | JVM + jlink + jpackage | 无运行时，原生二进制 |
| 安装包 | Inno Setup（.exe） | DMG（拖拽安装） |
| 体积 | 100 MB+（含 JRE / CEF） | 1.3 MB |
| 架构 | Windows x64 | arm64 + x86_64 通用 |

## 功能现状

### 已实现并已验证

| 能力 | 说明 |
|---|---|
| **分片并发下载** | 单任务多连接 Range 并行。40 MB 测试文件 8 分片，实测 ~17 MB/s |
| **断点续传** | 每个分片的已落盘字节实时记录，退出应用、重启后仍从断点续传（实测 16 MB 处暂停 → 恢复 → SHA-256 与原文件完全一致） |
| **全局限速** | 基于「时间片预约」的精确限速，多任务共享总带宽，不会按任务叠加。实测 2 MB/s 档位 40 MB 用时 17.9 s（理论 19.1 s） |
| **链接识别** | 本地规则识别夸克 / UC / 百度 / 蓝奏云 / 123 / 115 / 迅雷 / 139 / 阿里云盘、B 站 / 抖音 / 小红书 / 微博 / 快手 / AcFun / Pixiv、GitHub、磁力 / eD2k / BT 种子、HTTP 直链；自动提取 `提取码 / 密码 / pwd` |
| **GitHub 镜像测速** | 并发实测各 gh-proxy 镜像的握手延迟与真实吞吐，自动选最快；支持固定某个或自定义前缀 |
| **多任务队列** | 可配置同时下载任务数，排队自动放行 |
| **任务持久化** | 任务列表与分片进度落盘到 `~/Library/Application Support/YunX-Mac-Desktop/tasks.json`，重启恢复 |
| **原生集成** | 系统通知、Finder 定位、拖拽链接进窗口、剪贴板识别、深浅色自适应 |

### 尚未实现

网盘与视频平台的**私有解析接口**（真正把分享链接换成可下载直链那一步）本版本没有做。原因很直接：

- 这些接口需要登录态 Cookie（账号凭证），且接口本身未公开、随平台改版频繁变动；
- 无账号、无接口文档的情况下硬写，交付的只会是「看起来有功能但一用就报错」的假实现。

所以本版本的处理是：**完整识别来源、提取提取码、一键带码在浏览器打开**，把「解析」留成可插拔的扩展点（见下方 `Resolver` 设计）。要补齐这部分，需要你提供目标平台的账号，逐个平台做真机联调。

磁力 / BT / eD2k 同理，仅做识别，请交给专用工具（原项目也是把 P2P 交给 Gopeed 引擎）。

## 安装

从 [Releases](https://github.com/CrassusX/YunX-Mac-Desktop/releases) 下载 `YunX-Mac-Desktop-<版本>.dmg`，打开后把 app 拖进「应用程序」。

应用使用 **ad-hoc 签名**（没有 Apple 开发者证书），首次打开会被 Gatekeeper 拦下，两种解法：

```bash
# 方式一：命令行去掉隔离标记（推荐）
xattr -dr com.apple.quarantine /Applications/YunX-Mac-Desktop.app

# 方式二：右键点 app → 打开 → 在弹窗里再点「打开」
```

## 从源码构建

要求：macOS 13+、Xcode（或 Command Line Tools，但**通用二进制必须装完整 Xcode**，因为 SPM 的多架构构建依赖 xcbuild）。

```bash
git clone https://github.com/CrassusX/YunX-Mac-Desktop.git
cd YunX-Mac-Desktop

# 一键产出 .app 与 .dmg（自动编译 arm64 + x86_64 并 lipo 合并）
./scripts/build-app.sh

# 只要 .app
./scripts/build-app.sh --no-dmg

# 开发时直接跑（单架构，快）
swift build --disable-sandbox && swift run --disable-sandbox
```

产物：

```
dist/YunX-Mac-Desktop.app            # 通用二进制 app
dist/YunX-Mac-Desktop-1.0.0.dmg      # 分发包
```

> `--disable-sandbox` 是因为 SPM 编译 manifest 时会调用 `sandbox-exec`，在部分受限环境下会失败；正常开发机上可以省略。

## 架构

```
Sources/YunXMac/
├── App/
│   └── YunXMacApp.swift        # @main、菜单命令、配色
├── Core/                       # 与 UI 完全解耦，可单独测试
│   ├── Models.swift            # Provider / SegmentState / DownloadRecord
│   ├── LinkParser.swift        # 链接抽取、来源识别、提取码解析（纯本地）
│   ├── Prober.swift            # 只取响应头的探针：长度、Range 支持、文件名
│   ├── SegmentedDownloader.swift # 分片下载引擎（核心）
│   ├── Throttle.swift          # 全局时间片预约限速器
│   ├── DownloadManager.swift   # 任务池：排队、暂停恢复、持久化
│   ├── MirrorTester.swift      # 镜像延迟 + 吞吐实测
│   ├── AppSettings.swift       # UserDefaults 持久化设置
│   └── Notifier.swift          # 系统通知
└── UI/                         # SwiftUI 视图，只读 Manager 状态
```

### 下载引擎的三个关键决策

**1. 一个写线程独占所有写盘操作。**
网络回调（`URLSessionDataDelegate`）只把数据塞进内存缓冲队列；写盘、限速、重试调度全部在单条写线程里串行完成。分片写入是有序的，不会错位；同时写线程天然就是任务调度器。

**2. 背压而不是死扛。**
缓冲超过高水位（32 MB）就 `suspend()` 数据任务，降到低水位（8 MB）再 `resume()`。限速到 100 KB/s 时内存占用依然平稳，不会把整个文件堆进内存。

**3. 回调永不跑在写线程上。**
进度与完成回调统一走独立队列。否则调用方在 `onProgress` 里调 `pause()` 会等自己 → 死锁。（这个 bug 是在实现过程中真实踩到并修掉的。）

更多细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

### 扩展点：接网盘解析

新增一个平台不需要动 UI 和下载引擎，只要实现一个 resolver 把分享链接换成直链：

```swift
protocol Resolver {
    var provider: Provider { get }
    func resolve(link: ParsedLink) async throws -> ResolvedTarget
}

struct ResolvedTarget {
    var url: URL              // 可直链下载的地址
    var fileName: String
    var headers: [String: String]   // Cookie / Referer 等
}
```

拿到 `ResolvedTarget` 后交给 `DownloadManager.enqueue(...)`，分片、续传、限速全部复用。

## 目录里还有什么

```
scripts/make-icon.swift    # 用 CoreGraphics 直接按像素尺寸画图标，不缩放
scripts/build-app.sh       # 编译 → 组 .app → 签名 → 打包 DMG
.github/workflows/build.yml# CI：每次提交构建通用包，打 tag 自动发 Release
docs/ARCHITECTURE.md       # 引擎与队列设计细节
```

## 已知限制

- 网盘 / 视频平台私有解析未实现（见上文说明）。
- 服务器不支持 `Range` 时降级为单连接，此时「续传」等于重新下载。
- 未做公证（notarization），首次运行需手动绕过 Gatekeeper。
- 镜像测速结果是**当下**网络状况；镜像站点随时可能失效，可在设置里换。

## 与参考项目的关系

功能形态参考 [tidain/YunX-Desktop](https://github.com/tidain/YunX-Desktop)（与安卓版 [CYQawa/YunX](https://github.com/CYQawa/YunX) 同属云析项目）。本项目**没有复制其源码**，是用 Swift 独立实现，但设计思路与交互习惯受益于它，在此致谢。

云析项目坚持免费开源，任何收费版本都是二次打包的诈骗版本。本项目同样以 **AGPL-3.0** 开源。

## 许可证

[GNU AGPL-3.0](LICENSE)

仅供个人学习与合法用途。请遵守各平台服务条款，不要用于传播侵权内容。
