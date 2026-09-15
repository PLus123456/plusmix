import Synchronization
import SwitcherContracts

// 到达余量（V4 退回单 reports/issues/G2-w1-core-phase-crossing-dup-drop.md 的修法）。
//
// 问题：挑帧规则"pts ≤ 拍点的最新帧"用 pts（确定量）判合格、用"已经 push 进槽"判可用（随机量：到达 = pts + 延迟 + 抖动）。
// 帧的到达相位穿过拍点边界时两者赛跑：晚到一点 → 这拍重复上一帧，下一拍它和更新的帧一起在槽里 → 取最新、它被跳过。
// 每次穿越出一串 dup + drop 对，10 分钟四路合计 192 帧设计外。
//
// 修法：合格判据改成 pts ≤ 拍点 − L，L ≥ 该路的到达延迟 + 抖动，则合格的帧一定已经在槽里，不再与到达赛跑。
// L 由帧槽按每帧 d = ingressTime − pts（两者都是输入在入口打的戳）自估：
//   - 初值：第一帧 d_0 → max(initialFloor, initialFactor × d_0 + guardAbs)（节目 1/4 帧兜底，真设备 d 大则按 d 走；
//     下限不取半帧是因为 G2 合成源的提前量正好半帧，下限 > 提前量会让相位锁定的输入平白多一拍延迟）；
//   - 稳态目标 desired = 最近 blockCount 块（每块 blockFrames 帧）的 d 最大值 + 保护带（guardAbs + guardRelative × 最大值）。
//     用最大值而不是分位数：真设备（USB）常有孤立尖峰，分位数盖不住它们，每个尖峰就是一次 dup；用最大值只多付延迟。
//     一次大卡顿会让余量抬高 8 块（≈ 8 s）后再收回，同样只是延迟；
//   - 热身：前 warmupBlocks 块只许抬不许减（一帧样本估不出抖动）。
// 余量的任何一次变化都是一次相位跳变——增 δ 可能多一次 dup、减 δ 可能多一次 drop（概率 ≈ δ / 输入帧长，渐变也一样）。
// 所以只在"带内没有候选帧"的拍改（消费者线程看候选表就能精确判断，这时改是零代价）：
//   - 减：候选表里第一个不合格的帧不能被新余量带进合格区（否则这拍会同时合格两帧 → drop）；
//   - 增：当前合格的最新帧在新余量下仍须合格（否则这拍没帧可返 → dup）。
// 迟到帧（本该上一拍就返回、现在才到：候选表最旧的帧 pts ≤ 上一拍的合格上限）：那次 dup 已经躲不掉，把余量抬到
// 它的 d + 保护带、但不超过"让它此刻恰好合格"的值（否则又要多等一拍）、单次不超过 maxRaise（坏时间戳不许把余量顶飞；
// 封顶时晚到 ≥ 2 拍的帧才会被跳过）；这样迟到只花那一次 dup、不丢帧。
//
// 契约不变：FrameSlot.latest(atOrBefore:) 仍是字面语义（无余量），引擎走 ArrivalPacedFrameSlot.latest(forTick:)。
// 参数全在 PacingOptions，引擎注册输入时按节目帧率填 initialFloor / maxRaise。

/// 到达余量的参数。时长类字段是 host 时长；引擎注册时把 nil 的 initialFloor / maxRaise 按节目帧率填上。
public struct PacingOptions: Sendable, Hashable {
    /// 关掉则 latest(forTick:) 退化为 latest(atOrBefore:)。
    public var enabled: Bool = true
    /// 保护带的固定部分。
    public var guardAbsolute = HostDuration(milliseconds: 1)
    /// 保护带的比例部分（× 窗口最大到达延迟）。
    public var guardRelative: Double = 0.15
    /// 滞回：目标比余量高出这么多才主动抬、低这么多才往下减（迟到触发的抬高不受限）。
    public var hysteresis = HostDuration(milliseconds: 1)
    /// 到达延迟窗口：每块多少帧（块数固定 8）。
    public var blockFrames: Int = 60
    /// 热身块数：窗口里样本不足这么多块之前不往下减。
    public var warmupBlocks: Int = 2
    /// 初值 = max(initialFloor, initialFactor × 第一帧的 d + guardAbsolute)。
    public var initialFactor: Double = 2
    /// 初值下限；nil = 节目 1/4 帧（引擎填）。
    public var initialFloor: HostDuration? = nil
    /// 迟到时单次抬高的上限；nil = 一个节目帧（引擎填）。
    public var maxRaise: HostDuration? = nil
    /// 余量下限（帧不会早于 pts + minimumMargin 被用）。
    public var minimumMargin = HostDuration.zero
    /// 余量的绝对上限（另有结构上限 = 最早到达 + (capacity − 1) × 帧长，候选表装不下更多等着合格的帧）。
    public var maximumMargin = HostDuration(milliseconds: 500)
    public init() {}

