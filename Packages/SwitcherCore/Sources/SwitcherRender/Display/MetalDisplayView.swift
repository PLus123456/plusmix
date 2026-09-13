// 显示与渲染解耦（设计方案 §3.3、决策 2）：渲染线程只画离屏纹理；每个显示视图用 NSView.displayLink(target:selector:)
// 按自己所在显示器的刷新率，把"最新完成的纹理"画到自己的 CAMetalLayer。渲染线程永远不碰 drawable。
// 不用 CVDisplayLink（macOS 15 起弃用）。W2-B 在这个文件上继续完善（docs/OWNERSHIP.md 允许）。
@preconcurrency import Metal
import AppKit
import QuartzCore
import SwitcherContracts

@MainActor
public final class MetalDisplayView: NSView {
    /// 从哪里拿纹理。
    public weak var source: (any DisplayFrameSource)? {
        didSet {
            pipeline = nil
            lastVersion = 0
            if let source { metalLayer.device = source.displayCommandQueue.device }   // drawable 必须和 blit 用的队列同一台设备
        }
    }
    /// 显示 PGM / PVW / 多画面。
    public var target: DisplayTarget = .program {
        didSet { lastVersion = 0 }
    }
    /// 刷新率上限（fps）；nil = 跟显示器。缩略图用 15–30。
    public var maxFramesPerSecond: Int? {
        didSet { applyFrameRateRange() }
    }
    /// 统计：实际 blit 了多少帧、display link 触发了多少次（测试看刷新率上限用）。
    public private(set) var presentedFrames: UInt64 = 0
    public private(set) var linkCallbacks: UInt64 = 0
    /// 每次没画的原因计数（调试用）。
    public struct SkipCounters: Sendable {
        public var notVisible: UInt64 = 0
        public var noFrame: UInt64 = 0
        public var sameVersion: UInt64 = 0
        public var noDrawable: UInt64 = 0
    }
    public private(set) var skipCounters = SkipCounters()

    private let metalLayer = CAMetalLayer()
    private var link: CADisplayLink?
    private var lastVersion: UInt64 = 0
    private var pipeline: (any MTLRenderPipelineState)?
    private var pipelineQueue: ObjectIdentifier?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        metalLayer.pixelFormat = RenderResources.workingFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // 主线程拿 drawable 允许等（这是显示线程，不是渲染线程）；但预览掉帧比卡主线程好，所以不等太久
        metalLayer.allowsNextDrawableTimeout = true
        layer = metalLayer
        layerContentsRedrawPolicy = .never
    }

    public override var wantsUpdateLayer: Bool { true }
    public override func makeBackingLayer() -> CALayer { metalLayer }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard let window else { return }
        metalLayer.device = source?.displayCommandQueue.device ?? MTLCreateSystemDefaultDevice()
        metalLayer.contentsScale = window.backingScaleFactor
        updateDrawableSize()
        let l = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRateRange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { metalLayer.contentsScale = window.backingScaleFactor }
        updateDrawableSize()
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            lastVersion = 0   // 尺寸变了要重画
        }
    }

    private func applyFrameRateRange() {
        guard let link else { return }
        if let fps = maxFramesPerSecond, fps > 0 {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 10)), maximum: Float(fps), preferred: Float(fps))
        } else {
            link.preferredFrameRateRange = .default
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        linkCallbacks &+= 1
        // 被遮住 / 最小化：不画（display link 本身也会暂停，这里再兜一层）
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { skipCounters.notVisible &+= 1; return }
        guard let source, let frame = source.latestDisplayFrame(for: target) else { skipCounters.noFrame &+= 1; return }
        if frame.version == lastVersion { skipCounters.sameVersion &+= 1; return }   // 没有新帧就不重复 blit
        guard let drawable = metalLayer.nextDrawable() else { skipCounters.noDrawable &+= 1; return }
        let queue = source.displayCommandQueue
        guard let pso = pipelineState(for: queue) else { return }
        guard let cb = queue.makeCommandBuffer() else { return }
        cb.label = "switcher.display"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = DrawUniforms()
        let dw = drawable.texture.width, dh = drawable.texture.height
        Placement.fillTexture(&u, textureWidth: frame.texture.width, textureHeight: frame.texture.height,
                              dest: PixelRect(x: 0, y: 0, width: Float(dw), height: Float(dh)), targetWidth: dw, targetHeight: dh)
        u.format = DrawFormat.bgra.rawValue
        enc.setRenderPipelineState(pso)
        enc.setFragmentTexture(frame.texture, index: 0)
        enc.setFragmentTexture(frame.texture, index: 1)
        enc.setFragmentTexture(frame.texture, index: 2)
        enc.setFragmentTexture(frame.texture, index: 3)
        withUnsafeBytes(of: &u) { raw in
            enc.setVertexBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
            enc.setFragmentBytes(raw.baseAddress!, length: DrawUniforms.expectedStride, index: 0)
        }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        lastVersion = frame.version
        presentedFrames &+= 1
    }

    /// 显示用的管线状态（和合成用同一份着色器，目标格式同为 bgra8Unorm）；按队列的设备缓存一份。
    private func pipelineState(for queue: any MTLCommandQueue) -> (any MTLRenderPipelineState)? {
        if let pipeline, pipelineQueue == ObjectIdentifier(queue) { return pipeline }
        guard let resources = try? RenderResources.shared(for: queue.device) else { return nil }
        pipeline = resources.quadOpaque
        pipelineQueue = ObjectIdentifier(queue)
        return pipeline
    }

    deinit {
        // NSView 的 deinit 在主线程；display link 随视图失效
    }
}
