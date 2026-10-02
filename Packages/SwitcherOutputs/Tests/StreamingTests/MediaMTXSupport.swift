import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

// MediaMTX 集成测试的工装：起 / 停 MediaMTX 实例、ffprobe、frameprobe、netem（sudo 或代理）、真编码器的喂料。

/// 输出目录：$SWITCHER_TEST_OUTPUT 或临时目录。
enum StreamTestPaths {
    static let root: URL = {
        let base = ProcessInfo.processInfo.environment["SWITCHER_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("switcher-streaming-tests")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 仓库根：从源文件路径往上找 CLAUDE.md。
    static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) { return url }
        }
        throw XCTSkip("找不到仓库根（CLAUDE.md）")
    }

    /// frameprobe（先 `swift build -c release --package-path Tools/frameprobe`）。
    static func frameprobe() throws -> URL {
        let root = try repoRoot()
        for c in ["release", "debug"] {
            let u = root.appendingPathComponent("Tools/frameprobe/.build/\(c)/frameprobe")
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        throw XCTSkip("BLOCKED-工具：没有编好的 frameprobe（swift build -c release --package-path Tools/frameprobe）")
    }
}

/// 外部进程。
enum Proc {
    struct Output { var stdout: Data; var stderr: String; var code: Int32 }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 600) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(stdout: outData, stderr: String(decoding: errData, as: UTF8.self), code: p.terminationStatus)
    }

    static func json(_ path: String, _ args: [String]) throws -> [String: Any] {
        let o = try run(path, args)
        guard let obj = try? JSONSerialization.jsonObject(with: o.stdout) as? [String: Any] else {
            throw TestFailure("\(path) 没有 JSON 输出：\(o.stderr.prefix(500))")
        }
        return obj
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// ffprobe 包装（brew）。
enum FFprobe {
    static let path = "/opt/homebrew/bin/ffprobe"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }
    static func requireAvailable() throws {
        if !isAvailable { throw XCTSkip("BLOCKED-工具：没有 \(path)（brew install ffmpeg）") }
    }

    struct Packet { var ptsTime: Double; var dtsTime: Double?; var size: Int; var isKeyframe: Bool }

    static func packets(_ url: URL, stream: String = "v:0") throws -> [Packet] {
        let obj = try Proc.json(path, ["-v", "error", "-print_format", "json", "-select_streams", stream, "-show_packets",
                                       "-show_entries", "packet=pts_time,dts_time,size,flags", url.path])
        let arr = obj["packets"] as? [[String: Any]] ?? []
        return arr.compactMap { p in
            guard let pts = (p["pts_time"] as? String).flatMap(Double.init), let size = (p["size"] as? String).flatMap(Int.init) else { return nil }
            return Packet(ptsTime: pts, dtsTime: (p["dts_time"] as? String).flatMap(Double.init), size: size,
                          isKeyframe: (p["flags"] as? String ?? "").contains("K"))
        }
    }

    /// 两条轨的 start_time（秒）：MediaMTX 从第一个关键帧起录，音轨起点 = 我们送的原点包；两者之差就是落盘文件里两轨起点的距离。
    static func streamStartTimes(_ url: URL) throws -> (video: Double, audio: Double) {
        let obj = try Proc.json(path, ["-v", "error", "-print_format", "json", "-show_entries", "stream=codec_type,start_time", url.path])
        var v = Double.nan, a = Double.nan
        for st in obj["streams"] as? [[String: Any]] ?? [] {
            let t = (st["start_time"] as? String).flatMap(Double.init) ?? .nan
            switch st["codec_type"] as? String {
            case "video": v = t
            case "audio": a = t
            default: break
            }
        }
        return (v, a)
    }

    /// 视频帧数（逐帧解码数，慢但准）。
    static func countFrames(_ url: URL) throws -> Int {
        let obj = try Proc.json(path, ["-v", "error", "-print_format", "json", "-select_streams", "v:0", "-count_frames", "-show_entries",
                                       "stream=nb_read_frames", url.path])
        let s = (obj["streams"] as? [[String: Any]])?.first
        return (s?["nb_read_frames"] as? String).flatMap(Int.init) ?? 0
    }
}

