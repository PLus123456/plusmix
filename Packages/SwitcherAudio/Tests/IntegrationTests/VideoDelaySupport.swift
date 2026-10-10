import Foundation
import CoreVideo
import Darwin
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

// W1-B4（prompt 105，提案 028）的集成测试工装：真视频引擎（假渲染器）+ 空设备音频引擎共用一台状态机，
// 音频引擎在 videoDelay 补偿方式下把 Master 效果链的实测延迟交给视频引擎（VideoDelayControl）。

/// 记下音频引擎交过来的设定值（离线用例：不需要真引擎）。
final class StubVideoDelay: VideoDelayControl, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostDuration] = []
    func setVideoDelayTarget(_ delay: HostDuration) { lock.lock(); values.append(delay); lock.unlock() }
    var targets: [HostDuration] { lock.lock(); defer { lock.unlock() }; return values }
    var last: HostDuration? { targets.last }
}

/// 假渲染器（与 SwitcherEngineTests 的 FakeRenderer 同一路子）：render 立即返回，工作线程在提交 + gpuDelay 时发完成回调；
/// program 帧 pts = 拍点（引擎的契约），像素不看。
final class AVFakeRenderer: Renderer, @unchecked Sendable {
    var sink: (any RenderSink)?
    let gpuDelay: HostDuration
    private struct Pending { var tick: Tick; var tickTime: HostTime; var submitTime: HostTime }
    private let lock = NSLock()
    private var queue: [Pending] = []
    private let semaphore = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var worker: Thread?
    private let done = DispatchSemaphore(value: 0)
    private var buffer: CVPixelBuffer?
    let submitted = Atomic<UInt64>(0)
    let completed = Atomic<UInt64>(0)

    init(gpuDelay: HostDuration = HostDuration(milliseconds: 2)) { self.gpuDelay = gpuDelay }

    func prepare(format: ProgramFormat, maxInputs: Int) throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        buffer = pb
        running.store(true, ordering: .releasing)
        let t = Thread { [self] in
            while running.load(ordering: .acquiring) {
                semaphore.wait()
                while true {
                    lock.lock()
                    let p = queue.isEmpty ? nil : queue.removeFirst()
                    lock.unlock()
                    guard let p else { break }
                    mach_wait_until((p.submitTime + gpuDelay).ticks)
                    let end = HostClock.now()
                    let frame = Frame(pixelBuffer: buffer!, pts: p.tickTime, duration: HostDuration(milliseconds: 16.667), color: .bt709Limited,
                                      inputNumber: 0, sequence: UInt64(p.tick.rawValue), ingressTime: end)
                    completed.add(1, ordering: .relaxed)
                    sink?.renderer(self, didComplete: RenderedFrame(tick: p.tick, tickTime: p.tickTime, program: frame,
                                                                    submitTime: p.submitTime, gpuStart: p.submitTime, gpuEnd: end))
                }
            }
            done.signal()
        }
        t.name = "it-fake-gpu"
        t.qualityOfService = .userInteractive
        worker = t
        t.start()
    }

    func render(tick: Tick, at tickTime: HostTime, snapshot: MixerSnapshot, inputs: RenderInputTable) -> RenderVerdict {
        lock.lock()
        queue.append(Pending(tick: tick, tickTime: tickTime, submitTime: HostClock.now()))
        lock.unlock()
        submitted.add(1, ordering: .relaxed)
        semaphore.signal()
        return .submitted
    }

    func shutdown() {
        guard worker != nil else { return }
        // 先等已提交的帧都完成回调，再停线程
        let deadline = HostClock.now() + HostDuration(seconds: 2)
        while completed.load(ordering: .acquiring) < submitted.load(ordering: .acquiring) && HostClock.now() < deadline { usleep(500) }
        running.store(false, ordering: .releasing)
        semaphore.signal()
        done.wait()
        worker = nil
    }
}

/// 视频消费者：记每拍的 tickTime / program.pts / gpuEnd / 派发时刻（测试线程读，锁保护；这里不量分配）。
final class FrameTimingRecorder: FrameConsumer, @unchecked Sendable {
    struct Entry { var tick: Int64; var tickTime: HostTime; var pts: HostTime; var gpuEnd: HostTime; var dispatched: HostTime }
    let consumerName = "av-timing"
    private let lock = NSLock()
    private var list: [Entry] = []
    private var lastTick: Int64 = .min
    private var lastTime: UInt64 = 0
    private(set) var duplicatesOrOutOfOrder = 0
    private(set) var ptsRegressions = 0

    func consume(_ frame: RenderedFrame) {
        let now = HostClock.now()
        lock.lock()
        if frame.tick.rawValue <= lastTick { duplicatesOrOutOfOrder += 1 }
        if frame.tickTime.ticks <= lastTime { ptsRegressions += 1 }
        lastTick = frame.tick.rawValue
        lastTime = frame.tickTime.ticks
        list.append(Entry(tick: frame.tick.rawValue, tickTime: frame.tickTime, pts: frame.program.pts, gpuEnd: frame.gpuEnd, dispatched: now))
        lock.unlock()
    }

    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return list }
    var problems: (dupOrOrder: Int, ptsRegressions: Int) { lock.lock(); defer { lock.unlock() }; return (duplicatesOrOutOfOrder, ptsRegressions) }
    func entry(tick: Int64) -> Entry? { entries.first { $0.tick == tick } }
}

