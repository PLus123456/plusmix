import Foundation
import Synchronization
import SwitcherContracts
import SwitcherOutputs

/// 磁盘保护（测试标准 S7）的判定与估算。停录制的是 Recorder 自己：写失败 / 剩余空间低于 `minimumFreeBytes` → 状态 `.failed`、
/// 只影响本录制（W1-E）。这里做：把失败归因（是不是磁盘）、量剩余空间（非启动卷也对）、估算还能录多久、给切备用目录算路径。
/// 全部只出枚举 / 数字，给人看的文字归组装方（W3-C3）。
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

    /// 失败文案里表示"磁盘满"的、与语言无关的记号（小写比）：AVError.diskFull（-11807）、ENOSPC（POSIX 28）、NSFileWriteOutOfSpaceError（640），
    /// 外加系统英文描述里的说法。W3-C3 起不认中文字样：录制器的失败文案是 W1-E 给人看的、系统描述随用户语言变，拿它们归因靠不住；
    /// 录制器自己按下限停的改按它的读数认（`classify(recorder:message:freeBytes:)`）。
    static let diskFullMarkers = ["-11807", "code=28", "code=640", "enospc", "no space", "out of space", "disk full", "not enough space"]

    /// 按失败文案里的磁盘错误码 + 失败那一刻的剩余空间归因。空间充足、又没有磁盘错误码的写失败归 other
    /// （卷被拔掉时 `freeBytes(for:)` 量出来是 0，仍归磁盘）。
    public static func classify(message: String, freeBytes: UInt64) -> Cause {
        let m = message.lowercased()
        if diskFullMarkers.contains(where: { m.contains($0) }) { return .disk }
        if freeBytes < lowWaterBytes { return .disk }
        return .other
    }

    /// 带录制器的归因：录制器自己按下限停的（设了下限、它记下的剩余空间低于下限——Recorder 每次比下限之前都先记读数，
    /// 起步时与之后每秒一次）直接归磁盘，不看文案；其余同 `classify(message:freeBytes:)`。
    public static func classify(recorder: Recorder, message: String, freeBytes: UInt64) -> Cause {
        let minimum = recorder.configuration.minimumFreeBytes
        if minimum > 0, recorder.counters.diskFreeBytes < minimum { return .disk }
        return classify(message: message, freeBytes: freeBytes)
    }

    /// 录制器现在的失败原因：没失败为 nil。
    public static func failureCause(of recorder: Recorder) -> Cause? {
        guard case .failed(let message) = recorder.state else { return nil }
        return classify(recorder: recorder, message: message, freeBytes: freeBytes(for: recorder.configuration.url))
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

    /// 录制器所在卷的剩余空间：录制器自己的读数（`RecorderCounters.diskFreeBytes`，起步时与之后每秒一次）不是 0 就用它，是 0 就用
    /// `freeBytes(for:)` 重新量。`Recorder.freeBytes` 只看 importantUsage 键，非启动卷（磁盘镜像 / 外置盘）上恒 0
    /// （issue W3C-w1-outputs-recorder-freebytes-nonboot-volume，W1-E 还没修）；修好之后读数不再是 0，这里就不多量那一次（W3-C3）。
    public static func diskFreeBytes(of recorder: Recorder, counters: RecorderCounters) -> UInt64 {
        counters.diskFreeBytes > 0 ? counters.diskFreeBytes : freeBytes(for: recorder.configuration.url)
    }

    /// 在跑的录制器在 `Stats.encoder` 里的一项：同 `RecorderCounters.statsEntry`（skipped / bitrate / frames / dropped / state），
    /// disk_free_mb 用 `diskFreeBytes(of:counters:)`——非启动卷上不再报 0。组装方（App 的 OutputRuntime）用它代替 `counters.statsEntry`。
    public static func statsEntry(for recorder: Recorder, counters: RecorderCounters, previous: RecorderCounters?, windowSeconds: Double,
                                  output: Int = 0) -> Stats.EncoderEntry {
        var e = counters.statsEntry(previous: previous, windowSeconds: windowSeconds, state: recorder.state.statsName, output: output)
        e.diskFreeMb = Double(diskFreeBytes(of: recorder, counters: counters)) / 1_048_576
        return e
    }
}

/// 磁盘余量预估：按编码设置算每秒字节数，除进剩余空间。只出数（字节 / 秒、秒；没有码率 = +inf），
/// "约 1 小时 23 分"之类的文案归组装方（App 的 ISORoutes.remainingText；W3-C3 删了包里的 describe）。
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
                        let cause = DiskGuard.classify(recorder: e.recorder, message: message, freeBytes: free)
                        events.append((key, .failed(cause: cause, message: message, freeBytes: free)))
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
