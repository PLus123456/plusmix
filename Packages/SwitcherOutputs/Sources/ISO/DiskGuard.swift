import Foundation
import Synchronization
import SwitcherContracts
import SwitcherOutputs

/// 磁盘保护（测试标准 S7）的判定与估算。停录制的是 Recorder 自己：写失败 / 剩余空间低于 `minimumFreeBytes` → 状态 `.failed`、
/// 只影响本录制（W1-E）。这里只做三件事：把失败归因（是不是磁盘）、估算还能录多久、给切备用目录算路径。
public enum DiskGuard {
    /// 失败原因分类。
    public enum Cause: Hashable, Sendable {
        /// 磁盘满 / 写入失败 / 低于下限。
        case disk
        /// 其他（编码器、格式……）。
        case other
    }

    /// 剩余空间低于它就把"写失败"归因为磁盘（AVAssetWriter 报的错未必带 ENOSPC 字样）。
    public static let lowWaterBytes: UInt64 = 64 * 1024 * 1024

    /// 按失败文案 + 失败那一刻的剩余空间归因。
    public static func classify(message: String, freeBytes: UInt64) -> Cause {
        let m = message.lowercased()
        let words = ["磁盘", "no space", "enospc", "out of space", "disk full", "写入失败", "not enough space", "code=640", "code=28", "-11807"]
        if words.contains(where: { m.contains($0) }) { return .disk }
        if freeBytes < lowWaterBytes { return .disk }
        return .other
    }

    /// 录制器现在的失败原因：没失败为 nil。
    public static func failureCause(of recorder: Recorder) -> Cause? {
        guard case .failed(let message) = recorder.state else { return nil }
        return classify(message: message, freeBytes: freeBytes(for: recorder.configuration.url))
    }

    /// 文件所在卷的剩余空间（字节）。`volumeAvailableCapacityForImportantUsage` 只对启动卷有意义：探针实测 macOS 26 上 HFS+ / APFS
    /// 磁盘镜像都给 0（`Recorder.freeBytes` 只看它，录到镜像 / 外置盘时会误报 0，见 reports/issues/W3C-w1-outputs-recorder-freebytes-nonboot-volume.md），
    /// 所以它为 0 时退到 `volumeAvailableCapacity`，再退到 systemFreeSize。
    public static func freeBytes(for url: URL) -> UInt64 {
        let dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
            if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return UInt64(important) }
            if let available = v.volumeAvailableCapacity, available > 0 { return UInt64(available) }
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path), let free = attrs[.systemFreeSize] as? UInt64 {
            return free
        }
        return 0
    }
}

/// 磁盘余量预估：按编码设置算每秒字节数，除进剩余空间。
public enum DiskEstimate {
    /// 一路（视频 + 音频）每秒写多少字节。PCM 按 48 kHz × 声道 × 24 bit（Recorder 写 LPCM 用 24 bit）。
    public static func bytesPerSecond(video: VideoEncodeSettings?, audio: AudioEncodeSettings?, audioChannels: Int = 2) -> Double {
        var bits = 0.0
        if let video { bits += Double(video.bitrateBps) }
        if let audio {
            switch audio.codec {
            case .aac: bits += Double(audio.bitrateBps)
            case .pcm: bits += Double(AudioFormat.sampleRate * audioChannels * 24)
            }
        }
        return bits / 8
    }

    /// 还能录多少秒：(剩余 − 保留) / 每秒字节数；每秒字节数为 0 给 +inf。
    public static func remainingSeconds(freeBytes: UInt64, reserveBytes: UInt64, bytesPerSecond: Double) -> Double {
        let usable = Double(freeBytes > reserveBytes ? freeBytes - reserveBytes : 0)
        guard bytesPerSecond > 0 else { return .infinity }
        return usable / bytesPerSecond
    }