/// frameprobe 包装。
enum Frameprobe {
    struct Stats {
        var totalFrames: Int
        var droppedFrames: Int
        var duplicateFrames: Int
        var undecodable: Int
        var dropGaps: Int
        var durationSeconds: Double
    }

    static func stats(_ url: URL, fps: Int = 60) throws -> Stats {
        // 传输口径：只有一路、没有转场，要的是"收到的帧号连续、不重不丢"。W1-A3 起 frameprobe 默认开自证解码，其中"节奏"一票
        // 要求烧进画面的 (帧号, 时间戳) 落在该路自己的直线上、残差 ≤ 3 ms——那是按引擎节拍的合成源定的；这里的 PatternFeeder 实时喂送，
        // 时间戳带毫秒级调度抖动，RTMP 10 s 里有 37 帧残差 3.2–3.8 ms 被判成解不出、算成丢帧（G4 第二批合入时查明，同一文件关掉自证 599 帧 0 丢 0 重）。
        // 自证是为转场合成帧准备的，这里用不上，按老口径读；问题单 reports/issues/G4b-w1-testkit-selfcheck-rhythm-vs-realtime-feeder.md。
        let obj = try Proc.json(try StreamTestPaths.frameprobe().path, ["stats", url.path, "--fps", "\(fps)", "--no-self-check"])
        guard let st = obj["stats"] as? [String: Any] else { throw TestFailure("frameprobe stats 没有 stats 节：\(obj)") }
        let inputs = st["inputs"] as? [[String: Any]] ?? []
        let dropped = inputs.reduce(0) { $0 + ($1["droppedFrames"] as? Int ?? 0) }
        let dup = inputs.reduce(0) { $0 + ($1["duplicateFrames"] as? Int ?? 0) }
        let gaps = inputs.reduce(0) { $0 + (($1["dropGaps"] as? [Any])?.count ?? 0) }
        return Stats(totalFrames: st["totalFrames"] as? Int ?? 0, droppedFrames: dropped, duplicateFrames: dup,
                     undecodable: st["undecodableFrames"] as? Int ?? 0, dropGaps: gaps, durationSeconds: st["durationSeconds"] as? Double ?? 0)
    }

    struct Frame { var index: Int; var ptsSeconds: Double; var frameNumber: Int?; var flash: Bool }

    /// 逐帧：烧进画面的帧号（= 拍号）、PTS、是否闪光帧。落盘文件从哪一拍开始就看第一帧的 frameNumber。
    /// 同 `stats`：关掉自证（实时喂送的文件第一帧没有"节奏"可投票，会被判成解不出，见上）。
    static func frames(_ url: URL, limit: Int = 100) throws -> [Frame] {
        let obj = try Proc.json(try StreamTestPaths.frameprobe().path, ["frames", url.path, "--limit", "\(limit)", "--no-self-check"])
        let arr = obj["frames"] as? [[String: Any]] ?? []
        return arr.map { f in
            Frame(index: f["index"] as? Int ?? 0, ptsSeconds: f["ptsSeconds"] as? Double ?? .nan, frameNumber: f["frameNumber"] as? Int,
                  flash: (f["flash"] as? Bool) == true)
        }
    }

    struct AV { var meanMs: Double; var maxAbsMs: Double; var matched: Int; var flashes: Int }

    static func av(_ url: URL, fps: Int = 60) throws -> AV {
        let obj = try Proc.json(try StreamTestPaths.frameprobe().path, ["av", url.path, "--fps", "\(fps)"])
        guard let av = obj["av"] as? [String: Any] else { throw TestFailure("frameprobe av 没有 av 节：\(obj)") }
        return AV(meanMs: av["meanMs"] as? Double ?? .nan, maxAbsMs: av["maxAbsMs"] as? Double ?? .nan,
                  matched: av["matchedCount"] as? Int ?? 0, flashes: av["flashCount"] as? Int ?? 0)
    }
}

