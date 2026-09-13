// 实时合成引擎：实现 SwitcherContracts 的 Renderer 协议（CONTRACTS.md §7）。
//
// 线程模型（设计方案 §3.2、§3.3；CONTRACTS.md §6 T1–T3）：
// - render()：引擎的渲染线程每拍调一次。零分配（Swift 侧；Metal 内部每帧建命令缓冲区 / 编码器对象的分配不可避免，数字见报告）、
//   不等 drawable、不阻塞：GPU 还压着 maxInflight（默认 2）帧没完成就返回 .skipped。
// - 完成线程（switcher.render.completion）：按提交顺序 waitUntilCompleted，读 GPU 时间戳，组 RenderedFrame，调 sink。
//   不用 addCompletedHandler 是因为每帧的闭包 / block 都是堆分配。
// - 标签线程：见 LabelRenderer。
// - 显示视图（MetalDisplayView）在主线程从 latestDisplayFrame 拿"最新完成的纹理"，用同一个命令队列 blit，
//   同队列上 Metal 自动追踪读写冲突，所以三重缓冲 + 在途 ≤ 2 就够，不需要第四重。
@preconcurrency import Metal
import CoreVideo
import Foundation
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
    private var labels: LabelRenderer?
    private var format: ProgramFormat?
    private var frameDuration: HostDuration = .zero

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
        // 输入：每路最多约 8 个池缓冲 × 2 平面；输出环 × 2 平面
        let tbl = SurfaceTextureTable(device: device, capacity: max(1, maxInputs) * 16 + options.outputRingSize * 2 + 8)
        let rng = try OutputBufferRing(width: format.width, height: format.height, count: options.outputRingSize)
        let lbl = try LabelRenderer(device: device, slices: max(1, maxInputs),
                                    submittedFrames: { [weak self] in self?.submitted.load(ordering: .acquiring) ?? 0 },
                                    completedFrames: { [weak self] in self?.completed.load(ordering: .acquiring) ?? .max })
        stateLock.lock()
        resources = res
        slots = newSlots
        table = tbl
        ring = rng
        labels = lbl
        self.format = format
        frameDuration = TickClockSpec(t0: .zero, frameRate: format.frameRate).duration(ofTicks: 1)
        stopping.store(false, ordering: .releasing)
        inflight.store(0, ordering: .releasing)
        submitted.store(0, ordering: .releasing)
        completed.store(0, ordering: .releasing)
        latestCompletedSlot.store(-1, ordering: .releasing)
        stateLock.unlock()
        lbl.start()
        let t = Thread { [self] in completionLoop() }
        t.name = "switcher.render.completion"
        t.qualityOfService = .userInteractive
        completionThread = t
        t.start()
    }

    public func render(tick: Tick, at tickTime: HostTime, snapshot: MixerSnapshot, inputs: RenderInputTable) -> RenderVerdict {
        // Metal 的 makeCommandBuffer / make…Encoder 返回 autoreleased 对象；渲染线程若从不 drain，自动释放池每几百帧就新开一页（分配）。
        // 这里每拍 drain 一次（pop 只释放，不 malloc；线程的热页会被 objc 缓存复用）。W1-B 的渲染线程每拍也应包一层 autoreleasepool。
        autoreleasepool { renderInsidePool(tick: tick, at: tickTime, snapshot: snapshot, inputs: inputs) }
    }

    private func renderInsidePool(tick: Tick, at tickTime: HostTime, snapshot: MixerSnapshot, inputs: RenderInputTable) -> RenderVerdict {
        guard let resources, let table, let ring, let labels, !slots.isEmpty else { return .skipped }
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
        let labelSet = options.multiview ? labels.current : nil

        guard let output = ring.next(), let unmanaged = CVPixelBufferGetIOSurface(output) else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            RenderSignposts.event("skip-no-output-buffer")
            return .skipped
        }
        let surface = unmanaged.takeUnretainedValue()
        let width = slot.targets.width, height = slot.targets.height
        guard let luma = table.texture(surface: surface, plane: 0, format: .r8Uint, width: width, height: height,
                                       usage: .shaderWrite, frame: frameIndex),
              let chroma = table.texture(surface: surface, plane: 1, format: .rg8Uint, width: (width + 1) / 2, height: (height + 1) / 2,
                                         usage: .shaderWrite, frame: frameIndex),
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

        let context = CompositorPasses.Context(resources: resources, table: table, labels: labelSet, frameIndex: frameIndex)
        let state = snapshot.state
        CompositorPasses.encodeFrame(state: state, inputs: inputs, slot: slot, context: context, commandBuffer: cb,
                                     outputLuma: luma, outputChroma: chroma, multiview: options.multiview)

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

    public func shutdown() {
        guard completionThread != nil || resources != nil else { return }
        stopping.store(true, ordering: .releasing)
        pending.signal()
        if completionThread != nil {
            finished.wait()
            completionThread = nil
        }
        labels?.stop()
        stateLock.lock()
        resources = nil
        slots = []
        table = nil
        ring = nil
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
            // 先放资源、放行渲染线程，再派发
            slot.releaseFrame()
            latestCompletedSlot.store(slot.index, ordering: .releasing)
            completed.store(next + 1, ordering: .releasing)
            inflight.wrappingSubtract(1, ordering: .acquiringAndReleasing)
            let program = Frame(pixelBuffer: output, pts: tickTime, duration: frameDuration, color: .bt709Limited,
                                inputNumber: 0, sequence: next, ingressTime: gpuEnd)
            let frame = RenderedFrame(tick: tick, tickTime: tickTime, program: program, preview: nil, multiview: nil,
                                      submitTime: submitTime, gpuStart: gpuStart, gpuEnd: gpuEnd)
            if let sink { sink.renderer(self, didComplete: frame) }
            next += 1
        }
        finished.signal()
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

    /// 预热后应为 0：稳态每个 IOSurface 都命中。
    var textureCreateCount: Int { table?.createCount ?? 0 }
    /// 环里没空闲缓冲、退回池子分配的次数；稳态应为 0。
    var outputFallbackCount: Int { ring?.fallbackCount ?? 0 }
    /// 当前节目格式。
    public var preparedFormat: ProgramFormat? { stateLock.lock(); defer { stateLock.unlock() }; return format }
}