/// 直接挂在混音器上的 Master tap（不经泵）：块的 host time 就是混音块的输出时刻——空设备时 = "扬声器出声"的时刻（A5 模拟用）。
/// 后台线程每 2 ms 弹一次，记下每个 click 起点的输出时刻。
final class SpeakerTap: @unchecked Sendable {
    private let mixer: AudioMixer
    private let tap: AudioBlockTap
    private let lock = NSLock()
    private var onsets: [HostTime] = []
    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private var holdOff = 0

    init?(mixer: AudioMixer) {
        guard let tap = mixer.addTap(source: .bus(.master), capacityBlocks: 256) else { return nil }
        self.mixer = mixer
        self.tap = tap
        let t = Thread { [self] in loop() }
        t.name = "it-speaker-tap"
        t.start()
    }

    private func loop() {
        let channels = tap.channels, maxFrames = tap.maxFrames
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: channels * maxFrames)
        let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        for c in 0..<channels { planes[c] = storage + c * maxFrames }
        defer { planes.deallocate(); storage.deallocate(); finished.signal() }
        while !stopFlag.load(ordering: .acquiring) {
            while let b = tap.pop(into: UnsafePointer(planes)) {
                let x = planes[0]!
                for i in 0..<b.frames {
                    if holdOff > 0 { holdOff -= 1; continue }
                    if abs(x[i]) >= 0.5 {
                        let t = b.hostTime + HostDuration(nanoseconds: Int64((Double(i) * 1e9 / 48_000).rounded()))
                        lock.lock(); onsets.append(t); lock.unlock()
                        holdOff = 2400
                    }
                }
            }
            usleep(2000)
        }
    }

    /// 第 k 秒那个 click 的出声时刻（离 t0 + k s 最近、±0.5 s 内）。
    func onset(second k: Int, t0: HostTime) -> HostTime? {
        let nominal = t0 + HostDuration(seconds: Double(k))
        lock.lock(); defer { lock.unlock() }
        return onsets.min { abs(($0 - nominal).seconds) < abs(($1 - nominal).seconds) }.flatMap { abs(($0 - nominal).seconds) < 0.5 ? $0 : nil }
    }

    func stop() {
        stopFlag.store(true, ordering: .releasing)
        finished.wait()
        mixer.removeTap(tap)
    }
}

/// 一台状态机 + 真视频引擎（假渲染器）+ 空设备音频引擎（扬声器静音、Master 照常处理）+ 实时合成音频源（TestSignal：每秒一个 click）。
/// 视频第 60k 拍 = 第 k 个闪光，与 click 共用 t0（W1-A 的约定），所以 A2 = 闪光帧的 tickTime − click 的 PTS。
final class AVSyncRig {
    let sm: StateMachine
    let renderer: AVFakeRenderer
    let video: Engine
    let audio: AudioEngine
    let recorder = FrameTimingRecorder()
    let t0: HostTime
    let clock: TickClockSpec
    var sources: [RealtimeSource] = []

    init(compensation: AVCompensation, attach: Bool = true, gpuDelay: HostDuration = HostDuration(milliseconds: 2)) async throws {
        sm = StateMachine(initialState: States.fourInputs(afv: false))
        renderer = AVFakeRenderer(gpuDelay: gpuDelay)
        video = Engine(stateMachine: sm, renderer: renderer, maxInputs: 8)
        var cfg = AudioEngineConfiguration()
        cfg.output = .null
        cfg.outputChannelMap = BusChannelMap(master: nil)
        cfg.avCompensation = compensation
        audio = try AudioEngine(stateMachine: sm, configuration: cfg)
        if attach { audio.videoDelay = video }
        video.addConsumer(recorder)
        try await video.warmUp()                       // 起状态机线程
        t0 = HostClock.now() + HostDuration(milliseconds: 300)
        clock = TickClockSpec(t0: t0, frameRate: .fps60)
        try await audio.start(clock: clock)
        let src = RealtimeSource(t0: t0)
        var hints = AudioInputHints()
        hints.producerBlockFrames = 256
        try audio.registerInput(number: 1, ring: src.ring, hints: hints)
        src.start()
        sources.append(src)
        try await video.start(t0: t0)
    }

    /// 等到 t0 + seconds。
    func wait(until seconds: Double) async {
        let end = t0 + HostDuration(seconds: seconds)
        while HostClock.now() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func setMasterEffects(_ effects: [EffectSlot]) async {
        _ = await sm.apply(.setBusEffects(bus: .master, effects: effects))
    }

    func shutdown() async {
        for s in sources { s.stop() }
        await video.stop()
        await audio.stop()
    }
}
