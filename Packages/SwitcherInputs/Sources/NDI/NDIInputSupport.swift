import CoreVideo
import IOSurface
import Synchronization
import SwitcherContracts
import SwitcherInputs

/// `Input.state` 的存放处 + 转换计数（与 W2-A 的 InputStateBox 同构；那份是包内 internal，这里自己带一份）。
final class NDIStateBox: @unchecked Sendable {
    private let box = Mutex<InputState>(.noSignal)
    let transitions = Atomic<UInt64>(0)
    let liveCount = Atomic<UInt64>(0)
    let noSignalCount = Atomic<UInt64>(0)
    let errorCount = Atomic<UInt64>(0)

    var value: InputState { box.withLock { $0 } }

    /// 置状态；相同不算转换。返回是否变了。
    @discardableResult
    func set(_ new: InputState) -> Bool {
        let changed = box.withLock { old -> Bool in
            if old == new { return false }
            old = new
            return true
        }
        if changed {
            transitions.add(1, ordering: .relaxed)
            switch new {
            case .live: liveCount.add(1, ordering: .relaxed)
            case .noSignal: noSignalCount.add(1, ordering: .relaxed)
            case .error: errorCount.add(1, ordering: .relaxed)
            }
        }
        return changed
    }
}

/// IOSurface 背后、Metal 可用的像素缓冲池；尺寸 / 格式变了就重建。只在接收线程用。
/// 池子有上限（`maxBuffers`）：下游若一直持有帧（测试把 Frame 存数组），到上限就拒绝而不是无限长。
final class NDIPixelBufferPool {
    private var pool: CVPixelBufferPool?
    private var width = 0, height = 0
    private var format: OSType = 0
    let maxBuffers: Int
    /// 到上限被拒的次数。
    private(set) var exhausted: UInt64 = 0
    /// 池重建次数（首建也算）。
    private(set) var rebuilds: UInt64 = 0

    init(maxBuffers: Int) { self.maxBuffers = max(2, maxBuffers) }

    func makeBuffer(width w: Int, height h: Int, format f: OSType) -> CVPixelBuffer? {
        if pool == nil || w != width || h != height || f != format {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferPixelFormatTypeKey: f,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
            var p: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &p) == kCVReturnSuccess, let p else { return nil }
            pool = p
            width = w
            height = h
            format = f
            rebuilds += 1
        }
        guard let pool else { return nil }
        let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: maxBuffers]
        var pb: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux as CFDictionary, &pb)
        guard r == kCVReturnSuccess, let pb else {
            if r == kCVReturnWouldExceedAllocationThreshold { exhausted += 1 }
            return nil
        }
        return pb
    }
}

/// NDI 输入自己的计数（InputCounters 之外；值快照）。不是 Stats——Stats 只读帧槽 / 环（铁律 4）。
public struct NDIInputCounters: Hashable, Sendable {
    /// capture 给出的视频帧。
    public var framesReceived: UInt64 = 0
    /// 推进帧槽的帧。
    public var framesPushed: UInt64 = 0
    /// 格式不支持（既不是 UYVY 也不是 BGRA）的帧。
    public var framesUnsupported: UInt64 = 0
    /// 像素池到上限被拒的帧。
    public var framesPoolExhausted: UInt64 = 0
    /// SDK 侧因为取得不够快而丢的视频帧（NDIlib_recv_get_performance）。
    public var sdkVideoDropped: Int64 = 0
    /// SDK 队列里当前积压的视频帧。
    public var sdkQueueVideo: Int = 0
    /// capture 给出的音频块。
    public var audioFramesReceived: UInt64 = 0
    /// 写进环的音频块 / 帧 / 被环拒的帧。
    public var audioBlocksWritten: UInt64 = 0
    public var audioFramesWritten: UInt64 = 0
    public var audioFramesRejected: UInt64 = 0
    /// 经过重采样的音频块（源不是 48 kHz）。
    public var audioBlocksResampled: UInt64 = 0
    /// SDK 报的源切换 / 状态变化事件。
    public var sourceChanges: UInt64 = 0
    public var statusChanges: UInt64 = 0
    /// 我们主动 recv_connect 的次数（第一次连接不算，源换地址后重连才算）。
    public var reconnects: UInt64 = 0
    /// 当前连接数（0 = 没连上源）。
    public var connections: Int = 0
    /// 抖动统计（NDIClockMap，ms）。
    public var jitterMeanMs: Double = 0
    public var jitterMaxMs: Double = 0
    public var clockResets: UInt64 = 0
    /// d = ingress − pts（引擎到达余量看到的量，ms）：平均 / 最大 / 最小。抖动缓冲 J > 0 时通常是负的。
    public var arrivalMinusPtsMeanMs: Double = 0
    public var arrivalMinusPtsMaxMs: Double = 0
    public var arrivalMinusPtsMinMs: Double = 0
    /// 最近一帧的格式，例如 "1920x1080 UYVY 60000/1001 p"。
    public var lastFormat: String = ""
    /// 最近一次连上的源地址。
    public var connectedURL: String = ""
    /// 状态转换次数。
    public var liveTransitions: UInt64 = 0
    public var noSignalTransitions: UInt64 = 0
    public init() {}
}