/// 一个 MediaMTX 实例（scripts/mediamtx.yml + 环境变量改端口和录制目录）。
final class MediaMTXInstance {
    static let binary = "/opt/homebrew/bin/mediamtx"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: binary) }
    static func requireAvailable() throws {
        if !isAvailable { throw XCTSkip("BLOCKED-工具：没有 \(binary)（brew install mediamtx）") }
    }

    let rtmpPort: Int
    let srtPort: Int
    let apiPort: Int
    let recordDir: URL
    private let process = Process()
    private let log: FileHandle

    /// `extraConfig`：接在 scripts/mediamtx.yml 后面的顶层 YAML（比如鉴权的 authMethod / authInternalUsers），合成的配置写进录制目录。
    init(rtmpPort: Int, srtPort: Int, apiPort: Int, recordDir: URL, extraConfig: String? = nil) throws {
        self.rtmpPort = rtmpPort
        self.srtPort = srtPort
        self.apiPort = apiPort
        self.recordDir = recordDir
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        var config = try StreamTestPaths.repoRoot().appendingPathComponent("scripts/mediamtx.yml")
        if let extraConfig {
            let merged = recordDir.appendingPathComponent("mediamtx-\(rtmpPort).yml")
            try (try String(contentsOf: config, encoding: .utf8) + "\n" + extraConfig + "\n").write(to: merged, atomically: true, encoding: .utf8)
            config = merged
        }
        let logURL = recordDir.appendingPathComponent("mediamtx-\(rtmpPort).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        process.executableURL = URL(fileURLWithPath: Self.binary)
        process.arguments = [config.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            // SRT 必须显式绑 IPv4（":port" 是 IPv6 双栈 UDP，IPv4 回环的握手收不到，见 scripts/mediamtx.yml）
            "MTX_RTMPADDRESS": ":\(rtmpPort)", "MTX_SRTADDRESS": "0.0.0.0:\(srtPort)", "MTX_APIADDRESS": "127.0.0.1:\(apiPort)",
            "MTX_PATHDEFAULTS_RECORDPATH": recordDir.appendingPathComponent("%path/%Y-%m-%d_%H-%M-%S-%f").path,
        ]) { $1 }
        process.standardOutput = log
        process.standardError = log
        try process.run()
        // 等 API 起来
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while Date() < deadline {
            if let _ = try? apiJSON("/v3/paths/list") { ready = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !ready { stop(); throw TestFailure("MediaMTX（RTMP \(rtmpPort)）10 s 内没起来，日志 \(logURL.path)") }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? log.close()
    }

    func rtmpURL(_ path: String) -> String { "rtmp://127.0.0.1:\(rtmpPort)/\(path)" }
    func srtURL(_ path: String) -> String { "srt://127.0.0.1:\(srtPort)?streamid=publish:\(path)" }

    /// 该 path 的录制文件（按名字排序 = 按时间）。
    func recordings(_ path: String) -> [URL] {
        let dir = recordDir.appendingPathComponent(path)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// API：某 path 是否有发布者。
    func isPublishing(_ path: String) -> Bool {
        guard let obj = try? apiJSON("/v3/paths/get/\(path)") else { return false }
        return (obj["ready"] as? Bool) ?? false
    }

    private func apiJSON(_ endpoint: String) throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(apiPort)\(endpoint)")!
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<Data>()
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { box.set(.success(data)) } else { box.set(.failure(error ?? TestFailure("http"))) }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2)
        let data = try box.get().get()
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TestFailure("API JSON") }
        return obj
    }
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    private var value: Result<T, Error>?
    private let lock = NSLock()
    func set(_ v: Result<T, Error>) { lock.withLock { value = v } }
    func get() -> Result<T, Error> { lock.withLock { value ?? .failure(TestFailure("没有结果")) } }
}

