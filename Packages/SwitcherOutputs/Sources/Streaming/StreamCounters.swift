import Synchronization
import SwitcherContracts
import SwitcherOutputs

/// 一路推流的累计计数（值快照）。全部自启动累计、单调不减；窗口量由读方相减（Stats 口径）。
///
/// 网络丢帧（E9 口径，测试标准 §1 E9 / §8）：**编码器交出之后、没有送上网络的视频帧**，分项：
/// - `droppedQueueFull`：发送队列满，丢的是新来的这一帧（丢新不丢旧：队列里的 GOP 保持可解码）；
/// - `droppedWaitingKeyframe`：丢过一帧之后到下一个关键帧之前的非关键帧（避免送出去的 P 帧引用丢掉的帧）；
/// - `droppedDisconnected`：断线 / 重连 / 退避期间到达的帧；
/// - `discardedOnDisconnect`：断线那一刻队列里还没送出的帧；
/// - `lostInTransport`：断线那一刻已交给传输层但按其上报的未发字节估算没发出去的帧（估算值，见报告）。
/// `networkDropped` = 五项之和。`framesSent` 是**交给传输层**的帧数，其中 `lostInTransport` 那部分估计没发出去，所以恒等式是
/// framesReceived == framesSent + (networkDropped − lostInTransport) + queueDepth；真正到达对端的 ≈ framesSent − lostInTransport。
public struct StreamCounters: Hashable, Sendable {
    /// 编码器交出的视频帧数。
    public var framesReceived: UInt64 = 0
    /// 交给传输层的视频帧数（"帧数"）。
    public var framesSent: UInt64 = 0
    /// 交给传输层的关键帧数。
    public var keyframesSent: UInt64 = 0
    /// E9 网络丢帧总数（五个分项之和）。
    public var networkDropped: UInt64 = 0
    public var droppedQueueFull: UInt64 = 0
    public var droppedWaitingKeyframe: UInt64 = 0
    public var droppedDisconnected: UInt64 = 0
    public var discardedOnDisconnect: UInt64 = 0
    public var lostInTransport: UInt64 = 0
    /// 音频：编码器交出的包、送出的包、丢掉的包（队列满 / 断线 / 起步对齐前的）。
    public var audioPacketsReceived: UInt64 = 0
    public var audioPacketsSent: UInt64 = 0
    public var audioDropped: UInt64 = 0
    /// 交给传输层的字节（视频 + 音频有效载荷）；bitrate = Δbytes × 8 / 秒。
    public var bytesSent: UInt64 = 0
    /// 连接尝试次数（含第一次）。
    public var connectAttempts: UInt64 = 0
    /// 重连成功次数（第一次连上不算）。
    public var reconnects: UInt64 = 0
    /// 断线次数（连上之后掉线 / 停滞被判断线）。
    public var disconnects: UInt64 = 0
    /// 最近一次"断线 → 重连成功"的耗时（秒，E8）；没重连过为 0。
    public var lastReconnectSeconds: Double = 0
    /// 历次重连耗时的最大值（秒）。
    public var maxReconnectSeconds: Double = 0
    /// 视频发送队列当前深度（瞬时）。
    public var queueDepth: Int = 0
    /// 音频发送队列当前深度（瞬时）。
    public var audioQueueDepth: Int = 0
    /// 传输层还没发完的字节估计（瞬时）。
    public var inFlightBytes: Int = 0
    /// 当前状态。
    public var state: StreamState = .idle

    public init() {}

    /// 生成 Stats.encoder 的一项：skipped 用本路编码器的 E1 计数，bitrate 由与上一次快照的发送字节差算。
    /// 提案 001 + 002（已批，等契约会话落地）加的字段这样填：frames = framesSent、dropped = networkDropped、reconnects = reconnects、
    /// state = state.name、disk_free_mb = 0。契约一到，这里加四行即可。
    public func statsEntry(previous: StreamCounters?, windowSeconds: Double, encoderSkipped: UInt64) -> Stats.EncoderEntry {
        let delta = bytesSent &- (previous?.bytesSent ?? 0)
        let bitrate = windowSeconds > 0 ? Double(delta) * 8 / windowSeconds : 0
        return Stats.EncoderEntry(skipped: encoderSkipped, bitrate: bitrate)
    }
}

/// 推流状态（重连状态机的节点，见报告里的状态图）。
public enum StreamState: Hashable, Sendable, CustomStringConvertible {
    /// 还没 start。
    case idle
    /// 第 attempt 次连接中（从 1 起；重连时重新从 1 起）。
    case connecting(attempt: Int)
    /// 已连接、在发。
    case publishing
    /// 断线 / 连接失败后等待重试；seconds = 本次等待。
    case backoff(attempt: Int, seconds: Double)
    /// stop 进行中（排空队列、关连接）。
    case stopping
    /// 已停止。
    case stopped
    /// 放弃（超过最大尝试次数）。
    case failed(String)

