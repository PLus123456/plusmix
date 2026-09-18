import Synchronization
import SwitcherContracts

// 到达余量（V4 退回单 reports/issues/G2-w1-core-phase-crossing-dup-drop.md 的修法；W1-B2 按
// reports/issues/W2A-w1-core-arrival-pacing-vs-camera-latency.md 末尾的 G3 裁定改了初值、上限、保护带、饿死保护、估计器窗口）。
//
// 问题：挑帧规则"pts ≤ 拍点的最新帧"用 pts（确定量）判合格、用"已经 push 进槽"判可用（随机量：到达 = pts + d，d = 延迟 + 抖动）。
// 帧的到达相位穿过拍点边界时两者赛跑：晚到一点 → 这拍重复上一帧，下一拍它和更新的帧一起在槽里 → 取最新、它被跳过。
// 每次穿越出一串 dup + drop 对，10 分钟四路合计 192 帧设计外。
//
// 修法：合格判据改成 pts ≤ 拍点 − L。L ≥ 该路的到达延迟 + 抖动，则合格的帧一定已在槽里，不再与到达赛跑。
// 代价：每帧多等 L − d_k（再加拍点量化）。L 由帧槽按每帧 d = ingressTime − pts（两者都是输入在入口打的戳）自估：
//
//   窗口：最近 blockCount = 8 块，每块 blockDuration（默认 2 s，按 ingressTime 定长，与输入帧率无关：8 × 60 帧的老窗口在 30 fps
//         源上是 16 s、60 fps 上是 8 s，同一个尖峰影响的时长不一样）。每块记最小值和最大的 4 个样本。
//   d_min = 窗口最小值。
//   d_max = 窗口"可覆盖"最大值：每块在它最大的 4 个样本里取第一个 ≤ d_min + 一个节目帧 的；4 个都超过就取第 4 个（保守：
//           一块 2 s 里超过 3 个"尖峰"就不是尖峰，是水平变了）。超过 d_min + 一帧 的样本即使被余量盖住也要付 > 一帧的代价
//           （见上限），所以只走迟到路径，不让一个孤立尖峰（含相机总是最慢的第一帧）把余量钉在上限整整一个窗口。
//   保护带 guard = guardAbsolute + guardRelative × (d_max − d_min)：比例部分按抖动跨度，不按 d_max 绝对值
//           （摄像头 d ≈ 55–75 ms 是固定管线延迟，按绝对值算白付 8–11 ms）。
//   上限 cap = min(maximumMargin, max(0, d_min) + 一个节目帧 + guard)：硬件帧同步器的"最多缓一帧"——最早到的帧也只多等
//           一个节目帧 + 保护带。d 比 cap 还大的帧走迟到路径（那一拍 dup、余量不再抬）。
//   初值：第一帧 d_0 → d_0 > 0 ? max(initialFloor, d_0 + guardAbsolute) : initialFloor，再钳到 cap（此时窗口只有 d_0）。
//           不再乘 2：相机第一帧总是最慢的（75–115 ms），乘 2 再被单样本上限钳住会让稳态帧等 3–4 个帧长、候选表装不下 →
//           黑屏到热身结束（W2-A 实测 4.2 s）。
//   稳态目标 desired = max(minimumMargin, d_max + guard)，≤ cap。
//   热身：前 warmupBlocks 块（默认 1 块 = 2 s）不主动往下减到 desired（一块样本估不出抖动），但上限随时生效：余量高于 cap
//           就减到 cap（起流第一帧慢的那个初值就是这么被压下来的）。
//
// 余量的任何一次变化都是一次相位跳变——增 δ 可能多一次 dup、减 δ 可能多一次 drop（概率 ≈ δ / 输入帧长，渐变也一样）。
// 所以只在"带内没有候选帧"的拍改（消费者线程看候选表就能精确判断，这时改是零代价）：
//   - 减：候选表里第一个不合格的帧不能被新余量带进合格区（否则这拍会同时合格两帧 → drop）；
//   - 增：当前合格的最新帧在新余量下仍须合格（否则这拍没帧可返 → dup）。
// 迟到帧（本该上一拍就返回、现在才到：候选表最旧的帧 pts ≤ 上一拍的合格上限）：那次 dup 已经躲不掉，把余量抬到它的 d + guard、
//   但不超过"让它此刻恰好合格"的值（否则又要多等一拍）、单次不超过 maxRaise（坏时间戳不许把余量顶飞）、不超过 cap；
//   封顶时晚到 ≥ 2 拍的帧会被跳过（它后面的帧也已合格，挑帧取最新）。
// 饿死保护（热身期也生效）：候选表满、最旧候选仍不合格、这一拍没有合格帧 → 立即把余量降到让最旧候选此刻恰好合格
//   （那帧本来要被下一帧挤掉，降余量只是把一次 drop 换成一次正常返回，零代价）。起流时槽里有帧却从未返回过帧也这么做：
//   槽里有帧时 latest(forTick:) 不返回 nil。
//
// 契约不变：FrameSlot.latest(atOrBefore:) 仍是字面语义（无余量），引擎走 ArrivalPacedFrameSlot.latest(forTick:)。
// 参数全在 PacingOptions，引擎注册输入时按节目帧率填 initialFloor / maxRaise / programFrame（组装方可按输入另给一份）。