/// 网络损伤（scripts/netem.sh）。SWITCHER_NETEM=sudo：测试进程自己 `sudo -n scripts/netem.sh …`（先在同一终端 `sudo -v`；
/// 注意 sudo 凭证默认 5 分钟过期，E9 一跑 5 分钟，推荐 broker）；
/// SWITCHER_NETEM=broker：写请求文件给另一个终端里的 `sudo scripts/netem.sh serve`（默认目录 /tmp/switcher-netem，SWITCHER_NETEM_DIR 可改）；
/// 没设：E7 / E8 / E9 用进程内的 ThrottleProxy（不需要 sudo）。
enum Netem {
    enum Mode { case sudo, broker(URL) }

    static func mode() throws -> Mode {
        switch ProcessInfo.processInfo.environment["SWITCHER_NETEM"] {
        case "sudo":
            let o = try Proc.run("/usr/bin/sudo", ["-n", "true"])
            guard o.code == 0 else { throw XCTSkip("BLOCKED-sudo：SWITCHER_NETEM=sudo 但 sudo -n 不可用（先在同一终端 sudo -v）") }
            return .sudo
        case "broker":
            let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHER_NETEM_DIR"] ?? "/tmp/switcher-netem")
            guard FileManager.default.fileExists(atPath: dir.path) else {
                throw XCTSkip("BLOCKED-sudo：SWITCHER_NETEM=broker 但 \(dir.path) 不存在（先 sudo scripts/netem.sh serve \(dir.path)）")
            }
            return .broker(dir)
        default:
            throw XCTSkip("BLOCKED-sudo：需要网络损伤。用法：sudo -v && SWITCHER_NETEM=sudo swift test …；或另开终端 sudo scripts/netem.sh serve 后 SWITCHER_NETEM=broker")
        }
    }