    /// 不带参数的状态名（提案 002 的 Stats.encoder[i].state 用它）：idle / connecting / publishing / backoff / stopping / stopped / failed。
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .publishing: return "publishing"
        case .backoff: return "backoff"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .connecting(let a): return "connecting(\(a))"
        case .publishing: return "publishing"
        case .backoff(let a, let s): return "backoff(\(a), \(s)s)"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed(let m): return "failed(\(m))"
        }
    }
}

/// 原子计数器（发送 Task / 编码器回调线程写，任意线程读）。`snapshot()` 逐字段 relaxed 读，够统计用。
final class AtomicStreamCounters: @unchecked Sendable {
    let framesReceived = Atomic<UInt64>(0)
    let framesSent = Atomic<UInt64>(0)
    let keyframesSent = Atomic<UInt64>(0)
    let droppedQueueFull = Atomic<UInt64>(0)
    let droppedWaitingKeyframe = Atomic<UInt64>(0)
    let droppedDisconnected = Atomic<UInt64>(0)
    let discardedOnDisconnect = Atomic<UInt64>(0)
    let lostInTransport = Atomic<UInt64>(0)
    let audioPacketsReceived = Atomic<UInt64>(0)
    let audioPacketsSent = Atomic<UInt64>(0)
    let audioDropped = Atomic<UInt64>(0)
    let bytesSent = Atomic<UInt64>(0)
    let connectAttempts = Atomic<UInt64>(0)
    let reconnects = Atomic<UInt64>(0)
    let disconnects = Atomic<UInt64>(0)
    let lastReconnectNanos = Atomic<UInt64>(0)
    let maxReconnectNanos = Atomic<UInt64>(0)
    let queueDepth = Atomic<Int>(0)
    let audioQueueDepth = Atomic<Int>(0)
    let inFlightBytes = Atomic<Int>(0)
    private let stateLock = Mutex<StreamState>(.idle)

    var state: StreamState {
        get { stateLock.withLock { $0 } }
        set { stateLock.withLock { $0 = newValue } }
    }

    func recordReconnect(seconds: Double) {
        let ns = UInt64(max(0, seconds) * 1e9)
        lastReconnectNanos.store(ns, ordering: .relaxed)
        var current = maxReconnectNanos.load(ordering: .relaxed)
        while ns > current {
            let (done, original) = maxReconnectNanos.compareExchange(expected: current, desired: ns, ordering: .relaxed)
            if done { break }
            current = original
        }
    }

    func snapshot() -> StreamCounters {
        var c = StreamCounters()
        c.framesReceived = framesReceived.load(ordering: .relaxed)
        c.framesSent = framesSent.load(ordering: .relaxed)
        c.keyframesSent = keyframesSent.load(ordering: .relaxed)
        c.droppedQueueFull = droppedQueueFull.load(ordering: .relaxed)
        c.droppedWaitingKeyframe = droppedWaitingKeyframe.load(ordering: .relaxed)
        c.droppedDisconnected = droppedDisconnected.load(ordering: .relaxed)
        c.discardedOnDisconnect = discardedOnDisconnect.load(ordering: .relaxed)
        c.lostInTransport = lostInTransport.load(ordering: .relaxed)
        c.networkDropped = c.droppedQueueFull + c.droppedWaitingKeyframe + c.droppedDisconnected + c.discardedOnDisconnect + c.lostInTransport
        c.audioPacketsReceived = audioPacketsReceived.load(ordering: .relaxed)
        c.audioPacketsSent = audioPacketsSent.load(ordering: .relaxed)
        c.audioDropped = audioDropped.load(ordering: .relaxed)
        c.bytesSent = bytesSent.load(ordering: .relaxed)
        c.connectAttempts = connectAttempts.load(ordering: .relaxed)
        c.reconnects = reconnects.load(ordering: .relaxed)
        c.disconnects = disconnects.load(ordering: .relaxed)
        c.lastReconnectSeconds = Double(lastReconnectNanos.load(ordering: .relaxed)) / 1e9
        c.maxReconnectSeconds = Double(maxReconnectNanos.load(ordering: .relaxed)) / 1e9
        c.queueDepth = queueDepth.load(ordering: .relaxed)
        c.audioQueueDepth = audioQueueDepth.load(ordering: .relaxed)
        c.inFlightBytes = inFlightBytes.load(ordering: .relaxed)
        c.state = state
        return c
    }
}
