import Synchronization
import SwitcherContracts
import SwitcherEngine

/// 一路输入的 ISO 视频 tap：PGM 帧的消费者。每拍在自己的分支槽上按契约的挑帧规则取这一路 pts ≤ 拍点的最新帧，
/// 换上这一拍的 tick / 拍点时刻交给 `sink`（该路的 Recorder），于是 ISO 文件与 PGM 同一拍点网格、PTS 共用。
/// 视频延后（W1-B4，提案 028）：引擎延后派发的帧 tickTime = 拍点 + L、program.pts 仍是拍点——挑帧按画面内容的时刻（program.pts），
/// 打戳用 tickTime（节目输出时间线，ISO 音轨的输入来源同样平移 +L）；L = 0 时两者相等，与以前相同。
/// 30 fps 的输入在 60 fps 节目里同一帧被录两次（与 PGM 里显示它时一样）；这一路还没有任何帧时这一拍没有输出（只计数）。
///
/// 线程：`consume` 在引擎派发线程上被调（一个线程，MetalRenderer 的完成线程），做的事只有一次无锁挑帧 + 一次 `sink.consume`
/// （Recorder 的 consume 只入队），零分配（RenderedFrame 是值类型）。分支槽的唯一消费者就是这条线程。
public final class ISOFrameTap: FrameConsumer, @unchecked Sendable {
    /// 输入编号。
    public let inputNumber: Int
    /// 这一路的分支槽（InputFrameTee.addBranch 给的）。
    public let branch: LockFreeFrameSlot
    /// 下游（Recorder）。
    public let sink: any FrameConsumer
    public let consumerName: String

    /// 计数（值快照）。
    public struct Counters: Hashable, Sendable {
        /// 交给下游的帧数。
        public var forwarded: UInt64 = 0
        /// 这一拍分支上还没有任何帧（输入还没出第一帧），没有输出。
        public var noFrame: UInt64 = 0
        /// 交给下游的是上一拍同一帧（输入帧率低于节目 / 帧晚到）。
        public var repeated: UInt64 = 0
        /// 最近交出去的输入帧序号。
        public var lastSequence: UInt64 = 0
        public init() {}
    }

    private let forwarded = Atomic<UInt64>(0)
    private let noFrame = Atomic<UInt64>(0)
    private let repeated = Atomic<UInt64>(0)
    private let lastSequence = Atomic<UInt64>(0)
    private var hasLast = false   // 只有派发线程碰

    public init(inputNumber: Int, branch: LockFreeFrameSlot, sink: any FrameConsumer, name: String? = nil) {
        self.inputNumber = inputNumber
        self.branch = branch
        self.sink = sink
        consumerName = name ?? "iso\(inputNumber)"
    }

    public var counters: Counters {
        var c = Counters()
        c.forwarded = forwarded.load(ordering: .relaxed)
        c.noFrame = noFrame.load(ordering: .relaxed)
        c.repeated = repeated.load(ordering: .relaxed)
        c.lastSequence = lastSequence.load(ordering: .relaxed)
        return c
    }

    public func consume(_ frame: RenderedFrame) {
        guard let picked = branch.latest(atOrBefore: frame.program.pts) else {
            noFrame.add(1, ordering: .relaxed)
            return
        }
        if hasLast, picked.sequence == lastSequence.load(ordering: .relaxed) {
            repeated.add(1, ordering: .relaxed)
        }
        hasLast = true
        lastSequence.store(picked.sequence, ordering: .relaxed)
        forwarded.add(1, ordering: .relaxed)
        let out = RenderedFrame(tick: frame.tick, tickTime: frame.tickTime, program: picked, preview: nil, multiview: nil,
                                submitTime: frame.submitTime, gpuStart: frame.gpuStart, gpuEnd: frame.gpuEnd)
        sink.consume(out)
    }
}
