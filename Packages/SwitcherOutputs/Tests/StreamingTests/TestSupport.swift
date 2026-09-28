import CoreMedia
import CoreVideo
import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

// StreamingTests 公用：可控的传输层（FakeTransport）、可控的视频编码后端（FakeVideoBackend）、帧 / 音频喂料。

/// 可控传输层：模拟排空速率、停滞、断线、连接失败；记录收到的每个样本。线程安全（发送 Task 与测试线程都碰）。
final class FakeTransport: StreamTransport, @unchecked Sendable {
    struct Behavior: Sendable {
        /// connect 抛错。
        var connectFails = false
        /// 排空速率（字节 / 秒）；nil = 无限快。
        var drainBytesPerSecond: Int?
        /// 停滞：永远不排空、totalBytesOut 不涨。
        var stalled = false
        /// 收到这么多视频帧之后 isConnected 变 false。
        var disconnectAfterVideoFrames: Int?
        /// 起步对齐方式。
        var alignment: StartAlignment = .dtsOffset
        /// connect 要花这么久（模拟远端握手 / 慢服务器；W2-D2 握手期间排队的用例用）。
        var connectDelaySeconds: Double = 0
    }

    struct SentVideo: Sendable {
        let tick: Tick
        let tickTime: HostTime
        let isKeyframe: Bool
        let bytes: Int
        let dtsOffset: HostDuration
        let at: HostTime
    }

    let protocolName = "fake"
    let startAlignment: StartAlignment
    let behavior: Behavior
    let attempt: Int
    private let lock = NSLock()
    private(set) var connected = false
    private(set) var closed = false
    private(set) var video: [SentVideo] = []
    private(set) var audioTimes: [HostTime] = []
    private var queued = 0
    private var totalOut = 0
    private var lastDrain = HostClock.now()
    private var drainRemainder = 0.0

    init(behavior: Behavior, attempt: Int) {
        self.behavior = behavior
        self.attempt = attempt
        startAlignment = behavior.alignment
    }

    var sentVideo: [SentVideo] { lock.withLock { video } }
    var sentAudioTimes: [HostTime] { lock.withLock { audioTimes } }
    var isClosed: Bool { lock.withLock { closed } }

    func connect() async throws {
        if behavior.connectDelaySeconds > 0 { try? await Task.sleep(for: .milliseconds(Int(behavior.connectDelaySeconds * 1000))) }
        if behavior.connectFails { throw StreamTransportError.connectFailed("fake") }
        lock.withLock { connected = true; lastDrain = HostClock.now() }
    }

    func send(video sample: EncodedVideoSample, dtsOffset: HostDuration) async throws {
        lock.withLock {
            drainLocked()
            video.append(SentVideo(tick: sample.tick, tickTime: sample.tickTime, isKeyframe: sample.isKeyframe, bytes: sample.byteCount,
                                   dtsOffset: dtsOffset, at: HostClock.now()))
            queued += sample.byteCount
            if let n = behavior.disconnectAfterVideoFrames, video.count >= n { connected = false }
        }
    }

    func send(audio packet: EncodedAudioPacket) async throws {
        lock.withLock {
            drainLocked()
            audioTimes.append(packet.hostTime)
            queued += packet.byteCount
        }
    }

    func isConnected() async -> Bool { lock.withLock { connected } }

    func report() async -> TransportReport {
        lock.withLock {
            drainLocked()
            return TransportReport(queuedBytes: queued, totalBytesOut: totalOut, totalBytesIn: 0, updatedAt: HostClock.now())
        }
    }

    func close() async {
        lock.withLock { connected = false; closed = true }
    }

    /// 按时间和速率排空。
    private func drainLocked() {
        let now = HostClock.now()
        let elapsed = (now - lastDrain).seconds
        lastDrain = now
        if behavior.stalled { return }
        guard let rate = behavior.drainBytesPerSecond else {
            totalOut += queued
            queued = 0
            return
        }
        drainRemainder += Double(rate) * elapsed
        let bytes = min(queued, Int(drainRemainder))
        drainRemainder -= Double(bytes)
        queued -= bytes
        totalOut += bytes
    }
}

/// 造 FakeTransport 的工厂：按第几次连接给行为，记录造过的所有对象。
final class FakeTransportFactory: StreamTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeTransport] = []
    private let behaviorFor: @Sendable (Int) -> FakeTransport.Behavior

    init(_ behaviorFor: @escaping @Sendable (Int) -> FakeTransport.Behavior) {
        self.behaviorFor = behaviorFor
    }

    convenience init(behavior: FakeTransport.Behavior) {
        self.init { _ in behavior }
    }

    var transports: [FakeTransport] { lock.withLock { made } }

    func makeTransport(for destination: StreamDestination, audioFormat: AudioEncoder.Configuration?) throws -> any StreamTransport {
        lock.withLock {
            let t = FakeTransport(behavior: behaviorFor(made.count + 1), attempt: made.count + 1)
            made.append(t)
            return t
        }
    }
}