    /// 60 fps 的兜底值（没经引擎注册、直接用槽时）。
    static let fallbackFloor = HostDuration(milliseconds: 1000.0 / 60 / 4)
    static let fallbackMaxRaise = HostDuration(milliseconds: 1000.0 / 60)
}

/// 到达余量的运行状态（消费者线程写，任何线程读的非事务快照）。
public struct PacingStats: Sendable, Hashable {
    /// 已经拿到第一帧的 d，余量有效。
    public var initialized: Bool
    /// 当前余量 L。
    public var margin: HostDuration
    /// 窗口内最大到达延迟（ingressTime − pts）。
    public var windowMaxLatency: HostDuration
    /// 窗口里已观察的帧数。
    public var observedFrames: UInt64
    /// 迟到帧数（每次 = 一次躲不掉的 dup）。
    public var lateFrames: UInt64
    /// 余量抬高次数（含迟到触发的和主动的）。
    public var raises: UInt64
    /// 余量降低次数。
    public var decreases: UInt64
}

/// 带到达余量的帧槽：引擎注册输入时按这个协议识别，识别不了的槽退回 `latest(atOrBefore:)`。
public protocol ArrivalPacedFrameSlot: FrameSlot {
    /// 渲染线程：第 tickTime 拍的挑帧 = latest(atOrBefore: tickTime − 余量)，余量自估、只在零代价的拍变动。
    func latest(forTick tickTime: HostTime) -> Frame?
    /// 非实时线程：设参数（注册时；运行中改也行，下一拍生效）。
    func configurePacing(_ options: PacingOptions)
    /// 余量状态。
    var pacingStats: PacingStats { get }
}

/// PacingOptions 的原子镜像：非实时线程写、渲染线程每拍读，不加锁。
final class PacingOptionsAtomic: @unchecked Sendable {
    let enabled = Atomic<Bool>(true)
    let guardAbsolute = Atomic<Int64>(0)
    let guardRelativePermille = Atomic<Int64>(0)
    let hysteresis = Atomic<Int64>(0)
    let blockFrames = Atomic<Int>(60)
    let warmupBlocks = Atomic<Int>(2)
    let initialFactorPermille = Atomic<Int64>(2000)
    let initialFloor = Atomic<Int64>(0)
    let maxRaise = Atomic<Int64>(0)
    let minimumMargin = Atomic<Int64>(0)
    let maximumMargin = Atomic<Int64>(Int64.max)

    init(_ o: PacingOptions) { store(o) }

    func store(_ o: PacingOptions) {
        enabled.store(o.enabled, ordering: .relaxed)
        guardAbsolute.store(o.guardAbsolute.ticks, ordering: .relaxed)
        guardRelativePermille.store(Int64((o.guardRelative * 1000).rounded()), ordering: .relaxed)
        hysteresis.store(o.hysteresis.ticks, ordering: .relaxed)
        blockFrames.store(max(o.blockFrames, 1), ordering: .relaxed)
        warmupBlocks.store(max(o.warmupBlocks, 0), ordering: .relaxed)
        initialFactorPermille.store(Int64((o.initialFactor * 1000).rounded()), ordering: .relaxed)
        initialFloor.store((o.initialFloor ?? PacingOptions.fallbackFloor).ticks, ordering: .relaxed)
        maxRaise.store((o.maxRaise ?? PacingOptions.fallbackMaxRaise).ticks, ordering: .relaxed)
        minimumMargin.store(o.minimumMargin.ticks, ordering: .relaxed)
        maximumMargin.store(o.maximumMargin.ticks, ordering: .releasing)
    }
}
