import Synchronization
import SwitcherContracts

/// `Input.state` 的存放处：输入线程写、任何线程读（Mutex，读写都是纳秒级；输入的读写方都不是实时线程）。
/// 顺便记转换次数和最近一次错误文案，探针 / 测试看它判断热插拔与权限恢复。
final class InputStateBox: @unchecked Sendable {
    private let box = Mutex<InputState>(.noSignal)
    private let transitionsCount = Atomic<UInt64>(0)
    private let liveCount = Atomic<UInt64>(0)
    private let noSignalCount = Atomic<UInt64>(0)
    private let errorCount = Atomic<UInt64>(0)

    var value: InputState { box.withLock { $0 } }

    /// 置状态；相同则不算转换。返回是否真的变了。
    @discardableResult
    func set(_ new: InputState) -> Bool {
        let changed = box.withLock { old -> Bool in
            if old == new { return false }
            old = new
            return true
        }
        if changed {
            transitionsCount.add(1, ordering: .relaxed)
            switch new {
            case .live: liveCount.add(1, ordering: .relaxed)
            case .noSignal: noSignalCount.add(1, ordering: .relaxed)
            case .error: errorCount.add(1, ordering: .relaxed)
            }
        }
        return changed
    }

    /// 状态转换总次数。
    var transitions: UInt64 { transitionsCount.load(ordering: .relaxed) }
    /// 进入 live 的次数。
    var liveTransitions: UInt64 { liveCount.load(ordering: .relaxed) }
    /// 进入 noSignal 的次数。
    var noSignalTransitions: UInt64 { noSignalCount.load(ordering: .relaxed) }
    /// 进入 error 的次数。
    var errorTransitions: UInt64 { errorCount.load(ordering: .relaxed) }
}

/// 每路输入的诊断计数（原子读）。这是输入自己的诊断量，不是 Stats（Stats 只读帧槽 / 环的统计，铁律 4）。
public struct InputCounters: Hashable, Sendable {
    /// 采集回调 / 解码器给出的视频帧数。
    public var framesReceived: UInt64 = 0
    /// 真正 push 进帧槽的帧数。
    public var framesPushed: UInt64 = 0
    /// 收到但没推的帧（不是 IOSurface、格式不认识、暂停 / 到结尾后的重复推送不计）。
    public var framesRejected: UInt64 = 0
    /// 写进环的音频块数。
    public var audioBlocksWritten: UInt64 = 0
    /// 写进环的音频帧数。
    public var audioFramesWritten: UInt64 = 0
    /// 环满被拒的音频帧数。
    public var audioFramesRejected: UInt64 = 0
    /// 状态转换总次数。
    public var stateTransitions: UInt64 = 0
    /// 进入 live 的次数。
    public var liveTransitions: UInt64 = 0
    /// 进入 noSignal 的次数。
    public var noSignalTransitions: UInt64 = 0
    /// 进入 error 的次数。
    public var errorTransitions: UInt64 = 0
    /// 会话 / 流重建次数（热插拔恢复、权限恢复）。
    public var rebuilds: UInt64 = 0
    /// 这路输入见过的不同 IOSurface 数（池子稳定时应是个小常数；渲染器的纹理表每路 16 项）。
    public var distinctSurfaces: UInt64 = 0
    public init() {}
}

/// InputCounters 的原子存放处。
final class InputCountersBox: @unchecked Sendable {
    let framesReceived = Atomic<UInt64>(0)
    let framesPushed = Atomic<UInt64>(0)
    let framesRejected = Atomic<UInt64>(0)
    let audioBlocksWritten = Atomic<UInt64>(0)
    let audioFramesWritten = Atomic<UInt64>(0)
    let audioFramesRejected = Atomic<UInt64>(0)
    let rebuilds = Atomic<UInt64>(0)
    let surfaces = SurfaceTracker()

    func snapshot(state: InputStateBox) -> InputCounters {
        var c = InputCounters()
        c.framesReceived = framesReceived.load(ordering: .relaxed)
        c.framesPushed = framesPushed.load(ordering: .relaxed)
        c.framesRejected = framesRejected.load(ordering: .relaxed)
        c.audioBlocksWritten = audioBlocksWritten.load(ordering: .relaxed)
        c.audioFramesWritten = audioFramesWritten.load(ordering: .relaxed)
        c.audioFramesRejected = audioFramesRejected.load(ordering: .relaxed)
        c.stateTransitions = state.transitions
        c.liveTransitions = state.liveTransitions
        c.noSignalTransitions = state.noSignalTransitions
        c.errorTransitions = state.errorTransitions
        c.rebuilds = rebuilds.load(ordering: .relaxed)
        c.distinctSurfaces = surfaces.count
        return c
    }
}
