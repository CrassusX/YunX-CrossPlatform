# 架构说明

## 分层

```
UI (SwiftUI)  ──观察──>  DownloadManager (@MainActor)  ──驱动──>  SegmentedDownloader
                              │                                        │
                              │                                        ├─ Prober（只读响应头）
                              ├─ AppSettings（UserDefaults）            ├─ Throttle（全局限速）
                              ├─ tasks.json（任务持久化）               └─ URLSession（分片请求）
                              └─ Notifier（系统通知）
```

`Core/` 里除了 `DownloadManager` 依赖 SwiftUI（只为 `NSWorkspace` 打开 Finder），其余全部与 UI 无关，可以单独编译成命令行测试程序验证。

## 下载引擎

### 状态划分

一个任务被切成 N 个闭区间分片（`SegmentState { start, end, received }`）。`received` 就是该分片**已落盘的字节数**，它同时是进度、续传起点和完整性判据：

```
续传起点 = start + received
剩余区间 = [start + received, end]
```

暂停时把 `segments` 序列化进 `tasks.json`，恢复时原样读出来继续发 Range 请求。不需要额外的 `.part` 索引文件。

数据直接写进一个预分配（稀疏）的临时文件，每个分片按自己的偏移写入，因此**没有「下载完再合并」这一步**，完成时只需要 `rename` 成最终文件名。

### 线程模型

只有两类线程：

1. **URLSession 的 delegate 队列**（串行）：只做一件事——把收到的 `Data` 追加进对应分片的缓冲队列，然后 `signal` 写线程。
2. **写线程**（每个任务一条）：循环做四件事
   - 若某分片没有在跑的任务且还有剩余区间 → 建任务并 `resume()`
   - 若有缓冲数据 → 取出来，限速等待，`seek + write`，更新 `received`
   - 若全部分片完成 → 收尾
   - 否则 `wait`

由写线程统一决定「谁来写、写到哪、什么时候写」，所以不存在两个线程同时改同一分片偏移的可能。

### 为什么回调必须离开写线程

进度回调最初直接在写线程里调。结果 `pause()` 里要 `wait` 写线程退出，而 `pause()` 又是在回调里被调用的 → 自己等自己，死锁。

现在所有对外回调统一 `callbackQueue.async` 派发，写线程从不执行外部代码。

### 背压

限速时写线程会比网络慢，缓冲会涨。超过 32 MB 就 `suspend()` 正在跑的数据任务，降到 8 MB 以下再 `resume()`。内存占用因此是有界的，而不是「文件多大内存占多大」。

### 重试

- 分片短读（连接提前断开）：保留已下载部分，从 `nextOffset` 重新发请求，最多 6 次，退避 0.8s × 次数。
- HTTP 4xx/5xx：直接判失败并给出可读原因。
- 服务器对 `Range: bytes=N-` 返回 200（无视 Range）：判失败并提示「不支持断点续传」，不会把整个文件从 0 写进去造成数据错位。

## 限速器

朴素做法是「每块数据 `sleep(块大小 / 速率)`」，但 `Thread.sleep` 有毫秒级最小粒度，小块数据下误差会累积——实测 2 MB/s 只能跑到 1 MB/s。

现在用**时间片预约**：每个调用方先向限速器预约一段「允许开始写入的时刻」，然后睡到那个时刻。

```
target      = nextAvailable
nextAvailable += bytes / rate
sleep(target - now)
```

再把「睡过头」的时间从 `nextAvailable` 里扣回去，抵消系统调用的粒度误差。实测 2 MB/s 档位 40 MB 用时 17.9 s（理论 19.1 s）。

因为所有任务共享同一个 `Throttle` 实例，限速是**全局总量**，不随任务数叠加。

## 任务池

`DownloadManager` 是 `@MainActor` 的，全部状态变更都在主线程，避免 UI 与后台线程抢同一份数据。

- 新建任务先做一次探针（`Range: bytes=0-0` 只取响应头），拿到长度、Range 支持情况和文件名后才建分片。
- `pump()` 按 `maxConcurrentTasks` 放行排队任务。
- `pause()` 会把阻塞等待放到后台任务里做，不卡主线程。
- 保存做了 1 秒合并，避免下载时每 0.25 秒写一次磁盘。

## 镜像测速

`MirrorTester` 对每个前缀并发发起一次 1.5 MB 的 Range 请求，采样到截止时间就取消，记录 TTFB 与吞吐。评分 `1 / 延迟 × 400 + 吞吐 × 0.6`，取最高分作为自动镜像。

套用方式就是最常见的 gh-proxy 格式：

```
https://ghfast.top/https://github.com/owner/repo/releases/download/...
```

---

## 网盘解析层

### 分层

```
LinkParser          识别来源 + 提取提取码（纯本地，不发网络请求）
      ↓
PanAccountStore     凭证内存态，界面观察它
      ↓
PanCredentialStore  Keychain 持久化（service: cn.yunxmac.pan-credential）
      ↓
PanLoginSheet       内置 WKWebView 登录窗，轮询 cookie store 判定登录成功
      ↓
PanResolver 协议    每家一个实现：先 preview() 拿文件列表，再 resolve() 换直链
      ↓
ResolvedFile        { 直链, 文件名, 大小, 必需的请求头 }
      ↓
DownloadManager.enqueue(extraHeaders:knownSize:)   请求头随任务持久化
```

### 为什么不复用全局 URLSession

`PanHTTP` 是解析专用的轻量客户端：`httpShouldSetCookies = false`、手动维护 cookie 字典。原因有两个：

1. 解析过程会在同一个会话里连续做「验提取码 → 列目录 → 转存」，中间产生的 `BDCLND` 等 cookie 必须精确跟着走，交给系统的 cookie storage 反而不好控制时序；
2. 不污染应用其余请求的 cookie 状态。

### 凭证存储

只存解析直链必需的会话 cookie，**密码从没经过我们**——用户是在应用内嵌的 `WKWebView` 里直接登给平台自己的。

判定「真的登录了」不能看有没有 cookie（游客态也有 `BAIDUID`），要看平台特有的登录标记：

| 平台 | 判定 cookie |
|---|---|
| 百度 | `BDUSS` / `BDUSS_BFESS` / `STOKEN` |
| 夸克 | `__puus` / `__pus` / `__kp` |
| UC | `__puus` / `__pus` |

写入时过滤空名与 `undefined`：`Set-Cookie` 的解析边界上偶尔会混进 `undefined=`，这种脏 key 会让后续所有请求的 Cookie 头失效。

### 转存策略（百度）

百度现在只对「自己网盘里」的文件发可用 dlink，所以下载前必须落一份到用户网盘。设计上做了三点收敛：

1. **幂等**：转存前先 `/api/search` 按「文件名 + 大小」查一遍，命中就复用，不重复写盘；
2. **可回收**：统一落在 `/来自分享/<文件名>/` 下，便于一键清理（`BaiduPanResolver.cleanTransferred`）；
3. **透明**：note 里明确告诉用户文件在哪、是复用的还是新转存的。

### 请求头必须随任务持久化

网盘直链会校验 `Referer` / `Cookie` / `User-Agent`，缺一个就 403。这些头写进了 `DownloadRecord.requestHeaders`，因为**断点续传跨应用重启**——如果只存在内存里，重启后恢复下载会全部失败。
