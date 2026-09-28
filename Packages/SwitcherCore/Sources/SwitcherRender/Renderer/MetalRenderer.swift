// 实时合成引擎：实现 SwitcherContracts 的 Renderer 协议（CONTRACTS.md §7）。
//
// 线程模型（设计方案 §3.2、§3.3；CONTRACTS.md §6 T1–T3）：
// - render()：引擎的渲染线程每拍调一次。零分配（Swift 侧；Metal 内部每帧建命令缓冲区 / 编码器对象的分配不可避免，数字见报告）、
//   不等 drawable、不阻塞：GPU 还压着 maxInflight（默认 2）帧没完成就返回 .skipped。
// - 完成线程（switcher.render.completion）：按提交顺序 waitUntilCompleted，读 GPU 时间戳，组 RenderedFrame，调 sink。
//   不用 addCompletedHandler 是因为每帧的闭包 / block 都是堆分配。
// - prepare 末尾做一次首帧空渲染（warmUpGPU，W1-B3）：命令队列的第一次提交、管线 / 私有纹理的第一次用都在起时钟之前付掉。
// - 标签线程：见 LabelRenderer。
// - 显示视图（MetalDisplayView）在主线程从 latestDisplayFrame 拿"最新完成的纹理"，用同一个命令队列 blit，
//   同队列上 Metal 自动追踪读写冲突，所以三重缓冲 + 在途 ≤ 2 就够，不需要第四重。
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
    private var completionThread: Thread?
    /// prepare 里做过的预热帧数（0 或 1）与预热帧的 gpuStart − 提交 延迟（W1-B3；测试 / 报告看）。
    private(set) var warmupFrames = 0
    private(set) var warmupGpuStartLatency: HostDuration = .zero

    public init(device: (any MTLDevice)? = nil, options: MetalRendererOptions = MetalRendererOptions()) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = dev
        guard let q = dev.makeCommandQueue() else { throw RenderError.resource("建不出命令队列") }
        q.label = "switcher.render"
        commandQueue = q
        self.options = options
    }

    deinit {
        shutdown()
    }

    // MARK: - Renderer

    public func prepare(format: ProgramFormat, maxInputs: Int) throws {
        shutdown()
        let res = try RenderResources.shared(for: device)
        var newSlots: [RenderSlot] = []
        for i in 0..<max(2, options.slotCount) {
            let targets = try RenderTargets(device: device, width: format.width, height: format.height, label: "slot\(i)")
            newSlots.append(RenderSlot(index: i, targets: targets, maxInputs: max(1, maxInputs)))
        }
        // 输入：每路最多约 8 个池缓冲 × 2 平面；输出环的纹理 W3-B2 起在建环时包好、不进这张表，余量留给环被占满时退回池子的缓冲
        let tbl = SurfaceTextureTable(device: device, capacity: max(1, maxInputs) * 16 + options.outputRingSize * 2 + 8)
        let rng = try OutputBufferRing(width: format.width, height: format.height, count: options.outputRingSize, device: device)
        // PVW / 多画面的 NV12 环（W3-B2 可选项）：强制开的在这里建；其余等渲染线程第一次看到状态要它时由后台线程建。
        // P3 时两个环总是在这里建（prepare 时没有状态、渲染线程又不许分配），没有这类输出时 1080p / ringSize 8 各白占约 25 MB
        var eager: [AuxOutputRings.Kind] = []
        if options.previewOutput { eager.append(.preview) }
        if options.multiview && options.multiviewOutput { eager.append(.multiview) }
        let aux = try AuxOutputRings(device: device, width: format.width, height: format.height, count: options.outputRingSize, eager: eager)
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
        frameDuration = TickClockSpec(t0: .zero, frameRate: format.frameRate).duration(ofTicks: 1)
        stopping.store(false, ordering: .releasing)
        inflight.store(0, ordering: .releasing)
        submitted.store(0, ordering: .releasing)
        completed.store(0, ordering: .releasing)
        latestCompletedSlot.store(-1, ordering: .releasing)
        stateLock.unlock()
        lbl.start()
        aux.start()
        let t = Thread { [self] in completionLoop() }
        t.name = "switcher.render.completion"
        t.qualityOfService = .userInteractive
        completionThread = t
        t.start()
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
        if completionThread != nil {
            finished.wait()
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
            let gpuStart = HostTime(nanoseconds: UInt64(max(0, cb.gpuStartTime) * 1e9))
            let gpuEnd = HostTime(nanoseconds: UInt64(max(0, cb.gpuEndTime) * 1e9))
            let tick = slot.tick, tickTime = slot.tickTime, submitTime = slot.submitTime
            let previewBuffer = slot.previewBuffer, multiviewBuffer = slot.multiviewBuffer
            // 先放资源、放行渲染线程，再派发
            slot.releaseFrame()
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

    // MARK: - 给测试 / 报告看的计数

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

    /// 预热后应为 0：稳态每个 IOSurface 都命中。W3-B2 起输出环的纹理不进这张表（建环时包好），这里只剩输入。
    var textureCreateCount: Int { table?.createCount ?? 0 }
    /// 环里没空闲缓冲、退回池子分配的次数；稳态应为 0。
    var outputFallbackCount: Int { ring?.fallbackCount ?? 0 }
    /// 当前节目格式。
    public var preparedFormat: ProgramFormat? { stateLock.lock(); defer { stateLock.unlock() }; return format }
}
