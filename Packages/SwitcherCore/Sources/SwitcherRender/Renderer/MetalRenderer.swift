// 实时合成引擎：实现 SwitcherContracts 的 Renderer 协议（CONTRACTS.md §7）。
//
// 线程模型（设计方案 §3.2、§3.3；CONTRACTS.md §6 T1–T3）：
// - render()：引擎的渲染线程每拍调一次。零分配（Swift 侧；Metal 内部每帧建命令缓冲区 / 编码器对象的分配不可避免，数字见报告）、
//   不等 drawable、不阻塞：GPU 还压着 maxInflight（默认 2）帧没完成就返回 .skipped。
// - 完成线程（switcher.render.completion）：按提交顺序 waitUntilCompleted，读 GPU 时间戳，组 RenderedFrame，调 sink。
//   不用 addCompletedHandler 是因为每帧的闭包 / block 都是堆分配。W1-B3 起挂 time-constraint 实时策略（RealtimeThread.swift）：
//   它放行在途计数，晚醒几毫秒就可能让下一拍 .skipped；并且每次 .skipped 按"跳拍时最旧在途帧的 gpuEnd 是否早于跳拍时刻"归因成
//   GPU 侧晚 / 完成线程晚两类计数（skippedGPULate / skippedCompletionLate），G4 的成串跳拍以后能直接分类而不必从 render_ms 侧推。
// - prepare 末尾做一次首帧空渲染（warmUpGPU）：命令队列的第一次提交、管线 / 私有纹理的第一次用都在起时钟之前付掉。
// - 标签线程：见 LabelRenderer。
// - 显示视图（MetalDisplayView）在主线程从 latestDisplayFrame 拿"最新完成的纹理"，用同一个命令队列 blit，
//   同队列上 Metal 自动追踪读写冲突，所以三重缓冲 + 在途 ≤ 2 就够，不需要第四重。
// - 显示延后（W1-B4，提案 028）：引擎把画面延后 L 派发时（监听同步），显示源给"拍点 + L 已到期"的最新一帧（`displayDelayProvider`）。
//   为此多留 ⌈L_max / 拍长⌉ 格合成目标（`displayDelayHistory`），完成线程按格记下"这一格现在装的是第几帧、拍点"；
//   NV12 输出环也加深 ⌈L_max / 拍长⌉ + 1（`videoDelayHeadroom`：引擎的延迟队列扣着这些帧的输出缓冲）。不开就与以前逐行相同。
@preconcurrency import Metal
import CoreVideo
import Foundation
import IOSurface
import Synchronization
import SwitcherContracts

/// 渲染器选项。
public struct MetalRendererOptions: Sendable {
    /// 三重缓冲。
    public var slotCount: Int = 3
    /// CPU 领先 GPU 的上限（帧）。
    public var maxInflight: Int = 2
    /// 输出 NV12 缓冲环的大小；消费者最多同时持有 ringSize − maxInflight − 1 个。
    public var outputRingSize: Int = 8
    /// 是否画多画面（关掉省 GPU；测试基线用）。
    public var multiview: Bool = true
    /// PVW 画**所有**叠加的总开关（提案 010）。默认关，这时 PVW 只画 `OverlayState.previewOn` 的那几路；
    /// 一路都没开就是纯输入（`v8-preview-pvw.png` 的口径不变）。
    public var overlaysInPreview: Bool = false
    /// 强制把 PVW 转成 NV12 填进 `RenderedFrame.preview`。默认关：状态里有 enabled 且 source = preview 的输出时自动填，
    /// 这一项只是强制开的覆盖（多一趟 compute）。强制开时 PVW 的输出环在 prepare 里建；否则状态第一次要它时由后台线程建（W3-B2）。
    public var previewOutput: Bool = false
    /// 强制把多画面转成 NV12 填进 `RenderedFrame.multiview`（需要 multiview = true）。默认关，自动填的条件与环的建法同上。
    public var multiviewOutput: Bool = false
    /// 视频延后的余量（W1-B4，提案 028）：引擎最多把帧压多久再派发（= `EngineOptions.videoDelay.maxDelay`，默认 35 ms；这里默认 0 = 不留）。
    /// > 0 时 PGM / PVW / 多画面三个 NV12 输出环各加深 ⌈余量 / 拍长⌉ + 1 个缓冲（35 ms @ 60 fps：8 → 12）：延迟队列里压着的帧还扣着它们的输出缓冲，
    /// 不加深的话环被扣满就退回池子分配（渲染线程上分配）。1080p 每个缓冲 3 MB。
    public var videoDelayHeadroom: HostDuration = .zero
    /// 显示也延后（W1-B4）：再多留 ⌈videoDelayHeadroom / 拍长⌉ 格合成目标（1080p 每格 PGM / PVW / 多画面三张 BGRA ≈ 25 MB），
    /// `latestDisplayFrame` 按 `displayDelayProvider` 给"拍点 + 延后已到期"的最新一帧。默认关（显示最新完成的一帧）。
    public var displayDelayHistory: Bool = false
    public init() {}
}

