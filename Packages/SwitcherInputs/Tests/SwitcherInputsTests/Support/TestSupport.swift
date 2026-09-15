import CoreVideo
import Foundation
import Synchronization
import XCTest
import CSwitcherContracts
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherInputs

/// 仓库根（从 #filePath 往上找到含 Tests/Fixtures 的目录；Tests/Fixtures/README.md 的规矩）。
enum RepoPaths {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Tests/Fixtures").path) { return url }
        }
        fatalError("找不到仓库根（Tests/Fixtures）")
    }()
    static let fixtures = root.appendingPathComponent("Tests/Fixtures")
    static let patternMov = fixtures.appendingPathComponent("pattern.mov")
    /// 测试输出目录（$SWITCHER_TEST_OUTPUT 或 $TMPDIR/switcher-inputs-tests）。
    static let output: URL = {
        let base = ProcessInfo.processInfo.environment["SWITCHER_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("switcher-inputs-tests")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}

/// 音频环的测试替身：记录每次 write 的块（首帧 host time + 各声道样本），不做消费。
/// `raw` 是一块零初始化的 sw_audio_ring（契约要求有这个指针；测试不读它）。
final class RecordingAudioRing: AudioRing, @unchecked Sendable {
    struct Block: Sendable {
        let hostTime: HostTime
        let frameCount: Int
        let channel0: [Float]
        let channel1: [Float]
    }
    let channelCount: Int
    let sampleRate = AudioFormat.sampleRate
    let capacityFrames: Int
    let raw: UnsafeMutablePointer<sw_audio_ring>
    private let blocks = Mutex<[Block]>([])
    private let written = Atomic<UInt64>(0)
    /// 记录的样本上限（超过后只计数不存），免得长测试吃内存。
    var keepSamplesUpTo = 48_000 * 30

    init(channelCount: Int = 2, capacityFrames: Int = 1 << 16) {
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        raw = .allocate(capacity: 1)
        raw.initialize(to: sw_audio_ring())
    }
    deinit { raw.deallocate() }

    var availableFrames: Int { Int(written.load(ordering: .relaxed)) }
    var stats: AudioRingStats { AudioRingStats(framesWritten: written.load(ordering: .relaxed), framesRead: 0, overruns: 0, underruns: 0) }

    func write(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Int {
        let total = written.add(UInt64(frameCount), ordering: .relaxed).oldValue
        let keep = Int(total) < keepSamplesUpTo
        let c0 = keep ? Array(UnsafeBufferPointer(start: planes[0], count: frameCount)) : []
        let c1 = keep && channelCount > 1 ? Array(UnsafeBufferPointer(start: planes[1], count: frameCount)) : []
        blocks.withLock { $0.append(Block(hostTime: hostTime, frameCount: frameCount, channel0: c0, channel1: c1)) }
        return frameCount
    }

    func read(into planes: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> AudioReadResult {
        AudioReadResult(framesRead: 0, firstFrameHostTime: nil)
    }

    var recorded: [Block] { blocks.withLock { $0 } }
}

/// 模拟引擎的拍点循环：按真实时间等到每一拍，然后调 body（body 里通常是 slot.latest(...)）。不挂实时策略，
/// 醒来可能晚 1–7 ms；对 `latest(atOrBefore: t_n)` 的结果没有影响（上限是 t_n 不是现在）。
struct TickDriver {
    let timing: ProgramTiming

    /// 从第 `from` 拍起跑 `count` 拍。返回每拍 body 的返回值。
    @discardableResult
    func run<T>(from: Tick, count: Int, _ body: (Tick, HostTime) -> T) -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        var n = from
        for _ in 0..<count {
            let t = timing.time(of: n)
            InputThread.wait(until: t)
            out.append(body(n, t))
            n += 1
        }
        return out
    }

    /// 现在之后至少 `leadMs` 的第一拍。
    func firstTick(afterMs leadMs: Double = 50) -> Tick {
        timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: leadMs))
    }
}

/// 解出一帧里的测试图案帧号（pattern.mov 的帧号 = 帧序号）。
func frameNumber(of frame: Frame?) -> Int? {
    guard let frame, let d = TestPattern.decode(pixelBuffer: frame.pixelBuffer), let n = d.frameNumber else { return nil }
    return Int(n)
}

/// 一次挑帧的记录。不持有 Frame（持有会让解码器的像素池无法复用），当场解出帧号。
struct Pick: CustomStringConvertible {
    let tick: Tick
    let tickTime: HostTime
    let number: Int?
    let pts: HostTime?
    let ingressTime: HostTime?
    let pixelFormat: PixelFormat?
    let inputNumber: Int?
    let sequence: UInt64?
    /// 黑场判定用：NV12 时 (100,100) 处的 Y；BGRA 时首像素的 B G R A。
    let probe: [Int]

    init(tick: Tick, tickTime: HostTime, frame: Frame?) {
        self.tick = tick
        self.tickTime = tickTime
        number = frameNumber(of: frame)
        pts = frame?.pts
        ingressTime = frame?.ingressTime
        pixelFormat = frame?.pixelFormat
        inputNumber = frame?.inputNumber
        sequence = frame?.sequence
        var probe: [Int] = []
        if let pb = frame?.pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pb) {
                let p = base.assumingMemoryBound(to: UInt8.self)
                probe = [Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3])]
            } else if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                probe = [Int(base.assumingMemoryBound(to: UInt8.self)[100 * stride + 100])]
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        self.probe = probe
    }
    var hasFrame: Bool { pts != nil }
    var description: String { "\(tick): \(number.map(String.init) ?? "nil") pts=\(pts.map { String($0.ticks) } ?? "-")" }
}

extension XCTestCase {
    /// 等到条件成立或超时。
    func waitUntil(timeoutMs: Double, pollMs: Double = 5, _ condition: () -> Bool) -> Bool {
        let deadline = HostClock.now() + HostDuration(milliseconds: timeoutMs)
        while HostClock.now() < deadline {
            if condition() { return true }
            usleep(UInt32(pollMs * 1000))
        }
        return condition()
    }
}
