import Foundation
import Synchronization
import SwitcherContracts

// W2-E 引擎侧：把状态机的变化翻译成 `AudioControlEvent`（拍 → host time）。
//
// 两条路：
//   1. 转场事件（cut / started / completed / cancelled）与 FTB 斜坡变化走状态机自带的 `TransitionEventSink`：状态一变就在状态机线程上
//      同步到达、带确切的拍，音频侧能在起始拍的拍点之前拿到交叉淡变命令（状态机比渲染线程领先一拍准备快照）。FTB 原来走轮询、只比 on，
//      途中改时长漏掉（D11）；轮询也拿不到"改的那一拍"（快照的拍可能已经往后走了），音频分段换斜坡要的正是它。
//   2. 其余（每路音频参数、总线、监听方式、AFV 开关、T-bar 进度、输入表增删）由音频控制线程定期 `pollSnapshot()`：
//      读 `publisher.latest`，与上次看到的状态做 diff。快照发布是原子指针交换，读方不进 actor、不阻塞状态机线程。
//      两次轮询之间的中间态可能被合并（A→B→A 看不到），对这些"目标值"类的量无所谓：音频侧永远向最新状态收敛。
// 事件里的 host time 一律用 `TickClockSpec.time(of:)`（128 位整数，与引擎时钟同一算式）。

/// 状态机 → 音频控制事件的桥。一个状态机配一个桥；`attach()` 之后转场事件开始流动，`pollSnapshot()` 由调用方按需驱动。
public final class AudioStateBridge: TransitionEventSink, @unchecked Sendable {
    public let stateMachine: StateMachine
    public let clock: TickClockSpec
    private let sink: any AudioControlEventSink
    /// 上一次 pollSnapshot 看到的快照序号 / 拍 / 状态。
    private let seen = Mutex<(sequence: UInt64, tick: Tick, state: MixerState, hasSeen: Bool)?>(nil)
    private let attached = Atomic<Bool>(false)

    /// - Parameters:
    ///   - stateMachine: 要观察的状态机。
    ///   - clock: 节目时钟（拍 → host time）。引擎 start 时的 `TickClockSpec`，组装方传进来。
    ///   - sink: 事件接收方（音频侧）。
    public init(stateMachine: StateMachine, clock: TickClockSpec, sink: any AudioControlEventSink) {
        self.stateMachine = stateMachine
        self.clock = clock
        self.sink = sink
    }

    /// 注册为状态机的转场事件接收方。
    public func attach() async {
        guard !attached.exchange(true, ordering: .acquiringAndReleasing) else { return }
        await stateMachine.addTransitionSink(self)
    }

    /// 注销。
    public func detach() async {
        guard attached.exchange(false, ordering: .acquiringAndReleasing) else { return }
        await stateMachine.removeTransitionSink(self)
    }

    public var isAttached: Bool { attached.load(ordering: .acquiring) }

    // MARK: TransitionEventSink（状态机线程）

    public func stateMachine(_ machine: StateMachine, didEmit event: TransitionEvent, afv: Bool) {
        guard attached.load(ordering: .acquiring) else { return }
        sink.audioControl(Self.convert(event, clock: clock))
    }

    /// 转场事件 → 音频事件。
    public static func convert(_ event: TransitionEvent, clock: TickClockSpec) -> AudioControlEvent {
        switch event {
        case .cut(let tick, let from, let to):
            return .cut(from: from, to: to, tick: tick, at: clock.time(of: tick))
        case .started(let tick, let type, let d, let from, let to, let source):
            return .transitionStarted(from: from, to: to, type: type, source: source, tick: tick, at: clock.time(of: tick),
                                      durationTicks: d, duration: clock.duration(ofTicks: max(d, 0)))
        case .completed(let tick, let from, let to, let completion):
            // 对调已发生：新 PGM = to，新 PVW = from；怎么完成的照带（D10：被打断的要音频侧短淡收口）
            return .transitionEnded(program: to, preview: from, tick: tick, at: clock.time(of: tick), completion: completion)
        case .cancelled(let tick):
            // 被取消：新的 PGM / PVW 由随后的快照 diff 给出；这里只报告"结束了"，program / preview 用 0 占位由音频侧按最新快照重新门控
            return .transitionEnded(program: MixerState.noInput, preview: MixerState.noInput, tick: tick, at: clock.time(of: tick), completion: nil)
        case .fadeToBlack(let tick, let on, let start, let d):
            // D11：新斜坡从改的那一拍起生效（之前那段内容音频仍按旧斜坡走）
            return .fadeToBlack(on: on, startTick: start, at: clock.time(of: start), durationTicks: d, duration: clock.duration(ofTicks: d),
                                effectiveTick: tick, effectiveAt: clock.time(of: tick))
        }
    }

