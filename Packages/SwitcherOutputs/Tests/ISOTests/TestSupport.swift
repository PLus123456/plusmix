import CoreVideo
import Foundation
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherOutputs
@testable import SwitcherISO

// ISO 测试公用：外部工具（ffprobe / frameprobe）、临时目录、计数消费者、同步停止。

enum Tools {
    static let ffprobe = "/opt/homebrew/bin/ffprobe"

    static func requireFFprobe() throws {
        if !FileManager.default.isExecutableFile(atPath: ffprobe) { throw XCTSkip("BLOCKED-工具：没有 \(ffprobe)（brew install ffmpeg）") }
    }

    /// 编好的 frameprobe（先 `swift build -c release --package-path Tools/frameprobe`）。
    static func frameprobe() throws -> URL {
        guard let root = repoRoot() else { throw XCTSkip("找不到仓库根") }
        for c in ["release", "debug"] {
            let u = root.appendingPathComponent("Tools/frameprobe/.build/\(c)/frameprobe")
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        throw XCTSkip("BLOCKED-工具：没有编好的 frameprobe（swift build -c release --package-path Tools/frameprobe）")
    }

    static func repoRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) { return url }
        }
        return nil
    }

    struct Output { let stdout: Data; let stderr: String; let code: Int32 }
    static func run(_ path: String, _ args: [String]) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(stdout: o, stderr: String(decoding: e, as: UTF8.self), code: p.terminationStatus)
    }

    struct Stream { let type: String; let duration: Double; let frames: Int? }
    /// 流信息；errors 非空 = 文件有错。
    static func probe(_ url: URL) throws -> (streams: [Stream], errors: String) {
        let o = try run(ffprobe, ["-v", "error", "-print_format", "json", "-show_entries", "stream=codec_type,duration,nb_frames", url.path])
        let obj = (try? JSONSerialization.jsonObject(with: o.stdout) as? [String: Any]) ?? [:]
        let arr = obj["streams"] as? [[String: Any]] ?? []
        let streams = arr.map { s in
            Stream(type: s["codec_type"] as? String ?? "?", duration: (s["duration"] as? String).flatMap(Double.init) ?? 0,
                   frames: (s["nb_frames"] as? String).flatMap(Int.init))
        }
        return (streams, o.stderr.trimmingCharacters(in: .whitespacesAndNewlines) + (o.code == 0 ? "" : " (exit \(o.code))"))
    }

    /// 视频轨第一个包的 pts_time。
    static func firstVideoPTS(_ url: URL) throws -> Double? {
        let o = try run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time", "-of", "csv=p=0", "-read_intervals", "%+#1", url.path])
        let line = String(decoding: o.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        return Double(line.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ""))
    }
}

/// 测试输出目录：$SWITCHER_TEST_OUTPUT 或临时目录。
enum TestPaths {
    static let root: URL = {
        let base = ProcessInfo.processInfo.environment["SWITCHER_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("switcher-iso-tests")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}

/// 只数帧的消费者（推流 / 虚拟摄像头的替身）。
final class CountingConsumer: FrameConsumer, @unchecked Sendable {
    let consumerName: String
    private let count = Atomic<UInt64>(0)
    private let lastTick = Atomic<Int64>(Int64.min)
    init(name: String) { consumerName = name }
    func consume(_ frame: RenderedFrame) {
        count.add(1, ordering: .relaxed)
        lastTick.store(frame.tick.rawValue, ordering: .relaxed)
    }
    var frames: UInt64 { count.load(ordering: .relaxed) }
    var last: Int64 { lastTick.load(ordering: .relaxed) }
}

/// 记下收到的每一帧（tick、拍点、输入帧序号）的消费者。
final class RecordingSink: FrameConsumer, @unchecked Sendable {
    let consumerName = "sink"
    private let lock = NSLock()
    private var received: [(tick: Tick, tickTime: HostTime, sequence: UInt64, inputNumber: Int)] = []
    func consume(_ frame: RenderedFrame) {
        lock.withLock { received.append((frame.tick, frame.tickTime, frame.program.sequence, frame.program.inputNumber)) }
    }
    var frames: [(tick: Tick, tickTime: HostTime, sequence: UInt64, inputNumber: Int)] { lock.withLock { received } }
}

/// 一个 NV12 缓冲（测试造帧用）。
func makePixelBuffer(width: Int = 64, height: Int = 36) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
    return pb!
}

func makeFrame(input: Int, sequence: UInt64, pts: HostTime, buffer: CVPixelBuffer? = nil) -> Frame {
    Frame(pixelBuffer: buffer ?? makePixelBuffer(), pts: pts, duration: HostDuration(milliseconds: 16), color: .bt709Limited,
          inputNumber: input, sequence: sequence, ingressTime: pts)
}

extension XCTestCase {
    /// 同步停止录制。
    func stopAndWait(_ recorder: Recorder, atTick tick: Tick?, timeout: TimeInterval = 60) throws -> RecordingResult {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<RecordingResult>()
        recorder.stop(atTick: tick) { r in box.set(r); sem.signal() }
        guard sem.wait(timeout: .now() + timeout) == .success else { throw TestError.timeout("stop \(recorder.consumerName)") }
        return try box.get().get()
    }

    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2000)
        }
        return condition()
    }
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    private var value: Result<T, Error>?
    private let lock = NSLock()
    func set(_ v: Result<T, Error>) { lock.withLock { value = v } }
    func get() -> Result<T, Error> { lock.withLock { value ?? .failure(TestError.timeout("没有结果")) } }
}

enum TestError: Error { case timeout(String), message(String) }

func runProcess(_ path: String, _ args: [String]) throws -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
