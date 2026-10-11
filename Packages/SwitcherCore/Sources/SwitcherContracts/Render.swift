// 引擎（W1-B）、渲染器（W1-C）、输出消费者（W1-E）之间的协议草案。三者互不依赖，只见这里。
// 每拍的调用链：引擎 → Renderer.render(...) → GPU 完成 → RenderSink.renderer(_:didComplete:)（引擎实现）→ 逐个 FrameConsumer.consume(...)
// 音频（提案 001 B，P2 落地）：混音回调 → SPSC 环 → 集成层的泵线程（非实时）→ 逐个 AudioBlockConsumer.consumeAudio(...)

/// 一拍渲染完成的产物。`program` 是 NV12（BT.709 limited）IOSurface 背后的 CVPixelBuffer，pts = 拍点时刻（决策 10）。
///
/// 时间戳口径（提案 028，用户 2026-10-10 批；W1-B4 的监听同步）：**节目输出时间线** = 内容被采集（拍点）的时刻 + L，L = 为监听同步把视频延后的毫秒数
///（videoDelay 补偿下 = Master 效果链的实测延迟；audioPTS 补偿、没有效果、或组装方没接视频延后时 L = 0，与以前逐值相同）。
public struct RenderedFrame: Sendable {
    /// 哪一拍。
    public let tick: Tick
    /// 这一拍在节目输出时间线上的时刻 = 理想拍点 + 这一帧的视频延后 Lₙ（提案 028）；编码 PTS 用它；**严格递增**（Lₙ 每帧最多改 1/4 拍，不丢不重）。
    /// `tick` 不变；`program.pts` / `preview.pts` / `multiview.pts` **仍是理想拍点**（画面内容的时刻），`tickTime − program.pts` = 这一帧的 Lₙ。
    /// 按内容时刻挑输入帧的（ISO 录制的 ISOFrameTap）比 `program.pts`，打戳用 tickTime。
    public let tickTime: HostTime
    /// PGM，inputNumber = 0。
    public let program: Frame
    /// PVW；用不着时为 nil。
    ///
    /// 填充条件（用户 2026-09-22 定，W3-B 报告 §4 第 5 条）：**状态里有 enabled 的输出、其 `settings.source` 是 `.preview` 时自动填**；
    /// `MetalRendererOptions.previewOutput` 保留为强制开的覆盖（两者取或）。
    public let preview: Frame?
    /// 多画面；用不着时为 nil。填充条件同 `preview`：状态里有 enabled 且 source = `.multiview` 的输出时自动填，
    /// `MetalRendererOptions.multiviewOutput` 是强制开的覆盖。多画面的布局不看 enabled（见 `OutputState.enabled`）。
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
    /// 拍点取 `program.pts`（画面内容的时刻），不取 `tickTime`（提案 028：延后过的帧 tickTime = 拍点 + Lₙ，用它会读出负数）；L = 0 时两者逐值相同。
    public var renderMs: Double { (gpuEnd - program.pts).milliseconds }
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
/// `planes` 有 channelCount 个指针，每个指向 frameCount 个非交错 float32（48 kHz）；`hostTime` 是块首样本**在节目输出时间线上的时刻**
///（与 `RenderedFrame.tickTime` 同一条线，提案 028）= 内容被采集的时刻 + L：集成层已按对齐延迟修正到采集时刻，再按补偿方式平移——
/// videoDelay 下 Master 块不再前移（内容经 Master 效果链本来就晚 L_m），Bus A / B / 耳机块 = 采集 − L_bus + L_m，输入（ISO）块 = 采集 + L_m；
/// audioPTS 下（W5-C 现状）各来源 = 采集 − 各自效果链的延迟，L = 0。两种方式互斥，不会双重补偿；PTS 直接用，与视频同一时基。
public protocol AudioBlockConsumer: AnyObject {
    /// 名字（Stats / 日志）。
    var consumerName: String { get }
    /// 一块：`planes` 有 channelCount 个指针，每个指向 frameCount 个 float；`hostTime` 是块首样本在节目输出时间线上的时刻（见类型说明）。
    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime)
}
