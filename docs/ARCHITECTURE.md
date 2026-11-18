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
