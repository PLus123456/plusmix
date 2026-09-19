import CoreVideo
import CSwitcherNDI
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine

/// 只看亮度的帧号解码（UYVY 帧）：帧号行 32 块，每块取中心一半区域的 Y 均值 > 128 记 1，再过 CRC。
/// 便宜到可以在 push 路径上每帧做（约 8k 次字节读）。
enum UYVYDecode {
    static func frameNumber(of pb: CVPixelBuffer) -> UInt32? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_422YpCbCr8 else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w >= 320, h >= 180 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let g = TestPattern.Geometry(width: w, height: h)
        var word: UInt32 = 0
        let p = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<32 {
            let r = g.sampleRect(of: g.blockRect(row: 0, index: i))
            var sum = 0
            for y in r.y..<(r.y + r.height) {
                let row = p + y * stride
                for x in r.x..<(r.x + r.width) { sum += Int(row[x * 2 + 1]) }
            }
            let mean = sum / (r.width * r.height)
            if mean > 128 { word |= 1 << UInt32(31 - i) }
        }
        return TestPattern.decodeWord(word)
    }

    /// 完整解码：UYVY → NV12 scratch → TestPattern.decode（帧号、时间戳、输入 ID、闪光）。
    static func decodeAll(_ pb: CVPixelBuffer) -> TestPattern.Decoded? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_422YpCbCr8 else { return TestPattern.decode(pixelBuffer: pb) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let luma = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        let chroma = UnsafeMutablePointer<UInt8>.allocate(capacity: w * (h / 2))
        defer {
            luma.deallocate()
            chroma.deallocate()
        }
        sw_ndi_unpack_uyvy_to_nv12(base.assumingMemoryBound(to: UInt8.self), Int32(CVPixelBufferGetBytesPerRow(pb)), Int32(w), Int32(h),
                                   luma, Int32(w), chroma, Int32(w))
        return TestPattern.decode(.nv12(luma: UnsafeMutableRawPointer(luma), lumaBytesPerRow: w, chroma: UnsafeMutableRawPointer(chroma), chromaBytesPerRow: w),
                                  width: w, height: h)
    }
}

/// 帧槽装饰器：记录每次 push（序号、pts、ingress、帧号、格式）和每次 latest 返回的序号（按拍）。
/// push 路径上只做亮度帧号解码（微秒级）。输入线程 push、渲染 / 测试线程 latest。
final class RecordingSlot: FrameSlot, @unchecked Sendable {
    struct Pushed: Sendable {
        let sequence: UInt64
        let pts: HostTime
        let ingress: HostTime
        let frameNumber: UInt32?
        let pixelFormat: PixelFormat?
        let width: Int
        let height: Int
    }
    let inner: any FrameSlot
    private let pushed = Mutex<[Pushed]>([])
    private let picks = Mutex<[(time: HostTime, sequence: UInt64?)]>([])
    /// 也顺手把每帧的时间戳 / 输入 ID 解一次（贵一点，可关）。
    var decodeFully = false
    private let fullDecodes = Mutex<[UInt64: TestPattern.Decoded]>([:])

    init(inner: any FrameSlot) { self.inner = inner }

    var capacity: Int { inner.capacity }
    var stats: FrameSlotStats { inner.stats }

    func push(_ frame: Frame) {
        inner.push(frame)
        let n = UYVYDecode.frameNumber(of: frame.pixelBuffer) ?? TestPattern.decode(pixelBuffer: frame.pixelBuffer)?.frameNumber
        pushed.withLock {
            $0.append(Pushed(sequence: frame.sequence, pts: frame.pts, ingress: frame.ingressTime, frameNumber: n,
                             pixelFormat: frame.pixelFormat, width: frame.width, height: frame.height))
        }
        if decodeFully, let d = UYVYDecode.decodeAll(frame.pixelBuffer) {
            fullDecodes.withLock { $0[frame.sequence] = d }
        }
    }

    func latest(atOrBefore time: HostTime) -> Frame? {
        let f = inner.latest(atOrBefore: time)
        picks.withLock { $0.append((time, f?.sequence)) }
        return f
    }

    var pushedFrames: [Pushed] { pushed.withLock { $0 } }
    var pickedSequences: [(time: HostTime, sequence: UInt64?)] { picks.withLock { $0 } }
    var decoded: [UInt64: TestPattern.Decoded] { fullDecodes.withLock { $0 } }

    /// 帧号连续性：按序号排的推送帧里，帧号相邻差不为 1 的位置（跳号）数量。
    var frameNumberGaps: Int {
        let numbers = pushedFrames.compactMap(\.frameNumber)
        guard numbers.count > 1 else { return 0 }
        return zip(numbers, numbers.dropFirst()).filter { $1 != $0 + 1 }.count
    }
}

/// 音频环的测试替身：记录每次 write 的块（首帧 host time + 首声道样本）。
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
        written.add(UInt64(frameCount), ordering: .relaxed)
        let c0 = Array(UnsafeBufferPointer(start: planes[0], count: frameCount))
        let c1 = channelCount > 1 ? Array(UnsafeBufferPointer(start: planes[1], count: frameCount)) : []
        blocks.withLock { $0.append(Block(hostTime: hostTime, frameCount: frameCount, channel0: c0, channel1: c1)) }
        return frameCount
    }

    func read(into planes: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> AudioReadResult {
        AudioReadResult(framesRead: 0, firstFrameHostTime: nil)
    }

    var recorded: [Block] { blocks.withLock { $0 } }
}

/// 等到条件成立或超时。
func waitUntil(timeoutMs: Double, pollMs: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = HostClock.now() + HostDuration(milliseconds: timeoutMs)
    while HostClock.now() < deadline {
        if condition() { return true }
        usleep(UInt32(pollMs * 1000))
    }
    return condition()
}