/// 到达余量的参数。时长类字段是 host 时长；引擎注册时把 nil 的 initialFloor / maxRaise / programFrame 按节目帧率填上。
public struct PacingOptions: Sendable, Hashable {
    /// 关掉则 latest(forTick:) 退化为 latest(atOrBefore:)。
    public var enabled: Bool = true
    /// 保护带的固定部分。
    public var guardAbsolute = HostDuration(milliseconds: 1)
    /// 保护带的比例部分（× 窗口抖动跨度 d_max − d_min）。
    public var guardRelative: Double = 0.15
    /// 滞回：目标比余量高出这么多才主动抬、低这么多才往下减（迟到 / 饿死触发的变化不受限）。
    public var hysteresis = HostDuration(milliseconds: 1)
    /// 到达延迟窗口：每块的时长（块数固定 8；按帧的 ingressTime 定长）。
    public var blockDuration = HostDuration(seconds: 2)
    /// 热身块数：窗口里完成的块不足这么多之前不主动往下减到稳态目标（上限、饿死保护仍生效）。
    public var warmupBlocks: Int = 1
    /// 初值下限（第一帧 d ≤ 0 时的初值）；nil = 节目 1/4 帧（引擎填）。
    public var initialFloor: HostDuration? = nil
    /// 迟到时单次抬高的上限；nil = 一个节目帧（引擎填）。
    public var maxRaise: HostDuration? = nil
    /// 一个节目帧的时长（上限 = d_min + 它 + 保护带）；nil = 引擎按节目帧率填。
    public var programFrame: HostDuration? = nil
    /// 余量下限（帧不会早于 pts + minimumMargin 被用）。
    public var minimumMargin = HostDuration.zero
    /// 余量的绝对上限（另有动态上限 = d_min + 一个节目帧 + 保护带）。
    public var maximumMargin = HostDuration(milliseconds: 500)
    public init() {}

    /// 60 fps 的兜底值（没经引擎注册、直接用槽时）。
    static let fallbackFloor = HostDuration(milliseconds: 1000.0 / 60 / 4)
    static let fallbackMaxRaise = HostDuration(milliseconds: 1000.0 / 60)
    static let fallbackProgramFrame = HostDuration(milliseconds: 1000.0 / 60)
}

/// 到达余量的运行状态（消费者线程写，任何线程读的非事务快照）。
public struct PacingStats: Sendable, Hashable {
    /// 余量是否开着（关着时 latest(forTick:) 就是 latest(atOrBefore:)）。
    public var enabled: Bool
    /// 已经拿到第一帧的 d，余量有效。
    public var initialized: Bool
    /// 当前余量 L。
    public var margin: HostDuration
    /// 窗口内可覆盖的最大到达延迟（余量按它定；超过 d_min + 一帧 的孤立尖峰不算）。
    public var windowMaxLatency: HostDuration
    /// 窗口内原始最大到达延迟（含尖峰，诊断用）。
    public var windowPeakLatency: HostDuration
    /// 窗口内最小到达延迟。
    public var windowMinLatency: HostDuration
    /// 余量的动态上限（d_min + 一个节目帧 + 保护带，再 ≤ maximumMargin）。
    public var marginCap: HostDuration
    /// 窗口里已观察的帧数（累计）。
    public var observedFrames: UInt64
    /// 迟到帧数（每次 = 一次躲不掉的 dup）。
    public var lateFrames: UInt64
    /// 余量抬高次数（含迟到触发的和主动的）。
    public var raises: UInt64
    /// 余量降低次数（含饿死保护）。
    public var decreases: UInt64
    /// 饿死保护 / 起流出画触发的次数（把余量降到让最旧候选恰好合格）。
    public var starvationRescues: UInt64
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
    let blockDuration = Atomic<Int64>(1)
    let warmupBlocks = Atomic<Int>(1)
    let initialFloor = Atomic<Int64>(0)
    let maxRaise = Atomic<Int64>(0)
    let programFrame = Atomic<Int64>(0)
    let minimumMargin = Atomic<Int64>(0)
    let maximumMargin = Atomic<Int64>(Int64.max)

    init(_ o: PacingOptions) { store(o) }

    func store(_ o: PacingOptions) {
        enabled.store(o.enabled, ordering: .relaxed)
        guardAbsolute.store(o.guardAbsolute.ticks, ordering: .relaxed)
        guardRelativePermille.store(Int64((o.guardRelative * 1000).rounded()), ordering: .relaxed)
        hysteresis.store(o.hysteresis.ticks, ordering: .relaxed)
        blockDuration.store(max(o.blockDuration.ticks, 1), ordering: .relaxed)
        warmupBlocks.store(max(o.warmupBlocks, 0), ordering: .relaxed)
        initialFloor.store((o.initialFloor ?? PacingOptions.fallbackFloor).ticks, ordering: .relaxed)
        maxRaise.store((o.maxRaise ?? PacingOptions.fallbackMaxRaise).ticks, ordering: .relaxed)
        programFrame.store((o.programFrame ?? PacingOptions.fallbackProgramFrame).ticks, ordering: .relaxed)
        minimumMargin.store(o.minimumMargin.ticks, ordering: .relaxed)
        maximumMargin.store(o.maximumMargin.ticks, ordering: .releasing)
    }
}