/// NDIInputCounters 的原子存放处（接收线程写、任何线程读）。
final class NDICountersBox: @unchecked Sendable {
    let framesReceived = Atomic<UInt64>(0)
    let framesPushed = Atomic<UInt64>(0)
    let framesUnsupported = Atomic<UInt64>(0)
    let framesPoolExhausted = Atomic<UInt64>(0)
    let sdkVideoDropped = Atomic<Int64>(0)
    let sdkQueueVideo = Atomic<Int>(0)
    let audioFramesReceived = Atomic<UInt64>(0)
    let audioBlocksWritten = Atomic<UInt64>(0)
    let audioFramesWritten = Atomic<UInt64>(0)
    let audioFramesRejected = Atomic<UInt64>(0)
    let audioBlocksResampled = Atomic<UInt64>(0)
    let sourceChanges = Atomic<UInt64>(0)
    let statusChanges = Atomic<UInt64>(0)
    let reconnects = Atomic<UInt64>(0)
    let connections = Atomic<Int>(0)
    let dCount = Atomic<UInt64>(0)
    let dSum = Atomic<Int64>(0)
    let dMax = Atomic<Int64>(Int64.min)
    let dMin = Atomic<Int64>(Int64.max)
    let jitter = Mutex<(mean: Double, max: Double, resets: UInt64)>((0, 0, 0))
    let lastFormat = Mutex<String>("")
    let connectedURL = Mutex<String>("")

    func noteArrivalMinusPts(_ d: HostDuration) {
        let ns = d.nanoseconds
        dCount.add(1, ordering: .relaxed)
        dSum.add(ns, ordering: .relaxed)
        _ = dMax.max(ns, ordering: .relaxed)
        _ = dMin.min(ns, ordering: .relaxed)
    }

    func snapshot(state: NDIStateBox) -> NDIInputCounters {
        var c = NDIInputCounters()
        c.framesReceived = framesReceived.load(ordering: .relaxed)
        c.framesPushed = framesPushed.load(ordering: .relaxed)
        c.framesUnsupported = framesUnsupported.load(ordering: .relaxed)
        c.framesPoolExhausted = framesPoolExhausted.load(ordering: .relaxed)
        c.sdkVideoDropped = sdkVideoDropped.load(ordering: .relaxed)
        c.sdkQueueVideo = sdkQueueVideo.load(ordering: .relaxed)
        c.audioFramesReceived = audioFramesReceived.load(ordering: .relaxed)
        c.audioBlocksWritten = audioBlocksWritten.load(ordering: .relaxed)
        c.audioFramesWritten = audioFramesWritten.load(ordering: .relaxed)
        c.audioFramesRejected = audioFramesRejected.load(ordering: .relaxed)
        c.audioBlocksResampled = audioBlocksResampled.load(ordering: .relaxed)
        c.sourceChanges = sourceChanges.load(ordering: .relaxed)
        c.statusChanges = statusChanges.load(ordering: .relaxed)
        c.reconnects = reconnects.load(ordering: .relaxed)
        c.connections = connections.load(ordering: .relaxed)
        let j = jitter.withLock { $0 }
        c.jitterMeanMs = j.mean
        c.jitterMaxMs = j.max
        c.clockResets = j.resets
        let n = dCount.load(ordering: .relaxed)
        if n > 0 {
            c.arrivalMinusPtsMeanMs = Double(dSum.load(ordering: .relaxed)) / Double(n) / 1e6
            c.arrivalMinusPtsMaxMs = Double(dMax.load(ordering: .relaxed)) / 1e6
            c.arrivalMinusPtsMinMs = Double(dMin.load(ordering: .relaxed)) / 1e6
        }
        c.lastFormat = lastFormat.withLock { $0 }
        c.connectedURL = connectedURL.withLock { $0 }
        c.liveTransitions = state.liveCount.load(ordering: .relaxed)
        c.noSignalTransitions = state.noSignalCount.load(ordering: .relaxed)
        return c
    }

    /// 契约层面的 InputCounters（与其他输入同口径）。
    func inputCounters(state: NDIStateBox, surfaces: UInt64) -> InputCounters {
        var c = InputCounters()
        c.framesReceived = framesReceived.load(ordering: .relaxed)
        c.framesPushed = framesPushed.load(ordering: .relaxed)
        c.framesRejected = framesUnsupported.load(ordering: .relaxed) + framesPoolExhausted.load(ordering: .relaxed)
        c.audioBlocksWritten = audioBlocksWritten.load(ordering: .relaxed)
        c.audioFramesWritten = audioFramesWritten.load(ordering: .relaxed)
        c.audioFramesRejected = audioFramesRejected.load(ordering: .relaxed)
        c.stateTransitions = state.transitions.load(ordering: .relaxed)
        c.liveTransitions = state.liveCount.load(ordering: .relaxed)
        c.noSignalTransitions = state.noSignalCount.load(ordering: .relaxed)
        c.errorTransitions = state.errorCount.load(ordering: .relaxed)
        c.rebuilds = reconnects.load(ordering: .relaxed)
        c.distinctSurfaces = surfaces
        return c
    }
}

/// 记一路见过的不同 IOSurface 数（池子是否稳定复用）。只在接收线程调 note。
final class NDISurfaceTracker: @unchecked Sendable {
    private var ids: [UInt32] = []
    private let total = Atomic<UInt64>(0)
    func note(_ pb: CVPixelBuffer) {
        guard let s = CVPixelBufferGetIOSurface(pb) else { return }
        let id = IOSurfaceGetID(s.takeUnretainedValue())
        if ids.contains(id) { return }
        if ids.count < 64 { ids.append(id) }
        total.add(1, ordering: .relaxed)
    }
    var count: UInt64 { total.load(ordering: .relaxed) }
}
