import AVFoundation
import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

// 测试公用：ffprobe 包装、临时目录、可控后端、时钟与喂料的便利函数。

/// ffprobe（/opt/homebrew/bin）。没装就 XCTSkip（prompt 要求）。
enum FFprobe {
    static let path = "/opt/homebrew/bin/ffprobe"
    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func requireAvailable() throws {
        if !isAvailable { throw XCTSkip("BLOCKED-工具：没有 \(path)（brew install ffmpeg）") }
    }

    struct Stream {
        var index: Int
        var codecType: String
        var codecName: String
        var duration: Double?
        var startTime: Double?
        var nbFrames: Int?
        var nbReadFrames: Int?
        var width: Int?
        var height: Int?
        var timeBase: String?
    }

    struct Packet {
        var ptsTime: Double
        var dtsTime: Double?
        var size: Int
        var isKeyframe: Bool
    }

    struct Result {
        var streams: [Stream]
        var formatDuration: Double?
        var stderr: String
        var exitCode: Int32
        var video: Stream? { streams.first { $0.codecType == "video" } }
        var audio: Stream? { streams.first { $0.codecType == "audio" } }
    }

    static func run(_ args: [String]) throws -> (stdout: Data, stderr: String, code: Int32) {
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
        return (outData, String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }

    /// -show_streams -show_format（countFrames 时逐帧解码数 nb_read_frames，慢但准）。
    static func probe(_ url: URL, countFrames: Bool = false) throws -> Result {
        var args = ["-v", "error", "-print_format", "json", "-show_streams", "-show_format"]
        if countFrames { args.append("-count_frames") }
        args.append(url.path)
        let (data, stderr, code) = try run(args)
        var streams: [Stream] = []
        var formatDuration: Double?
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for s in (obj["streams"] as? [[String: Any]]) ?? [] {
                streams.append(Stream(
                    index: s["index"] as? Int ?? 0,
                    codecType: s["codec_type"] as? String ?? "",
                    codecName: s["codec_name"] as? String ?? "",
                    duration: (s["duration"] as? String).flatMap(Double.init),
                    startTime: (s["start_time"] as? String).flatMap(Double.init),
                    nbFrames: (s["nb_frames"] as? String).flatMap(Int.init),
                    nbReadFrames: (s["nb_read_frames"] as? String).flatMap(Int.init),
                    width: s["width"] as? Int, height: s["height"] as? Int,
                    timeBase: s["time_base"] as? String))
            }
            if let f = obj["format"] as? [String: Any] { formatDuration = (f["duration"] as? String).flatMap(Double.init) }
        }
        return Result(streams: streams, formatDuration: formatDuration, stderr: stderr, exitCode: code)
    }

    /// 某条流的全部包。
    static func packets(_ url: URL, stream: String = "v:0") throws -> [Packet] {
        let (data, _, _) = try run(["-v", "error", "-print_format", "json", "-select_streams", stream, "-show_packets",
                                   "-show_entries", "packet=pts_time,dts_time,size,flags", url.path])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["packets"] as? [[String: Any]] else { return [] }
        return arr.compactMap { p in
            guard let pts = (p["pts_time"] as? String).flatMap(Double.init), let size = (p["size"] as? String).flatMap(Int.init) else { return nil }
            let flags = p["flags"] as? String ?? ""
            return Packet(ptsTime: pts, dtsTime: (p["dts_time"] as? String).flatMap(Double.init), size: size, isKeyframe: flags.contains("K"))
        }
    }

    /// 解码整条音轨成单声道 float32 48 kHz 样本（需要 ffmpeg）。
    static func decodeAudioMono(_ url: URL) throws -> [Float] {
        let tmp = url.deletingPathExtension().appendingPathExtension("raw")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-v", "error", "-y", "-i", url.path, "-f", "f32le", "-ac", "1", "-ar", "48000", tmp.path]
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = try Data(contentsOf: tmp)
        try? FileManager.default.removeItem(at: tmp)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// 测试输出目录：$SWITCHER_TEST_OUTPUT 或临时目录；留下文件方便人工看。
enum TestPaths {
    static let root: URL = {
        let base = ProcessInfo.processInfo.environment["SWITCHER_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("switcher-outputs-tests")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// 可执行 target 的路径：与测试 bundle 同一个 .build/<config>/ 目录。
    static func probeBinary() throws -> URL {
        let bundle = Bundle(for: Anchor.self).bundleURL
        // .build/debug/SwitcherOutputsPackageTests.xctest → .build/debug/switcher-record-probe
        let dir = bundle.deletingLastPathComponent()
        let candidates = [dir.appendingPathComponent("switcher-record-probe"),
                          dir.deletingLastPathComponent().appendingPathComponent("switcher-record-probe")]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) { return c }
        throw XCTSkip("找不到 switcher-record-probe（\(candidates.map(\.path)))")
    }

    /// 仓库根（Tests/Fixtures 在这里）：从源文件路径往上找 CLAUDE.md。
    static func repoRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) { return url }
        }
        return nil
    }