/// 显示视图要的东西。
public enum DisplayTarget: Sendable, Hashable {
    case program, preview, multiview
}

/// "最新完成的纹理"及其版本号（完成帧计数，显示视图用来跳过重复 blit）。
public struct DisplayFrame {
    public let texture: any MTLTexture
    public let version: UInt64
    public let tick: Tick
}

/// 显示视图的数据来源（MetalRenderer 实现；测试可以伪造）。
public protocol DisplayFrameSource: AnyObject {
    /// 最新完成的 PGM / PVW / 多画面纹理；还没有完成任何一帧时为 nil。任意线程可调，不阻塞。
    func latestDisplayFrame(for target: DisplayTarget) -> DisplayFrame?
    /// 显示 blit 用的命令队列（与渲染同一个，Metal 追踪冲突）。
    var displayCommandQueue: any MTLCommandQueue { get }
}

public final class MetalRenderer: Renderer, DisplayFrameSource, @unchecked Sendable {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let options: MetalRendererOptions

    private let sinkLock = NSLock()
    private var sinkStorage: (any RenderSink)?
    public var sink: (any RenderSink)? {
        get { sinkLock.lock(); defer { sinkLock.unlock() }; return sinkStorage }
        set { sinkLock.lock(); sinkStorage = newValue; sinkLock.unlock() }
    }

    // prepare 建、shutdown 拆；stateLock 保护这些引用（render 线程读时不拿锁：prepare/shutdown 只在引擎停着时调）
    private let stateLock = NSLock()
    private var resources: RenderResources?
    private var slots: [RenderSlot] = []
    private var table: SurfaceTextureTable?
    private var ring: OutputBufferRing?
    /// PVW / 多画面的 NV12 输出环：按需建（W3-B2，见 AuxOutputRings.swift）。
    private var auxRings: AuxOutputRings?
    private var labels: LabelRenderer?
    private var format: ProgramFormat?
    private var frameDuration: HostDuration = .zero
    /// 多画面布局表：只有渲染线程碰；快照 sequence 变了才重新解析。
    private let layout = MultiviewLayoutTable()
    private var layoutSequence: UInt64 = .max
    /// 多画面电平表的读数通道（W3-B2）：setMeters 写、渲染线程每帧读。跟渲染器同寿命（prepare 之前也能喂）。
    private let meterFeed = MultiviewMeterFeed()

    // MARK: 显示延后（W1-B4）
    /// 每格现在装着的那一帧（完成线程写：先写拍 / 拍点，再 release 写"帧序号 + 1"；显示线程 acquire 读，读完再核一次序号）。容量固定 64 格。
    private static let maxSlots = 64
    private let slotFrame: UnsafeMutablePointer<Atomic<UInt64>>
    private let slotTick: UnsafeMutablePointer<Atomic<Int64>>
    private let slotTickTime: UnsafeMutablePointer<Atomic<UInt64>>
    private let displayDelayLock = NSLock()
    private var displayDelaySource: (@Sendable () -> HostDuration)?
    /// 显示延后的来源：组装方设成 `{ engine.videoDelayApplied }`（引擎正在用的延后）；nil 或给出 ≤ 0 = 显示最新完成的一帧（以前的行为）。
    /// `latestDisplayFrame` 每次调一次它（显示线程，主线程 120 Hz 量级），要快、不能阻塞。
    public var displayDelayProvider: (@Sendable () -> HostDuration)? {
        get { displayDelayLock.lock(); defer { displayDelayLock.unlock() }; return displayDelaySource }
        set { displayDelayLock.lock(); displayDelaySource = newValue; displayDelayLock.unlock() }
    }
    /// 延后的那一帧已经被新帧覆盖（历史格数不够），只好给最旧的还完整的一帧的次数（诊断；开了 displayDelayHistory 且延后 ≤ 余量时应为 0）。
    private let displayDelayShortfallCount = Atomic<UInt64>(0)
    public var displayDelayShortfalls: UInt64 { displayDelayShortfallCount.load(ordering: .acquiring) }

    /// 在途帧数（已提交未完成）。
    let inflight = Atomic<Int>(0)
    /// 已提交的帧数（= 下一帧的序号）。只有渲染线程写。
    let submitted = Atomic<UInt64>(0)
    /// 已完成的帧数。只有完成线程写。
    let completed = Atomic<UInt64>(0)
    /// 最新完成的 slot 下标；−1 = 还没有。
    let latestCompletedSlot = Atomic<Int>(-1)
    /// render 返回 .skipped 的次数（引擎那边是 missed_render；这里只给测试看）。
    let skipped = Atomic<UInt64>(0)

