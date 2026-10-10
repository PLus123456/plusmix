import Darwin
import Foundation
import SwitcherContracts
import Synchronization

/// 把 `Stats` 追加写进 stats.jsonl（测试标准 §2.4：每秒一行）。
///
/// 线程模型：`submit` 把一行放进 SPSC 队列后立刻返回（无锁、不分配额外内存、不等磁盘），写线程被信号量唤醒后
/// 出队、编码、`write(2)` 追加。队列满了这一行就丢（`droppedLines` 计数）——统计线程宁可少一行也不能等磁盘。
/// `submit` 只能由一个线程调（引擎每秒汇总的那个普通线程）；`close` 等队列写完再关文件。
/// 非有限的浮点（NaN / inf）`Stats.jsonLine()` 会抛错，这里先换成 0 并计 `sanitizedLines`（契约要求写入方处理）。
public final class StatsWriter: @unchecked Sendable {
    /// 输出文件。
    public let url: URL
    private let queue: SPSCQueue<Stats>
    private let wake = DispatchSemaphore(value: 0)
    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private let written = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let sanitized = Atomic<Int>(0)
    private let fd: Int32
    private var writerThread: Thread?
    private var samplerThread: RealtimeThread?
    private var closed = false

    /// - Parameters:
    ///   - queueCapacity: 队列深度（默认 64 = 一分钟的行）。
    ///   - append: true 追加到已有文件，false 清空重写。
    public init(url: URL, queueCapacity: Int = 64, append: Bool = true) throws {
        self.url = url
        queue = SPSCQueue(capacity: queueCapacity)
        let flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC)
        fd = open(url.path, flags, 0o644)
        guard fd >= 0 else { throw WriterError.openFailed(url, errno) }
        let t = Thread { [self] in writerLoop() }
        t.name = "stats-writer"
        t.qualityOfService = .utility
        writerThread = t
        t.start()
    }

    deinit { close() }

    public enum WriterError: Error { case openFailed(URL, Int32) }

    /// 已写入文件的行数。
    public var writtenLines: Int { written.load(ordering: .acquiring) }
    /// 队列满被丢的行数。
    public var droppedLines: Int { dropped.load(ordering: .acquiring) }
    /// 含 NaN / inf 被替换成 0 的行数。
    public var sanitizedLines: Int { sanitized.load(ordering: .acquiring) }

    /// 非阻塞入队；队列满返回 false 并计 droppedLines。
    @discardableResult
    public func submit(_ stats: Stats) -> Bool {
        if queue.push(stats) {
            wake.signal()
            return true
        }
        dropped.wrappingAdd(1, ordering: .relaxed)
        return false
    }

    /// 起一条采样线程：每 `interval` 秒调一次 `sampler`（在采样线程上，不在调用者线程上），结果 submit。
    /// sampler 返回 nil 表示这次不写。默认 1 Hz，就是测试标准 §2.4 的"每秒一行"。
    public func startSampling(every interval: TimeInterval = 1, _ sampler: @escaping @Sendable () -> Stats?) {
        guard samplerThread == nil else { return }
        let periodNs = UInt64(interval * 1e9)
        let t = RealtimeThread(name: "stats-sampler", periodNanoseconds: periodNs) { [self] thread in
            var next = HostClock.now()
            while !thread.isStopRequested {
                next += HostDuration(nanoseconds: Int64(periodNs))
                RealtimeThread.wait(until: next)
                if thread.isStopRequested { break }
                if let s = sampler() { submit(s) }
            }
        }
        samplerThread = t
        t.start()
    }

    /// 停采样线程、等队列写空、关文件。可重复调用。
    public func close() {
        guard !closed else { return }
        closed = true
        samplerThread?.stop()
        samplerThread = nil
        stopFlag.store(true, ordering: .releasing)
        wake.signal()
        finished.wait()
        writerThread = nil
        Darwin.close(fd)
    }

    private func writerLoop() {
        while true {
            _ = wake.wait(timeout: .now() + 1)
            drain()
            if stopFlag.load(ordering: .acquiring) {
                drain()
                break
            }
        }
        finished.signal()
    }

    private func drain() {
        while let s = queue.pop() {
            var line: String
            do {
                line = try s.jsonLine()
            } catch {
                line = (try? StatsWriter.sanitized(s).jsonLine()) ?? ""
                sanitized.wrappingAdd(1, ordering: .relaxed)
            }
            guard !line.isEmpty else { continue }
            line.append("\n")
            var data = Array(line.utf8)
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeMutableBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
                if n <= 0 { break }
                offset += n
            }
            written.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// 把非有限的浮点换成 0；表里的 dB / LUFS 换成下限 −120（提案 004 的口径，JSON 写不了 −inf）。
    static func sanitized(_ s: Stats) -> Stats {
        func fix(_ v: Double) -> Double { v.isFinite ? v : 0 }
        func fixDb(_ v: Double) -> Double { v.isFinite ? v : Stats.AudioCounters.Meters.floorDb }
        var out = s
        out.ts = fix(s.ts)
        out.renderMs = fix(s.renderMs)
        out.jitterMs = fix(s.jitterMs)
        out.rssMb = fix(s.rssMb)
        out.cpuPct = fix(s.cpuPct)
        out.gpuPct = fix(s.gpuPct)
        out.videoDelayMs = fix(s.videoDelayMs)   // 022
        out.perInput = s.perInput.mapValues { p in
            var p = p
            p.fps = fix(p.fps); p.latencyMs = fix(p.latencyMs); p.latencyMaxMs = fix(p.latencyMaxMs)
            return p
        }
        out.encoder = s.encoder.map { e in
            var e = e
            e.bitrate = fix(e.bitrate); e.diskFreeMb = fix(e.diskFreeMb); e.uptimeS = fix(e.uptimeS)   // 022：uptime_s
            return e
        }
        out.audio.meters.buses = s.audio.meters.buses.map { b in
            var b = b
            b.peakDb = b.peakDb.map(fixDb); b.truePeakDb = b.truePeakDb.map(fixDb)
            b.lufsM = fixDb(b.lufsM); b.lufsS = fixDb(b.lufsS); b.lufsI = fixDb(b.lufsI); b.lra = fix(b.lra)
            return b
        }
        out.audio.meters.inputs = s.audio.meters.inputs.mapValues { Stats.AudioCounters.InputMeter(peakDb: $0.peakDb.map(fixDb)) }
        return out
    }
}