    private final class Anchor {}
}

/// 可控后端：每帧要等测试放行一次（gate），编码本身不做事。用来证明 E1 的 skipped 计数精确等于理论值。
final class GatedBackend: VideoEncoderBackend, @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var encodedTicks: [Tick] = []
    private var output: (@Sendable (EncodedVideoSample) -> Void)?
    var blockForever = false

    func prepare(output: @escaping @Sendable (EncodedVideoSample) -> Void, dropped: @escaping @Sendable () -> Void) throws {
        self.output = output
    }

    func encode(_ frame: RenderedFrame, forceKeyframe: Bool) throws {
        gate.wait()
        lock.withLock { encodedTicks.append(frame.tick) }
    }

    func flush() {}
    func invalidate() {}

    var encodedCount: Int { lock.withLock { encodedTicks.count } }
}

extension XCTestCase {
    /// 等到条件成立或超时。
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2000)
        }
        return condition()
    }

    /// 同步停止录制。
    func stopAndWait(_ recorder: Recorder, atTick tick: Tick?, timeout: TimeInterval = 120) throws -> RecordingResult {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<RecordingResult>()
        recorder.stop(atTick: tick) { r in box.set(r); sem.signal() }
        guard sem.wait(timeout: .now() + timeout) == .success else { throw TestError.timeout("stop \(recorder.consumerName)") }
        return try box.get().get()
    }
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    private var value: Result<T, Error>?
    private let lock = NSLock()
    func set(_ v: Result<T, Error>) { lock.withLock { value = v } }
    func get() -> Result<T, Error> { lock.withLock { value ?? .failure(TestError.timeout("没有结果")) } }
}

enum TestError: Error { case timeout(String), message(String) }

/// 一次"起点 + 时钟 + 图案喂料 + 音频喂料"的录制场景。
struct RecordingScene {
    let format: ProgramFormat
    let clock: TickClockSpec
    let signal: TestSignal
    let feeder: PatternFeeder
    let signalFeeder: SignalFeeder

    /// realTime = true 时 t0 = 现在 + 0.3 s（让编码器热身）；否则 t0 = 现在（合成时间轴，越跑越"超前"，编码器只看 PTS）。
    init(format: ProgramFormat, texture: PatternFeeder.Texture = .flat, inputID: Int = 0, realTime: Bool) throws {
        self.format = format
        // 先建喂料器（噪声平面预生成在 debug 下要几百毫秒），再定 t0，否则实时喂的头几十拍已经晚点、成批涌入 → 队列溢出
        feeder = try PatternFeeder(configuration: .init(format: format, inputID: inputID, texture: texture))
        let t0 = HostClock.now() + HostDuration(milliseconds: realTime ? 300 : 0)
        clock = TickClockSpec(t0: t0, frameRate: format.frameRate)
        signal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: format.frameRate))
        signalFeeder = SignalFeeder(signal: signal)
    }

    /// 喂 [0, ticks) 拍的视频和同源音频给 recorders，然后把音频补齐到停止拍点。
    func feed(recorders: [Recorder], ticks: Int, realTime: Bool) throws -> PatternFeeder.FeedReport {
        let pacing: PatternFeeder.Pacing = realTime
            ? .realTime
            : .fastest(readyToAccept: { !recorders.contains { $0.isQueueFull } })
        let report = try feeder.feed(consumers: recorders, clock: clock, ticks: Tick.zero..<Tick(Int64(ticks)), pacing: pacing) { _, tickTime in
            signalFeeder.feed(upTo: tickTime, to: recorders)
        }
        let end = clock.time(of: Tick(Int64(ticks)))
        signalFeeder.flush(upToSample: signal.sampleIndex(at: end), to: recorders)
        return report
    }
}