    // MARK: 快照轮询（音频控制线程）

    /// 读最新快照，与上次比较，把差异交给 sink。第一次调用发全量（inputsChanged 全部输入、buses、monitorMode、afv）。
    /// 返回是否看到了新快照。
    @discardableResult
    public func pollSnapshot() -> Bool {
        guard let snapshot = stateMachine.publisher.latest else { return false }
        let previous: (sequence: UInt64, tick: Tick, state: MixerState, hasSeen: Bool)? = seen.withLock { $0 }
        if let previous, previous.hasSeen, previous.sequence == snapshot.sequence, previous.tick == snapshot.tick,
           previous.state == snapshot.state {
            return false
        }
        let events = Self.diff(from: previous?.hasSeen == true ? previous?.state : nil, to: snapshot.state, tick: snapshot.tick, clock: clock)
        seen.withLock { $0 = (snapshot.sequence, snapshot.tick, snapshot.state, true) }
        for e in events { sink.audioControl(e) }
        return true
    }

    /// 上次轮询看到的状态（音频侧重新门控时用）。
    public var lastSeenState: MixerState? { seen.withLock { $0?.hasSeen == true ? $0?.state : nil } }

    /// 纯函数：从 `from` 到 `to` 的音频相关差异（不含转场开始 / 结束与 FTB 斜坡变化，那些走 TransitionEventSink）。`from` 为 nil = 全量。
    /// 顺序：输入表 → 每路参数 → 总线 → 监听 → AFV → FTB（只在全量时）→ T-bar 进度。
    public static func diff(from: MixerState?, to: MixerState, tick: Tick, clock: TickClockSpec) -> [AudioControlEvent] {
        var out: [AudioControlEvent] = []
        // 输入表
        let oldInputs = from?.inputs ?? []
        var oldByNumber: [Int: InputConfig] = [:]
        for i in oldInputs { oldByNumber[i.number] = i }
        var newNumbers = Set<Int>()
        var added: [InputConfig] = []
        var settingsChanged: [AudioControlEvent] = []
        for i in to.inputs {
            newNumbers.insert(i.number)
            if let old = oldByNumber[i.number] {
                if old.settings.audio != i.settings.audio {
                    settingsChanged.append(.inputAudioSettings(input: i.number, settings: i.settings.audio))
                }
            } else {
                added.append(i)
            }
        }
        let removed = oldInputs.map(\.number).filter { !newNumbers.contains($0) }
        if !added.isEmpty || !removed.isEmpty { out.append(.inputsChanged(added: added, removed: removed)) }
        out.append(contentsOf: settingsChanged)
        // 总线 / 监听 / AFV
        if from == nil || from!.audio.buses != to.audio.buses { out.append(.buses(to.audio.buses)) }
        if from == nil || from!.audio.monitorMode != to.audio.monitorMode { out.append(.monitorMode(to.audio.monitorMode)) }
        if from == nil || from!.audio.afv != to.audio.afv { out.append(.afv(on: to.audio.afv)) }
        // FTB：只在全量时报告当前斜坡（进行中）或已到位的斜坡（on 或还在走）；之后的变化走 TransitionEventSink（D11，带改的那一拍）
        if from == nil && (to.ftb.on || to.ftb.startTick != nil) {
            let startTick = to.ftb.startTick ?? tick
            let d = to.ftb.startTick == nil ? 0 : max(to.ftb.durationTicks, 0)
            out.append(.fadeToBlack(on: to.ftb.on, startTick: startTick, at: clock.time(of: startTick), durationTicks: d,
                                    duration: clock.duration(ofTicks: d), effectiveTick: tick, effectiveAt: clock.time(of: tick)))
        }
        // T-bar 进度
        if to.transition.source == .tbar && to.transition.isActive {
            let changed = from.map { $0.transition.source != .tbar || !$0.transition.isActive || $0.transition.progress != to.transition.progress } ?? true
            if changed { out.append(.tbarProgress(from: to.program, to: to.preview, progress: to.transition.progress)) }
        }
        return out
    }
}