    private let pending = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stopping = Atomic<Bool>(false)
    private var completionThread: RealtimeThread?

    // MARK: 跳拍归因与预热（W1-B3；诊断量，不进 Stats，铁律 4 的那份数字仍是引擎的 missed_render）

    /// .skipped 里"跳拍时最旧的在途帧 GPU 已完成、只是完成线程还没放行"的次数（CPU 侧：完成线程晚醒）。
    let skippedCompletionLate = Atomic<UInt64>(0)
    /// .skipped 里"跳拍时最旧的在途帧 GPU 还没完成"的次数（GPU 侧：GPU 被抢占 / 驱动排队）。
    let skippedGPULate = Atomic<UInt64>(0)
    /// 渲染线程记跳拍时刻（host tick）的环，完成线程消费；容量 64（一次突发不会超过它）。
    private static let skipRingCapacity = 64
    private let skipTimes: UnsafeMutablePointer<Atomic<Int64>>
    private let skipWrite = Atomic<Int>(0)
    /// 完成线程私有的读游标。
    private var skipRead = 0
    /// 跳拍时最旧在途帧的年龄（now − submitTime）的窗口最大值，读后清零。
    private let skipOldestAgeMaxNs = Atomic<Int64>(0)
    /// 完成线程醒来时刻 − gpuEnd 的窗口最大值（放行延迟），读后清零。
    private let completionWakeLagMaxNs = Atomic<Int64>(0)
    /// prepare 里做过的预热帧数（0 或 1）与预热帧的 gpuStart − 提交 延迟。
    private(set) var warmupFrames = 0
    private(set) var warmupGpuStartLatency: HostDuration = .zero
    /// SWITCHER_RENDER_DIAG=1：完成线程每归因一次跳拍就往 stderr 打一行（打印会分配、会拿锁，只在诊断时开）。
    private let diagnostics = ProcessInfo.processInfo.environment["SWITCHER_RENDER_DIAG"] == "1"

