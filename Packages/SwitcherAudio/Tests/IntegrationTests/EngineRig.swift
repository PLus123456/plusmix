import XCTest
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 离线搭台：状态机 + 音频引擎（离线、手动控制）+ 离线驱动 + 按 host time 交付的合成源。
/// 时间线：驱动第 0 块首样本 = t0（也是节目第 0 拍 = 合成信号的 click 0）。每块：喂源到块首（真源在一块采完的那一刻交付，
/// 所以块 T 渲染时环里只有时刻 < T 的样本；喂到块尾会把年龄少算一块，实测 447 vs 703）→ 状态机准备到"块尾所在拍 + 1"
/// （引擎渲染线程比拍点早一拍准备快照，这里等价）→ 控制循环（now = 块首）→ 渲染一块 → 泵。
final class EngineRig {
    let sm: StateMachine
    let engine: AudioEngine
    let driver: OfflineAudioDriver
    let clock: TickClockSpec
    let t0: HostTime
    let blockFrames: Int
    var sources: [Int: OfflineAudioSource] = [:]
    var captures: [AudioTapSource: TimedCapture] = [:]
    var tokens: [AudioTapSource: AudioConsumerToken] = [:]
    /// 每块渲染后回调（块、块首 host time）。
    var afterBlock: ((OfflineBlock) -> Void)?

    init(state: MixerState, frameRate: FrameRate = .fps60, blockFrames: Int = 256, t0: HostTime = HostClock.now(),
         configure: ((inout AudioEngineConfiguration) -> Void)? = nil) async throws {
        self.t0 = t0
        self.blockFrames = blockFrames
        clock = TickClockSpec(t0: t0, frameRate: frameRate)
        sm = StateMachine(initialState: state)
        sm.start()
        var cfg = AudioEngineConfiguration.offline
        cfg.blockFrames = blockFrames
        configure?(&cfg)
        engine = try AudioEngine(stateMachine: sm, configuration: cfg)
        driver = OfflineAudioDriver(mixer: engine.mixer, blockFrames: blockFrames, startHostTime: t0)
        try await engine.start(clock: clock)
    }

    func shutdown() async {
        await engine.stop()
        sm.stop()
    }

    /// 加一路合成源并注册给引擎。默认信号 = TestSignal（1 kHz −20 dBFS + 每秒 click，t0 与节目第 0 拍相同）。
    @discardableResult
    func addSource(number: Int, channels: Int = 1, driftPpm: Double = 0, producerBlock: Int = 256, sourceT0: HostTime? = nil,
                   hints: AudioInputHints? = nil,
                   generator: ((Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void)? = nil) throws -> OfflineAudioSource {
        let src = OfflineAudioSource(channels: channels, t0: sourceT0 ?? t0, driftPpm: driftPpm, producerBlockFrames: producerBlock,
                                     capacityFrames: 65_536, generator: generator)
        sources[number] = src
        var h = hints ?? AudioInputHints()
        if hints == nil { h.producerBlockFrames = producerBlock }
        try engine.registerInput(number: number, ring: src.ring, hints: h)
        return src
    }

    /// 给某个来源挂一个采集消费者。
    @discardableResult
    func capture(_ source: AudioTapSource) throws -> TimedCapture {
        let key = source.normalized
        if let c = captures[key] { return c }
        let cap = TimedCapture()
        let consumer = CaptureConsumer(name: "capture-\(key)", capture: cap)
        tokens[key] = try engine.addConsumer(consumer, source: key)
        captures[key] = cap
        consumers.append(consumer)
        return cap
    }
    private var consumers: [CaptureConsumer] = []

    /// 跑 n 块。
    func run(blocks: Int) async {
        for _ in 0..<blocks {
            let start = driver.nextBlockHostTime
            let end = driver.nextBlockEndHostTime
            for (_, s) in sources { s.deliver(upTo: start) }
            await sm.prepare(upTo: clock.tick(at: end) + 1)
            engine.runControlCycle(now: start)
            let b = driver.renderNext()
            engine.pumpOnce()
            afterBlock?(b)
        }
    }

    /// 跑到某个 host time（含）。
    func run(until time: HostTime) async {
        while driver.nextBlockHostTime <= time { await run(blocks: 1) }
    }

    /// 跑 n 秒。
    func run(seconds: Double) async {
        await run(blocks: Int((seconds * 48000 / Double(blockFrames)).rounded()))
    }

    /// 当前块首相对 t0 的秒数。
    var elapsedSeconds: Double { (driver.nextBlockHostTime - t0).seconds }
}

/// 把收到的块存进 TimedCapture 的消费者。
final class CaptureConsumer: AudioBlockConsuming, @unchecked Sendable {
    let consumerName: String
    let capture: TimedCapture
    init(name: String, capture: TimedCapture) { consumerName = name; self.capture = capture }
    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
        capture.append(planes: planes, frames: frameCount, hostTime: hostTime)
    }
}

/// 常用状态：4 路合成输入（1–4），PGM 1、PVW 2，AFV 可选。
enum States {
    static func fourInputs(afv: Bool = true, program: Int = 1, preview: Int = 2, frameRate: FrameRate = .fps60) -> MixerState {
        var s = MixerState(format: ProgramFormat(width: 1920, height: 1080, frameRate: frameRate))
        s.inputs = (1...4).map { InputConfig(number: $0, name: "机位 \($0)", source: .synthetic(settings: SyntheticSourceSettings())) }
        s.program = program
        s.preview = preview
        s.audio.afv = afv
        return s
    }
}

extension TimedCapture {
    /// 每个 click 起点相对 t0 的整秒偏差（ms，音频超前为正：click 早于整秒为正）。
    func clickOffsetsMs(t0: HostTime, onset: Float = 0.5) -> [(second: Int, offsetMs: Double)] {
        IT.clickOnsets(left, onset: onset).compactMap { i in
            let rel = (hostTime(ofSample: i) - t0).seconds
            let k = Int(rel.rounded())
            guard k >= 1 else { return nil }
            return (k, (Double(k) - rel) * 1000)
        }
    }
    /// 某段 host time 区间的 RMS（左声道）。
    func rms(from: HostTime, to: HostTime) -> Double {
        guard let first = firstHostTime else { return 0 }
        let a = max(0, Int(((from - first).seconds * sampleRate).rounded()))
        let b = min(left.count, Int(((to - first).seconds * sampleRate).rounded()))
        guard b > a else { return 0 }
        return IT.rms(left[a..<b])
    }
}
