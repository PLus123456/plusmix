// 引擎（W1-B）、渲染器（W1-C）、输出消费者（W1-E）之间的协议草案。三者互不依赖，只见这里。
// 每拍的调用链：引擎 → Renderer.render(...) → GPU 完成 → RenderSink.renderer(_:didComplete:)（引擎实现）→ 逐个 FrameConsumer.consume(...)
// 音频（提案 001 B，P2 落地）：混音回调 → SPSC 环 → 集成层的泵线程（非实时）→ 逐个 AudioBlockConsumer.consumeAudio(...)

/// 一拍渲染完成的产物。`program` 是 NV12（BT.709 limited）IOSurface 背后的 CVPixelBuffer，pts = 拍点时刻（决策 10）。
public struct RenderedFrame: Sendable {
    /// 哪一拍。
    public let tick: Tick
    /// 这一拍的理想拍点时刻；编码 PTS 用它。
    public let tickTime: HostTime
    /// PGM，inputNumber = 0。
    public let program: Frame
    /// PVW / 多画面，第一版可为 nil（外部显示与 NDI 用得着时再填）。
    public let preview: Frame?
    /// 多画面。
    public let multiview: Frame?
    /// 命令缓冲区提交时刻。
    public let submitTime: HostTime
    /// GPU 开始 / 结束时刻（MTLCommandBuffer 的 GPUStartTime / GPUEndTime 换算成 host time）。
    public let gpuStart: HostTime
    /// GPU 结束时刻。
    public let gpuEnd: HostTime

    public init(tick: Tick, tickTime: HostTime, program: Frame, preview: Frame? = nil, multiview: Frame? = nil,
                submitTime: HostTime, gpuStart: HostTime, gpuEnd: HostTime) {
        self.tick = tick
        self.tickTime = tickTime
        self.program = program
        self.preview = preview
        self.multiview = multiview
        self.submitTime = submitTime
        self.gpuStart = gpuStart
        self.gpuEnd = gpuEnd
    }

    /// V1 口径：拍点时刻 → GPU 完成（ms）。Stats.render_ms 是它在窗口内的平均。
    public var renderMs: Double { (gpuEnd - tickTime).milliseconds }
}

/// 引擎每拍为渲染器准备的输入帧表：下标 = 输入编号。引擎拥有，容量在启动时定，之后每拍复用，零分配。
/// 引擎在调 `render` 前填好，渲染器只在 `render` 里读；`render` 返回后内容可能被覆盖，渲染器要留的东西自己 retain。
public final class RenderInputTable {
    /// 容量 = 最大输入编号 + 1。
    public let capacity: Int
    private var frames: [Frame?]

    public init(capacity: Int) {
        self.capacity = capacity
        frames = Array(repeating: nil, count: capacity)
    }

    /// 按输入编号读写；越界读返回 nil，越界写是编程错误。
    public subscript(inputNumber number: Int) -> Frame? {
        get { (number >= 0 && number < capacity) ? frames[number] : nil }
        set {
            precondition(number >= 0 && number < capacity, "输入编号超出表容量")
            frames[number] = newValue
        }
    }

    /// 全部置空（不释放存储）。
    public func removeAll() {
        for i in frames.indices { frames[i] = nil }
    }
}

/// `render` 的结果。
public enum RenderVerdict: Hashable, Sendable {
    /// 命令缓冲区已提交，稍后 RenderSink 会收到完成回调。
    case submitted
    /// 这一拍没渲染（GPU 还压着 2 帧没完成，或渲染器未就绪）；引擎记 missed_render。
    case skipped
}

/// 渲染器的回调对象（引擎实现）。在 GPU 完成回调线程上被调，必须立即返回：只做派发和统计。
public protocol RenderSink: AnyObject {
    func renderer(_ renderer: any Renderer, didComplete frame: RenderedFrame)
}

/// 合成引擎（W1-C 实现）。
///
/// 线程规则：
/// - `render` 在渲染线程每拍调一次，必须零分配、不等 drawable、不阻塞超过一拍；CPU 领先 GPU ≤ 2 帧用信号量限制。
/// - 完成后在 GPU 回调线程调 `sink.renderer(_:didComplete:)`。
/// - `prepare` / `shutdown` 在非实时线程调，允许分配（纹理池、命令缓冲区池都在这里建）。
public protocol Renderer: AnyObject {
    var sink: (any RenderSink)? { get set }
    /// 建池子。maxInputs = RenderInputTable 容量。
    func prepare(format: ProgramFormat, maxInputs: Int) throws
    /// 渲染一拍：读快照 → 用 inputs 里挑好的帧按 §5 顺序合成 PGM / PVW / 多画面 → 提交。
    func render(tick: Tick, at tickTime: HostTime, snapshot: MixerSnapshot, inputs: RenderInputTable) -> RenderVerdict
    func shutdown()
}

/// PGM 帧的消费者（编码、录制、NDI 发送、虚拟摄像头……，W1-E 起实现）。
///
/// 规则（设计方案 §3.4）：`consume` 在引擎的派发线程上被调，必须立即返回：只把帧放进自己的有界队列；
/// 队列满了丢自己最旧的并记 Stats.encoder[i].skipped；永远不拖渲染线程。每个消费者自己的线程做真正的工作。
public protocol FrameConsumer: AnyObject {
    var consumerName: String { get }
    func consume(_ frame: RenderedFrame)
}

/// 混音块（Master、某条总线、某路输入推子后）的消费者：录制、推流、NDI 发送……，与 `FrameConsumer` 对称（提案 001 B）。
/// 签名逐字 = W1-E 原来在 SwitcherOutputs 里的那份；SwitcherAudioIntegration 的 `AudioBlockConsuming` 是它的 typealias。
///
/// 规则：`consumeAudio` 在**非实时**的泵线程上被调（把混音回调写进 SPSC 环的块搬出来的那条线程，W2-E 的 AudioEngine 提供），
/// 实现必须立即返回：只拷进自己的有界缓冲；永远不在音频实时回调里直接调它（铁律 3）。
/// `planes` 有 channelCount 个指针，每个指向 frameCount 个非交错 float32（48 kHz）；`hostTime` 是块首样本的 host time
/// （与 `AudioRing.write` 同一口径；集成层已按对齐延迟修正到"内容被采集的时刻"，与视频拍点同一时基，PTS 直接用）。
public protocol AudioBlockConsumer: AnyObject {
    /// 名字（Stats / 日志）。
    var consumerName: String { get }
    /// 一块：`planes` 有 channelCount 个指针，每个指向 frameCount 个 float；`hostTime` 是块首样本的 host time。
    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime)
}