    /// 执行一条 netem 子命令（block PORT SECONDS 之类）。带秒数的命令会在后台自动清除，这里不等它。
    static func run(_ mode: Mode, _ args: [String]) throws {
        let script = try StreamTestPaths.repoRoot().appendingPathComponent("scripts/netem.sh").path
        switch mode {
        case .sudo:
            // 带秒数的命令会 sleep 到时自动清；不等它退出，只等 0.5 s 让规则装上，然后看它有没有立刻失败（凭证过期 = sudo -n 秒退）
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", script] + args
            p.standardOutput = FileHandle.standardOutput
            p.standardError = FileHandle.standardError
            try p.run()
            Thread.sleep(forTimeInterval: 0.5)
            if !p.isRunning, p.terminationStatus != 0 {
                XCTFail("netem（sudo -n）失败，退出码 \(p.terminationStatus)：sudo 凭证过期？重新 sudo -v，或改用 SWITCHER_NETEM=broker")
            }
        case .broker(let dir):
            let reply = dir.appendingPathComponent("netem.reply")
            try? FileManager.default.removeItem(at: reply)
            try (args.joined(separator: " ") + "\n").write(to: dir.appendingPathComponent("netem.request"), atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !FileManager.default.fileExists(atPath: reply.path) { Thread.sleep(forTimeInterval: 0.1) }
            if let s = try? String(contentsOf: reply, encoding: .utf8) { print("netem: \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
    }

    static func clear(_ mode: Mode) { try? run(mode, ["clear"]) }
}

/// 真编码器的推流场景：图案（可加噪声）+ 合成音频，按拍点实时喂给若干 StreamOutput。
final class StreamScene {
    let format: ProgramFormat
    let clock: TickClockSpec
    let signal: TestSignal
    let feeder: PatternFeeder
    let signalFeeder: SignalFeeder

    init(format: ProgramFormat = .hd1080p60, texture: PatternFeeder.Texture = .noise(amplitude: 24, seed: 7), inputID: Int = 3, leadMs: Double = 500) throws {
        self.format = format
        feeder = try PatternFeeder(configuration: .init(format: format, inputID: inputID, texture: texture))
        let t0 = HostClock.now() + HostDuration(milliseconds: leadMs)
        clock = TickClockSpec(t0: t0, frameRate: format.frameRate)
        signal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: format.frameRate))
        signalFeeder = SignalFeeder(signal: signal)
    }

    /// 实时喂 [from, to) 拍；每拍之后调 onTick（做断网 / 检查用）。返回喂了多少帧。
    @discardableResult
    func feed(outputs: [StreamOutput], ticks: Range<Int>, onTick: ((Int, HostTime) -> Void)? = nil) throws -> PatternFeeder.FeedReport {
        try feeder.feed(consumers: outputs, clock: clock, ticks: Tick(Int64(ticks.lowerBound))..<Tick(Int64(ticks.upperBound)), pacing: .realTime) { tick, tickTime in
            self.signalFeeder.feed(upTo: tickTime, to: outputs)
            onTick?(Int(tick.rawValue), tickTime)
        }
    }

    /// 生产配置：真 VT 编码器 + HaishinKit 传输层。
    func makeOutput(name: String, url: String, bitrate: Int = 6_000_000, keyint: Int = 120, connectTimeout: Double = 5,
                    queue: StreamOutput.QueuePolicy = StreamOutput.QueuePolicy(lingerSeconds: 2)) throws -> StreamOutput {
        let video = VideoEncodeSettings(codec: .h264, bitrateBps: bitrate, keyframeIntervalFrames: keyint)
        let cfg = StreamOutput.Configuration(name: name, format: format, video: video, audio: AudioEncodeSettings(),
                                             stream: StreamSettings(url: url), queue: queue, connectTimeoutSeconds: connectTimeout)
        return try StreamOutput(configuration: cfg, transportFactory: HaishinKitTransportFactory(format: format, video: video, connectTimeoutSeconds: Int(connectTimeout)))
    }
}

/// 汇总一批录制文件的 frameprobe 统计。
func frameprobeTotals(_ files: [URL]) throws -> (frames: Int, dropped: Int, gaps: Int, undecodable: Int) {
    var frames = 0, dropped = 0, gaps = 0, undecodable = 0
    for f in files {
        let s = try Frameprobe.stats(f)
        frames += s.totalFrames
        dropped += s.droppedFrames
        gaps += s.dropGaps
        undecodable += s.undecodable
    }
    return (frames, dropped, gaps, undecodable)
}

/// A/V 偏移的 ffmpeg 口径（推流落盘文件专用，见报告 §1.4）：
/// 音轨用 ffmpeg 解成 PCM（`aresample=first_pts=0` 把音轨的起始偏移补成静音，ffmpeg 系解码器不裁 AAC priming），
/// 找 click（满幅样本）；闪光帧的时刻用 frameprobe frames 的 ptsSeconds。偏移 = 闪光时刻 − click 时刻（音频超前为正，同 frameprobe av）。
enum AVOffsetFFmpeg {
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    struct Result {
        var meanMs: Double
        var maxAbsMs: Double
        var pairs: [(flash: Double, click: Double)]
        /// 解出的音轨在 [0.1 s, 1.0 s) 的 RMS（跳过 AAC 解码器前 2112 样本的热身）：1 kHz −20 dBFS 正弦 ≈ 0.071；没有音频 = 0。
        var rmsFirstSecond: Double
    }

    static func measure(_ url: URL, fps: Int = 60) throws -> Result {
        // 闪光帧
        let obj = try Proc.json(try StreamTestPaths.frameprobe().path, ["frames", url.path])
        let frames = obj["frames"] as? [[String: Any]] ?? []
        let flashes = frames.filter { ($0["flash"] as? Bool) == true }.compactMap { $0["ptsSeconds"] as? Double }
        // click
        let raw = url.deletingPathExtension().appendingPathExtension("avraw")
        let o = try Proc.run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-map", "0:a:0", "-af", "aresample=async=1:first_pts=0",
                                      "-f", "f32le", "-ac", "1", "-ar", "48000", raw.path])
        guard o.code == 0 else { throw TestFailure("ffmpeg 解音轨失败：\(o.stderr)") }
        let data = try Data(contentsOf: raw)
        try? FileManager.default.removeItem(at: raw)
        var clicks: [Double] = []
        var rmsFirst = 0.0
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let samples = p.bindMemory(to: Float.self)
            var last = -1000
            for i in 0..<samples.count where samples[i] > 0.9 {
                if i - last > 100 { clicks.append(Double(i) / 48000) }
                last = i
            }
            let lo = 4800, hi = min(samples.count, 48000)
            if hi > lo {
                var acc = 0.0
                for i in lo..<hi { acc += Double(samples[i]) * Double(samples[i]) }
                rmsFirst = (acc / Double(hi - lo)).squareRoot()
            }
        }
        var pairs: [(Double, Double)] = []
        for f in flashes {
            guard let c = clicks.min(by: { abs($0 - f) < abs($1 - f) }), abs(c - f) < 0.3 else { continue }
            pairs.append((f, c))
        }
        let offsets = pairs.map { ($0.0 - $0.1) * 1000 }
        let mean = offsets.isEmpty ? .nan : offsets.reduce(0, +) / Double(offsets.count)
        let maxAbs = offsets.map(abs).max() ?? .nan
        return Result(meanMs: mean, maxAbsMs: maxAbs, pairs: pairs.map { (flash: $0.0, click: $0.1) }, rmsFirstSecond: rmsFirst)
    }
}

