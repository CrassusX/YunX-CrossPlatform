import Foundation

/// 全局限速器：漏桶 + 预约时间片。
///
/// 每个写入方在写盘前调用 `acquire(bytes)`，它会把"这个数据块允许被消费的时间点"
/// 往后排，然后在时间点之前阻塞。这样多线程并发下载时，总体速率严格收敛到设定值，
/// 而不会出现每个线程各限一份、合计超限的问题。
final class Throttle {

    static let shared = Throttle()

    private let lock = NSLock()
    private var rate: Int64 = 0            // bytes / second，0 表示不限速
    private var nextAvailable: Double = 0  // 单调时钟（秒）

    /// 允许的最大积压时长，防止暂停后恢复时"补课"冲量过大
    private let maxBurst: Double = 1.0

    func setLimit(bytesPerSecond: Int64) {
        lock.lock()
        rate = max(0, bytesPerSecond)
        if rate > 0 { nextAvailable = max(nextAvailable, now()) }
        lock.unlock()
    }

    var currentLimit: Int64 {
        lock.lock(); defer { lock.unlock() }
        return rate
    }

    /// 阻塞直到该数据块被允许消费；不限速时立即返回。
    /// `isCancelled` 会被切成小片轮询，保证暂停时能尽快退出。
    func acquire(_ bytes: Int, isCancelled: (() -> Bool)? = nil) {
        guard bytes > 0 else { return }

        lock.lock()
        let limit = rate
        guard limit > 0 else { lock.unlock(); return }

        let current = now()
        if nextAvailable < current { nextAvailable = current }
        if nextAvailable - current > maxBurst { nextAvailable = current + maxBurst }

        let start = nextAvailable
        nextAvailable += Double(bytes) / Double(limit)
        lock.unlock()

        var remaining = start - now()
        while remaining > 0 {
            if isCancelled?() == true { return }
            Thread.sleep(forTimeInterval: min(remaining, 0.02))
            remaining = start - now()
        }

        // 结算：Thread.sleep 有毫秒级最小粒度，小块数据每块都睡会累积成明显偏差
        // （实测会让 2MB/s 只跑到 1MB/s）。把睡过头的时间从后续调度里扣回来。
        let finished = now()
        if finished > start {
            lock.lock()
            nextAvailable = max(now(), nextAvailable - (finished - start))
            lock.unlock()
        }
    }

    private func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
