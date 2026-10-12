import Synchronization
import SwitcherContracts
import SwitcherOutputs

/// 一路推流的累计计数（值快照）。全部自启动累计、单调不减；窗口量由读方相减（Stats 口径）。
///
/// 网络丢帧（E9 口径，测试标准 §1 E9 / §8）：**这路推流开始之后、编码器交出而没有送上网络的视频帧**，分项：
/// - `droppedQueueFull`：发送队列满，丢的是新来的这一帧（丢新不丢旧：队列里的 GOP 保持可解码）；
/// - `droppedWaitingKeyframe`：丢过一帧之后到下一个关键帧之前的非关键帧（避免送出去的 P 帧引用丢掉的帧）；
/// - `droppedDisconnected`：断线 / 退避 / 重连期间到达而没留在缓冲里的帧（缓冲只留从关键帧起的最近一段，满了从下一个关键帧重来）；
/// - `discardedOnDisconnect`：断线那一刻队列里还没送出的帧；
/// - `lostInTransport`：断线那一刻已交给传输层但按其上报的未发字节估算没发出去的帧（估算值，见报告）。
/// `networkDropped` = 五项之和。`framesSent` 是**交给传输层**的帧数，其中 `lostInTransport` 那部分估计没发出去，所以恒等式是
/// framesReceived == framesSent + (networkDropped − lostInTransport) + videoBeforeStart + queueDepth；真正到达对端的 ≈ framesSent − lostInTransport。
///
/// 开始之前（W2-D2）：推流的原点是第一次连上后送出的第一个关键帧，两轨从它同一时刻起送。原点之前编码器就交出的帧 / 包不是丢：
/// 握手期间到的先排在缓冲里、连上后照送；握手比缓冲长时缓冲从下一个关键帧重来，清掉的旧内容记 `videoBeforeStart` / `audioBeforeStart`；
/// 起步对齐裁掉的原点之前的音频包（headless 里音频引擎比视频 t0 早起那 ~1 s 的 47 包就是这种：没有画面可配）记 `audioBeforeStart`。
/// 第一次连上之后再断线，同样的事就是损失（droppedDisconnected / audioDropped）。
/// 音频恒等式：audioPacketsReceived == audioPacketsSent + audioDropped + audioBeforeStart + audioQueueDepth。
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
    /// 音频：编码器交出的包、送出的包、丢掉的包（开始之后：队列满 / 断线丢弃 / 重连起步对齐裁掉的）。
    public var audioPacketsReceived: UInt64 = 0
    public var audioPacketsSent: UInt64 = 0
    public var audioDropped: UInt64 = 0
    /// 开始之前（第一次连上、送出第一个关键帧之前）没成为推流内容的视频帧 / 音频包：不算网络丢帧 / 音频丢包（见上）。
    public var videoBeforeStart: UInt64 = 0
    public var audioBeforeStart: UInt64 = 0
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

    /// 生成 Stats.encoder 的一项：skipped 用本路编码器的 E1 计数，bitrate 由与上一次快照的发送字节差算；
    /// 提案 001 + 002（P2 落地）：frames = framesSent、dropped = networkDropped（E9）、reconnects = reconnects、state = state.name、disk_free_mb = 0。
    /// output = 这路推流在 MixerState.outputs 里的编号（提案 019；组装方给，不给 = 0）；connections 推流写 0。
    /// 提案 022：disconnects = 本结构的 disconnects；attempt = 这一轮第几次尝试（connecting(n) = n，backoff 期间 = 即将进行的那一次 = failures + 1，与 App 底栏的读法一致；在推 / 空闲 / 停止 / failed = 0）。
    public func statsEntry(previous: StreamCounters?, windowSeconds: Double, encoderSkipped: UInt64, output: Int = 0) -> Stats.EncoderEntry {
        let delta = bytesSent &- (previous?.bytesSent ?? 0)
        let bitrate = windowSeconds > 0 ? Double(delta) * 8 / windowSeconds : 0
        let attempt: Int = { switch state { case .connecting(let a): return a; case .backoff(let a, _): return a + 1; default: return 0 } }()
        return Stats.EncoderEntry(output: output, skipped: encoderSkipped, bitrate: bitrate, frames: framesSent, dropped: networkDropped, diskFreeMb: 0,
                                  reconnects: reconnects, state: state.name, disconnects: disconnects, attempt: attempt)
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
    /// 放弃：超过最大尝试次数，或服务器拒绝鉴权（W2-D4，第一次就停）。参数是给人看的原因（= last_error）；类型化的原因见 `StreamOutput.failure`。
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

/// 推流停在 failed 的原因（类型化，W2-D4）：`StreamOutput.failure`。App 按它给提示，不按 `StreamState.failed` 里的文字匹配。
public enum StreamFailure: Hashable, Sendable {
    /// 服务器拒绝鉴权：第一次就停、不退避重试。
    case authentication(StreamAuthFailure)
    /// 连续连不上，超过 `ReconnectPolicy.maxAttempts`。
    case retriesExhausted
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
    let videoBeforeStart = Atomic<UInt64>(0)
    let audioBeforeStart = Atomic<UInt64>(0)
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
    /// 第一次连上之后为 true（start 时清）：缓冲里没送出的从此算损失（断线期间），之前算"开始之前"。放在这里是因为编码器回调闭包只捕获本对象。
    let published = Atomic<Bool>(false)

    var state: StreamState {
        get { stateLock.withLock { $0 } }
        set { stateLock.withLock { $0 = newValue } }
    }

    /// 缓冲里没送出的帧 / 包（缓冲重来清掉的、起步对齐裁掉的、停止时剩下的）：第一次连上之前算"开始之前"，之后算损失（断线期间）。
    func countNotSent(video: Int, audio: Int) {
        countNotSent(video: video, audio: audio, published: published.load(ordering: .relaxed))
    }

    func countNotSent(video: Int, audio: Int, published: Bool) {
        if published {
            if video > 0 { droppedDisconnected.add(UInt64(video), ordering: .relaxed) }
            if audio > 0 { audioDropped.add(UInt64(audio), ordering: .relaxed) }
        } else {
            if video > 0 { videoBeforeStart.add(UInt64(video), ordering: .relaxed) }
            if audio > 0 { audioBeforeStart.add(UInt64(audio), ordering: .relaxed) }
        }
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
        c.videoBeforeStart = videoBeforeStart.load(ordering: .relaxed)
        c.audioBeforeStart = audioBeforeStart.load(ordering: .relaxed)
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