/// 网络损伤的两种来源：真 dummynet（SWITCHER_NETEM=sudo | broker，作用在 MediaMTX 端口）或用户态代理（默认，不需要 sudo）。
final class Impairment {
    enum Kind { case netem(Netem.Mode, port: Int); case proxy(ThrottleProxy) }
    let kind: Kind
    /// 推流地址（代理模式下指向代理端口）。
    let url: String
    private var timers: [DispatchWorkItem] = []

    init(mtx: MediaMTXInstance, path: String, proxyPort: Int) throws {
        if ProcessInfo.processInfo.environment["SWITCHER_NETEM"] != nil {
            let mode = try Netem.mode()
            kind = .netem(mode, port: mtx.rtmpPort)
            url = mtx.rtmpURL(path)
        } else {
            let proxy = try ThrottleProxy(listenPort: proxyPort, targetPort: mtx.rtmpPort)
            kind = .proxy(proxy)
            url = "rtmp://127.0.0.1:\(proxyPort)/\(path)"
        }
    }

    var description: String {
        switch kind {
        case .netem(_, let port): return "dummynet（端口 \(port)）"
        case .proxy(let p): return "用户态代理（\(p.listenPort) → \(p.targetPort)）"
        }
    }

    /// 封 seconds 秒后自动放开。netem 的调用放后台线程：它要等 sudo / 代理回话（0.3–0.5 s），不能卡住按拍喂帧的线程，
    /// 否则编码器队列被成批涌入的帧挤爆（E1 跳帧）—— dummynet 版 E7 第一次就是这么错判的。
    func block(seconds: Double) throws {
        switch kind {
        case .netem(let mode, let port):
            DispatchQueue.global().async { try? Netem.run(mode, ["block", "\(port)", "\(Int(seconds))"]) }
        case .proxy(let proxy):
            proxy.blocked = true
            let item = DispatchWorkItem { proxy.blocked = false }
            timers.append(item)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    /// 上行限速 kbit/s，seconds 秒后自动放开。
    func limit(kbit: Int, seconds: Double) throws {
        switch kind {
        case .netem(let mode, let port):
            DispatchQueue.global().async { try? Netem.run(mode, ["limit", "\(port)", "\(kbit)", "\(Int(seconds))"]) }
        case .proxy(let proxy):
            proxy.rateBytesPerSecond = kbit * 1000 / 8
            let item = DispatchWorkItem { proxy.rateBytesPerSecond = nil }
            timers.append(item)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    func clear() {
        for t in timers { t.cancel() }
        timers.removeAll()
        switch kind {
        case .netem(let mode, _): Netem.clear(mode)
        case .proxy(let proxy): proxy.blocked = false; proxy.rateBytesPerSecond = nil
        }
    }

    func stop() {
        clear()
        if case .proxy(let proxy) = kind { proxy.stop() }
    }
}