    /// "约 1 小时 23 分" / "约 12 分" / "不足 1 分钟"。
    public static func describe(seconds: Double) -> String {
        guard seconds.isFinite else { return "不受磁盘限制" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "不足 1 分钟" }
        if minutes < 60 { return "约 \(minutes) 分钟" }
        return "约 \(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

/// 切备用目录：同名文件放到备用目录，已存在就加序号。
public enum RecordingFallback {
    public static func url(for original: URL, directory: String, fileManager: FileManager = .default) -> URL {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension.isEmpty ? "mov" : original.pathExtension
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

/// 轮询一组录制器的磁盘状况，只报事件（自己的定时器线程）：剩余空间（`DiskGuard.freeBytes`，自己算，不用录制器的计数）跌破
/// 警戒线报一次 `.lowSpace`、跌破该路的下限报一次 `.belowMinimum`（组装方收到就停那一路：S7 的"空间低于阈值 → 只停录制"）；
/// 录制器失败（写失败）报一次 `.failed(cause:)`（归因见 DiskGuard）。组装方在事件里提示用户 / 切备用目录重起；本对象不停任何东西。
/// 下限为什么不交给 Recorder.minimumFreeBytes：它的 freeBytes 在非启动卷上是 0（见 DiskGuard.freeBytes），组装方把它设 0、由这里管。
public final class RecordingDiskMonitor: @unchecked Sendable {
    /// 事件。
    public enum Event: Hashable, Sendable {
        /// 剩余空间跌破 `warnBelowBytes`（每路只报一次，回升到线上之后可以再报）。
        case lowSpace(freeBytes: UInt64)
        /// 剩余空间跌破该路的下限（每路只报一次）；组装方应停这一路。
        case belowMinimum(freeBytes: UInt64)
        /// 录制器失败（每路只报一次）。
        case failed(cause: DiskGuard.Cause, message: String, freeBytes: UInt64)
    }

    /// 警戒线（字节），默认 1 GB。
    public var warnBelowBytes: UInt64
    /// 轮询间隔。
    public let interval: TimeInterval
    /// 事件回调（监视线程上调；接收方自己跳线程）。参数：登记时的键。
    public var onEvent: (@Sendable (Int, Event) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    private struct Entry {
        let recorder: Recorder
        let minimumFreeBytes: UInt64
        var warned = false
        var reportedMinimum = false
        var reportedFailure = false
        var lastFree: UInt64 = 0
    }
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var handler: (@Sendable (Int, Event) -> Void)?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "switcher.iso.diskmonitor", qos: .utility)

    public init(warnBelowBytes: UInt64 = 1024 * 1024 * 1024, interval: TimeInterval = 1) {
        self.warnBelowBytes = warnBelowBytes
        self.interval = interval
    }

    deinit { stop() }

    /// 登记一路（键由组装方定，一般 = 输出编号）。`minimumFreeBytes` = 这一路的下限（0 = 不设下限，写到满为止）。
    public func add(_ recorder: Recorder, key: Int, minimumFreeBytes: UInt64 = 200 * 1024 * 1024) {
        lock.withLock { entries[key] = Entry(recorder: recorder, minimumFreeBytes: minimumFreeBytes) }
    }

    /// 最近一次轮询看到的某路剩余空间。
    public func lastFreeBytes(key: Int) -> UInt64? { lock.withLock { entries[key]?.lastFree } }

    public func remove(key: Int) {
        _ = lock.withLock { entries.removeValue(forKey: key) }
    }

    /// 登记的键。
    public var keys: [Int] { lock.withLock { entries.keys.sorted() } }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.pollOnce() }
        t.resume()
        timer = t
    }

    public func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    /// 轮询一次（定时器调；测试也可以直接调）。返回这次发出的事件数。
    @discardableResult
    public func pollOnce() -> Int {
        var events: [(Int, Event)] = []
        lock.withLock {
            for (key, var e) in entries {
                let free = DiskGuard.freeBytes(for: e.recorder.configuration.url)
                e.lastFree = free
                switch e.recorder.state {
                case .failed(let message):
                    if !e.reportedFailure {
                        e.reportedFailure = true
                        events.append((key, .failed(cause: DiskGuard.classify(message: message, freeBytes: free), message: message, freeBytes: free)))
                    }
                case .recording:
                    if free < warnBelowBytes {
                        if !e.warned {
                            e.warned = true
                            events.append((key, .lowSpace(freeBytes: free)))
                        }
                    } else {
                        e.warned = false
                    }
                    if e.minimumFreeBytes > 0, free < e.minimumFreeBytes, !e.reportedMinimum {
                        e.reportedMinimum = true
                        events.append((key, .belowMinimum(freeBytes: free)))
                    }
                default:
                    break
                }
                entries[key] = e
            }
        }
        guard !events.isEmpty, let h = onEvent else { return events.count }
        for (key, event) in events.sorted(by: { $0.0 < $1.0 }) { h(key, event) }
        return events.count
    }
}