    public init(device: (any MTLDevice)? = nil, options: MetalRendererOptions = MetalRendererOptions()) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = dev
        guard let q = dev.makeCommandQueue() else { throw RenderError.resource("建不出命令队列") }
        q.label = "switcher.render"
        commandQueue = q
        self.options = options
        skipTimes = .allocate(capacity: MetalRenderer.skipRingCapacity)
        for i in 0..<MetalRenderer.skipRingCapacity { (skipTimes + i).initialize(to: Atomic(0)) }
        slotFrame = .allocate(capacity: MetalRenderer.maxSlots)
        slotTick = .allocate(capacity: MetalRenderer.maxSlots)
        slotTickTime = .allocate(capacity: MetalRenderer.maxSlots)
        for i in 0..<MetalRenderer.maxSlots {
            (slotFrame + i).initialize(to: Atomic(0))
            (slotTick + i).initialize(to: Atomic(0))
            (slotTickTime + i).initialize(to: Atomic(0))
        }
    }

    deinit {
        shutdown()
        skipTimes.deinitialize(count: MetalRenderer.skipRingCapacity)
        skipTimes.deallocate()
        slotFrame.deinitialize(count: MetalRenderer.maxSlots); slotFrame.deallocate()
        slotTick.deinitialize(count: MetalRenderer.maxSlots); slotTick.deallocate()
        slotTickTime.deinitialize(count: MetalRenderer.maxSlots); slotTickTime.deallocate()
    }

    // MARK: - Renderer

    public func prepare(format: ProgramFormat, maxInputs: Int) throws {
        shutdown()
        let res = try RenderResources.shared(for: device)
        let period = TickClockSpec(t0: .zero, frameRate: format.frameRate).duration(ofTicks: 1)
        // 视频延后的余量（W1-B4）：延后最多压 ⌈余量 / 拍长⌉ 帧；输出环多 +1 盖住"新帧入队时队头正在出队"（与引擎的延迟队列深度同一个算法）
        let delayFrames = options.videoDelayHeadroom.ticks > 0
            ? Int((Double(options.videoDelayHeadroom.ticks) / Double(max(1, period.ticks))).rounded(.up)) : 0
        let ringCount = options.outputRingSize + (delayFrames > 0 ? delayFrames + 1 : 0)
        let slotTotal = min(MetalRenderer.maxSlots, max(2, options.slotCount) + (options.displayDelayHistory ? delayFrames : 0))
        var newSlots: [RenderSlot] = []
        for i in 0..<slotTotal {
            let targets = try RenderTargets(device: device, width: format.width, height: format.height, label: "slot\(i)")
            newSlots.append(RenderSlot(index: i, targets: targets, maxInputs: max(1, maxInputs)))
        }
        // 输入：每路最多约 8 个池缓冲 × 2 平面；输出环的纹理 W3-B2 起在建环时包好、不进这张表，余量留给环被占满时退回池子的缓冲
        let tbl = SurfaceTextureTable(device: device, capacity: max(1, maxInputs) * 16 + ringCount * 2 + 8)
        let rng = try OutputBufferRing(width: format.width, height: format.height, count: ringCount, device: device)
        // PVW / 多画面的 NV12 环（W3-B2 可选项）：强制开的在这里建；其余等渲染线程第一次看到状态要它时由后台线程建。
        // P3 时两个环总是在这里建（prepare 时没有状态、渲染线程又不许分配），没有这类输出时 1080p / ringSize 8 各白占约 25 MB
        var eager: [AuxOutputRings.Kind] = []
        if options.previewOutput { eager.append(.preview) }
        if options.multiview && options.multiviewOutput { eager.append(.multiview) }
        let aux = try AuxOutputRings(device: device, width: format.width, height: format.height, count: ringCount, eager: eager)
        // 标签：输入槽按输入表容量要，LabelSet 封顶 64（多画面最多 64 格）
        let lbl = try LabelRenderer(device: device, inputSlots: max(1, maxInputs),
                                    completedFrames: { [weak self] in self?.completed.load(ordering: .acquiring) ?? .max })
        // W1-B3 首帧空渲染：不预热时第 0 帧的 gpuStart − 提交 要 13 ms（队列第一次提交、管线 / 私有纹理第一次用），稳态 < 1 ms；在起时钟之前付掉
        try warmUpGPU(resources: res, slot: newSlots[0], table: tbl, ring: rng, format: format)
        stateLock.lock()
        resources = res
        slots = newSlots
        table = tbl
        ring = rng
        auxRings = aux
        labels = lbl
        layoutSequence = .max
        self.format = format
        frameDuration = period
        stopping.store(false, ordering: .releasing)
        inflight.store(0, ordering: .releasing)
        submitted.store(0, ordering: .releasing)
        completed.store(0, ordering: .releasing)
        latestCompletedSlot.store(-1, ordering: .releasing)
        skipWrite.store(0, ordering: .releasing)
        skipRead = 0
        for i in 0..<MetalRenderer.maxSlots { slotFrame[i].store(0, ordering: .releasing) }
        stateLock.unlock()
        lbl.start()
        aux.start()
        // 完成线程：实时策略，参数与节目时钟线程同一套（period = 拍长，computation 1/4 拍，constraint 半拍；实际每拍只做几十微秒的放行 + 派发。
        // 申报 1/8 拍时内核读回来是 1/4 拍——它有下限，索性与时钟线程一致）
        let periodTicks = UInt32(clamping: period.ticks)
        let tc = RealtimeThreadConfig.TimeConstraint(period: periodTicks, computation: max(1, periodTicks / 4), constraint: max(1, periodTicks / 2))
        let t = RealtimeThread(config: RealtimeThreadConfig(name: "switcher.render.completion", timeConstraint: tc)) { [self] in completionLoop() }
        do { try t.start() } catch {
            throw RenderError.resource("完成线程起不来：\(error)")
        }
        completionThread = t
    }

    /// 首帧空渲染（W1-B3）：空状态、空输入表，真走一遍 encodeFrame（PGM / PVW / 多画面 + NV12）到 slot 与输出环的一个缓冲，同步等 GPU 完成，
    /// 再放资源。不经过完成线程、不进提交 / 完成计数、不给 sink。
    private func warmUpGPU(resources: RenderResources, slot: RenderSlot, table: SurfaceTextureTable, ring: OutputBufferRing, format: ProgramFormat) throws {
        guard let out = ring.nextSlot(), let cb = commandQueue.makeCommandBuffer() else { throw RenderError.resource("预热帧建不出命令缓冲区") }
        cb.label = "warmup"
        let state = MixerState(format: format)
        let inputs = RenderInputTable(capacity: 1)
        layout.parse(state: state, width: format.width, height: format.height)
        let program = out.target ?? nv12Target(out.buffer, table: table, width: format.width, height: format.height, frame: 0)
        let context = CompositorPasses.Context(resources: resources, table: table, labels: nil, layout: layout, frameIndex: 0)
        slot.outputBuffer = out.buffer
        CompositorPasses.encodeFrame(state: state, inputs: inputs, slot: slot, context: context, commandBuffer: cb,
                                     outputs: CompositorPasses.FrameOutputs(program: program), multiview: options.multiview)
        let submitTime = HostClock.now()
        cb.commit()
        cb.waitUntilCompleted()
        let gpuStart = HostTime(nanoseconds: UInt64(max(0, cb.gpuStartTime) * 1e9))
        warmupGpuStartLatency = gpuStart - submitTime
        warmupFrames += 1
        slot.releaseFrame()
    }

    public func render(tick: Tick, at tickTime: HostTime, snapshot: MixerSnapshot, inputs: RenderInputTable) -> RenderVerdict {
        // Metal 的 makeCommandBuffer / make…Encoder 返回 autoreleased 对象；渲染线程若从不 drain，自动释放池每几百帧就新开一页（分配）。
        // 这里每拍 drain 一次（pop 只释放，不 malloc；线程的热页会被 objc 缓存复用）。W1-B 的渲染线程每拍也应包一层 autoreleasepool。
        autoreleasepool { renderInsidePool(tick: tick, at: tickTime, snapshot: snapshot, inputs: inputs) }
    }

    private func renderInsidePool(tick: Tick, at tickTime: HostTime, snapshot: MixerSnapshot, inputs: RenderInputTable) -> RenderVerdict {
        guard let resources, let table, let ring, let auxRings, let labels, !slots.isEmpty else { return .skipped }
        RenderSignposts.begin(.frame)
        defer { RenderSignposts.end(.frame) }
        // T3：GPU 压着 maxInflight 帧没完成 → 跳过这一拍，不等
        if inflight.load(ordering: .acquiring) >= options.maxInflight {
            skipped.wrappingAdd(1, ordering: .relaxed)
            RenderSignposts.event("skip-inflight")
            noteSkip()
            return .skipped
        }
        let frameIndex = submitted.load(ordering: .relaxed)
        let slot = slots[Int(frameIndex % UInt64(slots.count))]
        labels.noteSnapshot(snapshot)
        // 标签线程画好了新的一套就在这一帧接手（改名的下一帧就是新名字，见 LabelRenderer）
        let labelSet = options.multiview ? labels.acquire(frame: frameIndex) : nil

        guard let out = ring.nextSlot() else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            RenderSignposts.event("skip-no-output-buffer")
            return .skipped
        }
        let output = out.buffer
        let width = slot.targets.width, height = slot.targets.height
        // 环里的缓冲建环时就包好了纹理；只有环被消费者占满、退回池子分配的缓冲才走纹理表
        guard let program = out.target ?? nv12Target(output, table: table, width: width, height: height, frame: frameIndex),
              let cb = commandQueue.makeCommandBufferWithUnretainedReferences() else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            RenderSignposts.event("skip-resource")
            return .skipped
        }
        cb.label = "frame"   // 短 ASCII 字面量是 tagged pointer，不分配；"switcher.frame" 这种长度会分配
        slot.tick = tick
        slot.tickTime = tickTime
        slot.frameIndex = frameIndex
        slot.outputBuffer = output
        slot.commandBuffer = cb
        // PVW / 多画面的 NV12 输出：状态里有 enabled 且 source 是它的输出就填（提案 010），选项是强制开的覆盖；
        // 环还没建好（第一次要的那一两帧，后台线程在建）或拿不到缓冲，这一帧就不出，不拖 PGM
        let state = snapshot.state
        var outputs = CompositorPasses.FrameOutputs(program: program)
        if options.previewOutput || CompositorPasses.wants(.preview, in: state),
           let previewRing = auxRings.ring(.preview), let s = previewRing.nextSlot(),
           let t = s.target ?? nv12Target(s.buffer, table: table, width: width, height: height, frame: frameIndex) {
            slot.previewBuffer = s.buffer
            outputs.preview = t
        }
        if options.multiview, options.multiviewOutput || CompositorPasses.wants(.multiview, in: state),
           let multiviewRing = auxRings.ring(.multiview), let s = multiviewRing.nextSlot(),
           let t = s.target ?? nv12Target(s.buffer, table: table, width: width, height: height, frame: frameIndex) {
            slot.multiviewBuffer = s.buffer
            outputs.multiview = t
        }
        if snapshot.sequence != layoutSequence {
            layoutSequence = snapshot.sequence
            layout.parse(state: state, width: width, height: height)
        }
        var context = CompositorPasses.Context(resources: resources, table: table, labels: labelSet, layout: layout, frameIndex: frameIndex)
        context.overlaysInPreview = options.overlaysInPreview
        if options.multiview { context.meters = meterFeed.acquire(now: tickTime) }
        CompositorPasses.encodeFrame(state: state, inputs: inputs, slot: slot, context: context, commandBuffer: cb,
                                     outputs: outputs, multiview: options.multiview)

        RenderSignposts.begin(.submit)
        inflight.wrappingAdd(1, ordering: .acquiringAndReleasing)
        cb.commit()
        slot.submitTime = HostClock.now()
        submitted.store(frameIndex + 1, ordering: .releasing)
        pending.signal()
        RenderSignposts.end(.submit)
        if frameIndex % 600 == 599 { table.evictIdle(frame: frameIndex) }
        return .submitted
    }

    /// 渲染线程：记下跳拍时刻给完成线程归因；顺便记最旧在途帧的年龄。零分配：预分配环 + 原子量；submitTime 只有渲染线程写。
    @inline(__always)
    private func noteSkip() {
        let now = HostClock.now()
        let w = skipWrite.load(ordering: .relaxed)
        skipTimes[w % MetalRenderer.skipRingCapacity].store(Int64(clamping: now.ticks), ordering: .relaxed)
        skipWrite.store(w &+ 1, ordering: .releasing)
        let oldest = slots[Int(completed.load(ordering: .acquiring) % UInt64(slots.count))]
        _ = skipOldestAgeMaxNs.max((now - oldest.submitTime).nanoseconds, ordering: .relaxed)
    }

    /// 完成线程：把渲染线程记下的、发生在这一帧在途期间的跳拍按这一帧的 gpuEnd 归因（这一帧就是跳拍时最旧的在途帧）。
    @inline(__always)
    private func attributeSkips(submitTime: HostTime, gpuEnd: HostTime, wakeTime: HostTime, tick: Tick) {
        let w = skipWrite.load(ordering: .acquiring)
        while skipRead < w {
            let s = skipTimes[skipRead % MetalRenderer.skipRingCapacity].load(ordering: .relaxed)
            skipRead += 1
            let cause = MetalRenderer.classifySkip(skipTime: HostTime(ticks: UInt64(max(0, s))), oldestGpuEnd: gpuEnd)
            switch cause {
            case .completionLate: skippedCompletionLate.add(1, ordering: .relaxed)
            case .gpuLate: skippedGPULate.add(1, ordering: .relaxed)
            }
            if diagnostics {
                fputs("render-diag skip while frame tick \(tick.rawValue) in flight: \(cause), skip at +\(String(format: "%.2f", (HostTime(ticks: UInt64(max(0, s))) - submitTime).milliseconds)) ms after its submit, gpuEnd at +\(String(format: "%.2f", (gpuEnd - submitTime).milliseconds)) ms, completion wake lag \(String(format: "%.3f", (wakeTime - gpuEnd).milliseconds)) ms\n", stderr)
            }
        }
    }

    /// 跳拍原因。
    enum SkipCause: Equatable, CustomStringConvertible {
        /// 跳拍那一刻最旧的在途帧 GPU 已完成：是完成线程还没放行（CPU 侧调度）。
        case completionLate
        /// 跳拍那一刻最旧的在途帧 GPU 还没完成：GPU 侧晚（抢占 / 驱动排队 / 帧太重）。
        case gpuLate
        var description: String { self == .gpuLate ? "gpu-late" : "completion-late" }
    }

    /// 归因规则：最旧在途帧的 gpuEnd ≤ 跳拍时刻 → completionLate，否则 gpuLate。
    static func classifySkip(skipTime: HostTime, oldestGpuEnd: HostTime) -> SkipCause {
        oldestGpuEnd <= skipTime ? .completionLate : .gpuLate
    }

    /// 退回池子分配的输出缓冲（环被消费者占满时）：IOSurface 的两个平面包成整数视图，表里按 IOSurfaceID 缓存。
    @inline(__always)
    private func nv12Target(_ pixelBuffer: CVPixelBuffer, table: SurfaceTextureTable, width: Int, height: Int, frame: UInt64) -> CompositorPasses.NV12Target? {
        guard let unmanaged = CVPixelBufferGetIOSurface(pixelBuffer) else { return nil }
        let surface = unmanaged.takeUnretainedValue()
        guard let luma = table.texture(surface: surface, plane: 0, format: .r8Uint, width: width, height: height, usage: .shaderWrite, frame: frame),
              let chroma = table.texture(surface: surface, plane: 1, format: .rg8Uint, width: (width + 1) / 2, height: (height + 1) / 2,
                                         usage: .shaderWrite, frame: frame) else { return nil }
        return CompositorPasses.NV12Target(luma: luma, chroma: chroma)
    }

    public func shutdown() {
        guard completionThread != nil || resources != nil else { return }
        stopping.store(true, ordering: .releasing)
        pending.signal()
        if let t = completionThread {
            finished.wait()
            t.join()
            completionThread = nil
        }
        labels?.stop()
        auxRings?.stop()
        stateLock.lock()
        resources = nil
        slots = []
        table = nil
        ring = nil
        auxRings = nil
        labels = nil
        format = nil
        latestCompletedSlot.store(-1, ordering: .releasing)
        stateLock.unlock()
    }

    // MARK: - 完成线程

    private func completionLoop() {
        var next: UInt64 = 0
        while true {
            pending.wait()
            if next >= submitted.load(ordering: .acquiring) {
                if stopping.load(ordering: .acquiring) { break }
                continue
            }
            let slot = slots[Int(next % UInt64(slots.count))]
            guard let cb = slot.commandBuffer, let output = slot.outputBuffer else {
                next += 1
                continue
            }
            cb.waitUntilCompleted()
            let wakeTime = HostClock.now()
            let gpuStart = HostTime(nanoseconds: UInt64(max(0, cb.gpuStartTime) * 1e9))
            let gpuEnd = HostTime(nanoseconds: UInt64(max(0, cb.gpuEndTime) * 1e9))
            let tick = slot.tick, tickTime = slot.tickTime, submitTime = slot.submitTime
            let previewBuffer = slot.previewBuffer, multiviewBuffer = slot.multiviewBuffer
            _ = completionWakeLagMaxNs.max((wakeTime - gpuEnd).nanoseconds, ordering: .relaxed)
            attributeSkips(submitTime: submitTime, gpuEnd: gpuEnd, wakeTime: wakeTime, tick: tick)
            // 先放资源、放行渲染线程，再派发
            slot.releaseFrame()
            // 显示延后（W1-B4）：这一格现在装的是第 next 帧（先写拍 / 拍点，再 release 发布序号）
            slotTick[slot.index].store(tick.rawValue, ordering: .relaxed)
            slotTickTime[slot.index].store(tickTime.ticks, ordering: .relaxed)
            slotFrame[slot.index].store(next + 1, ordering: .releasing)
            latestCompletedSlot.store(slot.index, ordering: .releasing)
            completed.store(next + 1, ordering: .releasing)
            inflight.wrappingSubtract(1, ordering: .acquiringAndReleasing)
            let program = Frame(pixelBuffer: output, pts: tickTime, duration: frameDuration, color: .bt709Limited,
                                inputNumber: 0, sequence: next, ingressTime: gpuEnd)
            let preview = previewBuffer.map { Frame(pixelBuffer: $0, pts: tickTime, duration: frameDuration, color: .bt709Limited,
                                                    inputNumber: 0, sequence: next, ingressTime: gpuEnd) }
            let multiview = multiviewBuffer.map { Frame(pixelBuffer: $0, pts: tickTime, duration: frameDuration, color: .bt709Limited,
                                                        inputNumber: 0, sequence: next, ingressTime: gpuEnd) }
            let frame = RenderedFrame(tick: tick, tickTime: tickTime, program: program, preview: preview, multiview: multiview,
                                      submitTime: submitTime, gpuStart: gpuStart, gpuEnd: gpuEnd)
            if let sink { sink.renderer(self, didComplete: frame) }
            next += 1
        }
        finished.signal()
    }

    // MARK: - 多画面电平表（W3-B2）

    /// 把表读数递给多画面的电平表。组装方（App / headless）在**非实时线程**调：每秒 Stats 发布时喂 `stats.audio.meters`，
    /// 想让表更活可以更密（例如 App 按 50 ms 的表读数拼一份同形态的 Meters）；不许在音频实时回调里调（这里分配、拿锁）。
    /// - 输入格读 `meters.inputs[n]`，PGM 格读 master 总线，PVW 格读当前 PVW 那路输入；只用峰值（契约没有 RMS）。
    /// - 峰值保持 1 s 按 `time`（喂数时刻）算；超过 3 s 没喂新数，渲染线程就当没有读数（输入格退回占位）。
    /// - nil = 清掉（例如音频引擎停了）。多条线程同时调会按锁串行，渲染线程从不等它。
    public func setMeters(_ meters: Stats.AudioCounters.Meters?, at time: HostTime = HostClock.now()) {
        meterFeed.write(meters, at: time)
    }

    /// 渲染线程接手新电平表的次数（测试看）。
    var meterAdoptions: Int { meterFeed.adoptions.load(ordering: .relaxed) }

    /// 标签线程交出新一套标签的次数、最近一次的时刻（测试 / 报告看改名的延迟）。
    var labelPublishes: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return labels?.publishedCount.load(ordering: .acquiring) ?? 0
    }
    var lastLabelPublishTime: HostTime? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let ticks = labels?.lastPublishTicks.load(ordering: .relaxed), ticks > 0 else { return nil }
        return HostTime(ticks: ticks)
    }

    // MARK: - DisplayFrameSource

    public var displayCommandQueue: any MTLCommandQueue { commandQueue }

    public func latestDisplayFrame(for target: DisplayTarget) -> DisplayFrame? {
        if let delay = displayDelayProvider?(), delay.ticks > 0 { return delayedDisplayFrame(for: target, delay: delay) }
        let index = latestCompletedSlot.load(ordering: .acquiring)
        guard index >= 0 else { return nil }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard index < slots.count else { return nil }
        let slot = slots[index]
        let version = completed.load(ordering: .acquiring)
        switch target {
        case .program: return DisplayFrame(texture: slot.targets.program, version: version, tick: slot.tick)
        case .preview: return DisplayFrame(texture: slot.targets.preview, version: version, tick: slot.tick)
        case .multiview: return DisplayFrame(texture: slot.targets.multiview, version: version, tick: slot.tick)
        }
    }

    /// 显示延后（W1-B4）：从最新完成的帧往回找"拍点 + 延后 ≤ 现在"的最新一帧。只看还完整的格：第 k 帧所在格要等第 k + 格数 帧提交才被覆盖，
    /// 再留一帧余量（显示这次 blit 提交之前，渲染线程最多再提交一帧），所以 k ≥ 已提交 − 格数 + 2。
    /// 找到了给它；往回找到了完整格的边界还没到期（延后超出历史）给最旧的完整那一帧并计一次 shortfall；一直找到第 0 帧都没到期（刚开始）给 nil。
    private func delayedDisplayFrame(for target: DisplayTarget, delay: HostDuration) -> DisplayFrame? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let n = UInt64(slots.count)
        let done = completed.load(ordering: .acquiring)
        guard n > 0, done > 0 else { return nil }
        let sub = submitted.load(ordering: .acquiring)
        let oldestSafe: UInt64 = sub + 2 > n ? sub + 2 - n : 0
        let cutoff = HostClock.now() - delay
        var k = done - 1
        var chosen: UInt64?
        var oldestIntact: UInt64?
        var limited = false
        while true {
            if k < oldestSafe { limited = true; break }
            let s = Int(k % n)
            guard slotFrame[s].load(ordering: .acquiring) == k + 1 else { limited = true; break }
            let tickTime = HostTime(ticks: slotTickTime[s].load(ordering: .relaxed))
            guard slotFrame[s].load(ordering: .acquiring) == k + 1 else { limited = true; break }
            oldestIntact = k
            if tickTime <= cutoff { chosen = k; break }
            if k == 0 { break }
            k -= 1
        }
        if chosen == nil && limited && oldestIntact != nil { displayDelayShortfallCount.add(1, ordering: .relaxed) }
        guard let pick = chosen ?? (limited ? oldestIntact : nil) else { return nil }
        let slot = slots[Int(pick % n)]
        let tick = Tick(slotTick[Int(pick % n)].load(ordering: .relaxed))
        switch target {
        case .program: return DisplayFrame(texture: slot.targets.program, version: pick + 1, tick: tick)
        case .preview: return DisplayFrame(texture: slot.targets.preview, version: pick + 1, tick: tick)
        case .multiview: return DisplayFrame(texture: slot.targets.multiview, version: pick + 1, tick: tick)
        }
    }

    // MARK: - 给测试 / 报告看的计数

    /// 合成目标的格数（3，开了显示延后再加 ⌈余量 / 拍长⌉）。
    var slotCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return slots.count }
    /// PGM 的 NV12 输出环有几个缓冲（outputRingSize，开了视频延后余量再加 ⌈余量 / 拍长⌉ + 1）。
    var outputRingCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return ring?.count ?? 0 }

    /// PVW / 多画面的输出环建了没有、后台线程建过几次、常驻多少字节（W3-B2 按需建）。
    func isAuxRingBuilt(_ kind: AuxOutputRings.Kind) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return auxRings?.isBuilt(kind) ?? false
    }
    var auxRingBuilds: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return auxRings?.builds.load(ordering: .relaxed) ?? 0
    }
    var auxRingResidentBytes: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return auxRings?.residentBytes ?? 0
    }

    /// 跳拍归因计数（W1-B3）：GPU 侧晚 / 完成线程晚。两者之和 = 因在途满而 .skipped 的次数（完成线程处理完之后）。
    public var skipAttribution: (gpuLate: UInt64, completionLate: UInt64) {
        (skippedGPULate.load(ordering: .acquiring), skippedCompletionLate.load(ordering: .acquiring))
    }
    /// 完成线程"GPU 完成 → 醒来"的窗口最大延迟，读后清零。
    public func takeCompletionWakeLagMax() -> HostDuration {
        HostDuration(nanoseconds: completionWakeLagMaxNs.exchange(0, ordering: .acquiringAndReleasing))
    }
    /// 跳拍时最旧在途帧年龄的窗口最大值，读后清零。
    public func takeSkipOldestAgeMax() -> HostDuration {
        HostDuration(nanoseconds: skipOldestAgeMaxNs.exchange(0, ordering: .acquiringAndReleasing))
    }
    /// 完成线程的实时策略是否生效（prepare 之后有效）。
    public var completionThreadIsRealtime: Bool { completionThread?.appliedTimeConstraint ?? false }
    /// 完成线程的 mach 端口（测试读回策略用；prepare 之后有效）。
    var completionThreadPort: thread_t { completionThread?.machPort ?? 0 }

    /// 预热后应为 0：稳态每个 IOSurface 都命中。W3-B2 起输出环的纹理不进这张表（建环时包好），这里只剩输入。
    var textureCreateCount: Int { table?.createCount ?? 0 }
    /// 环里没空闲缓冲、退回池子分配的次数；稳态应为 0。
    var outputFallbackCount: Int { ring?.fallbackCount ?? 0 }
    /// 当前节目格式。
    public var preparedFormat: ProgramFormat? { stateLock.lock(); defer { stateLock.unlock() }; return format }
}
