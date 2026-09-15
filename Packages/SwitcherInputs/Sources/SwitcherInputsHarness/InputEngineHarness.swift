import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherRender

/// 组装方：真状态机 + 真 Metal 渲染器 + 真引擎 + 真帧槽（包一层 L1 记录）+ L1 消费者。探针和测试共用；
/// 相当于 headless 的 --input 版本（headless 归 W2-C / G3，本会话不能改它）。
public final class InputEngineHarness: @unchecked Sendable {
    public let format: ProgramFormat
    public let timing: ProgramTiming
    public let renderer: MetalRenderer
    public let stateMachine: StateMachine
    public let engine: Engine
    public private(set) var slots: [(number: Int, slot: LatencyFrameSlot)] = []
    public private(set) var inputs: [any Input] = []
    public private(set) var consumer: LatencyConsumer?

    /// - Parameters:
    ///   - configs: 输入表（第一路是 PGM）。
    ///   - leadMs: t0 = 现在 + leadMs（要盖住输入起来的时间：摄像头会话 ~300 ms、文件首帧 ~100 ms）。
    public init(format: ProgramFormat, configs: [InputConfig], leadMs: Double = 600, engineOptions: EngineOptions = EngineOptions()) throws {
        self.format = format
        timing = ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: leadMs))
        var state = MixerState(format: format, inputs: configs, program: configs.first?.number ?? 0, preview: configs.dropFirst().first?.number ?? 0)
        state.transition = TransitionState(type: .cut, durationTicks: 0)
        try state.validate()
        renderer = try MetalRenderer()
        stateMachine = StateMachine(initialState: state)
        let maxNumber = configs.map(\.number).max() ?? 1
        engine = Engine(stateMachine: stateMachine, renderer: renderer, maxInputs: max(4, maxNumber), options: engineOptions)
    }

    /// 给某路输入建帧槽（真 LockFreeFrameSlot + L1 记录层）并注册到引擎。
    public func makeSlot(forInput number: Int) -> LatencyFrameSlot {
        let s = LatencyFrameSlot(inner: LockFreeFrameSlot(capacity: 3), timing: timing)
        slots.append((number, s))
        engine.registerInput(number: number, slot: s)
        return s
    }

    /// 登记一路输入对象（start / stop 由 harness 统一做）。
    public func add(_ input: any Input) { inputs.append(input) }

    /// 起输入 → 挂 L1 消费者 → 起引擎（t0 = timing.clock.t0）。
    public func start(lastTick: Tick? = nil) async throws {
        let c = LatencyConsumer(slots: slots)
        consumer = c
        engine.addConsumer(c)
        for i in inputs { try i.start() }
        try await engine.start(t0: timing.clock.t0, firstTick: .zero, lastTick: lastTick)
    }

    /// 先停输入再停引擎（跑满时的顺序，W1-B 报告 §4 第 13 条）。
    public func stop() async {
        for i in inputs { i.stop() }
        await engine.stop()
    }

    /// 某路的 L1。
    public func latency(ofInput number: Int) -> LatencyStats? { consumer?.stats(forInput: number) }
}