/// 可控视频编码后端：每帧同步交出一个固定大小的"压缩样本"（数据全 0），关键帧按间隔或按要求。
final class FakeVideoBackend: VideoEncoderBackend, @unchecked Sendable {
    let frameBytes: Int
    let keyframeInterval: Int
    private var output: (@Sendable (EncodedVideoSample) -> Void)?
    private var count = 0
    private let formatDescription: CMFormatDescription
    private let lock = NSLock()

    init(frameBytes: Int = 12_500, keyframeInterval: Int = 120) {
        self.frameBytes = frameBytes
        self.keyframeInterval = keyframeInterval
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 640, height: 360, extensions: nil, formatDescriptionOut: &fd)
        formatDescription = fd!
    }

    func prepare(output: @escaping @Sendable (EncodedVideoSample) -> Void, dropped: @escaping @Sendable () -> Void) throws {
        lock.withLock { self.output = output; count = 0 }
    }

    func encode(_ frame: RenderedFrame, forceKeyframe: Bool) throws {
        let (isKey, out): (Bool, (@Sendable (EncodedVideoSample) -> Void)?) = lock.withLock {
            let key = forceKeyframe || count % keyframeInterval == 0
            count += 1
            return (key, output)
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frameBytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: frameBytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frameBytes)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.tickTime.cmTime, decodeTimeStamp: .invalid)
        var size = frameBytes
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        let now = HostClock.now()
        out?(EncodedVideoSample(sampleBuffer: sb!, tick: frame.tick, tickTime: frame.tickTime, isKeyframe: isKey, byteCount: frameBytes,
                                encodeLatency: .zero, outputTime: now))
    }

    func flush() {}
    func invalidate() {}
}

/// 帧喂料：小尺寸 NV12（不看内容），按 tick 给。
final class FrameSource {
    let format: ProgramFormat
    let clock: TickClockSpec
    private let feeder: PatternFeeder

    init(format: ProgramFormat = ProgramFormat(width: 640, height: 360, frameRate: .fps60), t0: HostTime) throws {
        self.format = format
        clock = TickClockSpec(t0: t0, frameRate: format.frameRate)
        feeder = try PatternFeeder(configuration: .init(format: format, poolSize: 8))
    }

    func frame(tick: Int) throws -> RenderedFrame {
        try feeder.makeFrame(tick: Tick(Int64(tick)), clock: clock)
    }
}

/// 音频喂料：TestSignal 按 256 帧块给，块首 host time 精确。`startSample` 为负 = 从 t0 之前开始喂（headless 里音频引擎比视频早起的顺序）。
final class AudioSource {
    let signal: TestSignal
    let feeder: SignalFeeder
    init(t0: HostTime, startSample: Int64 = 0) {
        signal = TestSignal(t0: t0)
        feeder = SignalFeeder(signal: signal, startSample: startSample)
    }
    func feed(upTo time: HostTime, to consumers: [any AudioBlockConsumer]) { feeder.feed(upTo: time, to: consumers) }
    /// 精确喂到样本序号 end（含不足一块的尾巴）。
    func flush(upToSample end: Int64, to consumers: [any AudioBlockConsumer]) { feeder.flush(upToSample: end, to: consumers) }
}

extension StreamOutput {
    /// 测试用：假后端、假传输层。
    static func makeForTest(name: String, factory: any StreamTransportFactory, audio: Bool = true, url: String = "rtmp://127.0.0.1:1935/test",
                            reconnect: ReconnectPolicy = ReconnectPolicy(initialSeconds: 0.1, multiplier: 2, maxSeconds: 0.4),
                            queue: StreamOutput.QueuePolicy = .init(videoFrames: 30, maxInFlightBytes: 400_000, stallSeconds: 0.5, drainSeconds: 1,
                                                                     lingerSeconds: 0, pollIntervalMs: 20),
                            backend: FakeVideoBackend = FakeVideoBackend(), format: ProgramFormat = ProgramFormat(width: 640, height: 360, frameRate: .fps60),
                            connectTimeout: Double = 1) throws -> StreamOutput {
        let cfg = StreamOutput.Configuration(
            name: name, format: format, video: VideoEncodeSettings(codec: .h264, bitrateBps: 6_000_000, keyframeIntervalFrames: 120),
            audio: audio ? AudioEncodeSettings() : nil, stream: StreamSettings(url: url), reconnect: reconnect, queue: queue,
            connectTimeoutSeconds: connectTimeout)
        return try StreamOutput(configuration: cfg, transportFactory: factory, videoBackend: backend)
    }
}

/// 等到条件成立或超时。
func waitUntil(timeout: Double, interval: Double = 0.02, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}
