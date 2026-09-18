// 显示与渲染解耦（设计方案 §3.3、决策 2）：渲染线程只画离屏纹理；每个显示视图用 NSView.displayLink(target:selector:)
// 按自己所在显示器的刷新率，把"最新完成的纹理"画到自己的 CAMetalLayer。渲染线程永远不碰 drawable。
// 不用 CVDisplayLink（macOS 15 起弃用）。
//
// W2-B 在 W1-C 的版本上补的（探针结论见 reports/w2-app.md §5）：
// - 刷新率上限 `maxFramesPerSecond` 除了 preferredFrameRateRange（ProMotion 屏真会降到 24 Hz）之外，再按 host time 卡一道：
//   固定 60 Hz 的外接屏不理会 preferredFrameRateRange，回调仍是 60 Hz，只靠它缩略图会画到 60 fps。
// - 窗口被完全遮住时 display link 自己不停（探针：遮挡后仍 120 Hz 回调，只有最小化 / orderOut 才停），这里按
//   occlusionState 主动 `isPaused`，遮挡期间连回调都没有；隐藏、滚出可见区域同理。
// - `sourceRect`：只画纹理的一块（输入缩略图 = 多画面纹理里对应的格子，见 MetalDisplayView+Multiview.swift）。
// - 每次 blit 打一个 os_signpost 事件（subsystem app.switcher.display），Instruments 里能数缩略图实际刷新率。
@preconcurrency import Metal
import AppKit
import QuartzCore
import os
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
    /// 只画纹理的这一块（0–1 归一化，原点左上）；默认整张。缩略图用它切多画面的格子。
    public var sourceRect: NormalizedRect = .full {
        didSet {
            if sourceRect != oldValue { lastVersion = 0 }
        }
    }
    /// 刷新率上限（fps）；nil = 跟显示器。缩略图用 24。
    public var maxFramesPerSecond: Int? {
        didSet {
            applyFrameRateRange()
            minPresentInterval = maxFramesPerSecond.map { fps in
                // 允许比理论间隔早 1 ms 画：120 Hz 屏上 5 次回调 = 41.67 ms 对 24 fps 的 41.67 ms，不留余量会被舍入抖掉一半
                HostDuration(seconds: 1 / Double(max(fps, 1))) - HostDuration(milliseconds: 1)
            }
        }
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
        /// 被 maxFramesPerSecond 的 host time 闸门拦下的次数。
        public var rateLimited: UInt64 = 0
    }
    public private(set) var skipCounters = SkipCounters()
    /// display link 现在是否被本视图主动暂停（遮挡 / 隐藏）。
    public var isLinkPaused: Bool { link?.isPaused ?? true }
    /// 所在显示器的刷新率上限（Hz）；不在窗口里为 nil。
    public var screenMaximumFramesPerSecond: Int? { window?.screen?.maximumFramesPerSecond }

    private let metalLayer = CAMetalLayer()
    private var link: CADisplayLink?
    private var lastVersion: UInt64 = 0
    private var lastPresent = HostTime.zero
    private var minPresentInterval: HostDuration?
    private var pipeline: (any MTLRenderPipelineState)?
    private var pipelineQueue: ObjectIdentifier?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var screenObserver: (any NSObjectProtocol)?

    /// Instruments 里按 subsystem 过滤：app.switcher.display，事件名 present-pgm / present-pvw / present-mv。
    nonisolated static let signpostLog = OSLog(subsystem: "app.switcher.display", category: .pointsOfInterest)

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

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        removeWindowObservers()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard let window else { return }
        metalLayer.device = source?.displayCommandQueue.device ?? MTLCreateSystemDefaultDevice()
        metalLayer.contentsScale = window.backingScaleFactor
        updateDrawableSize()
        // NSView.displayLink 跟着视图所在窗口的显示器走（换屏自动换刷新率），窗口最小化 / orderOut 时自己停
        let l = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRateRange()
        let center = NotificationCenter.default
        occlusionObserver = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePause() }
        }
        screenObserver = center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenDidChange() }
        }
        updatePause()
    }

    private func removeWindowObservers() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        occlusionObserver = nil
        screenObserver = nil
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updatePause()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePause()
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

    /// 窗口换了显示器：backing scale 可能变了；刷新率由 NSView.displayLink 自己跟。
    private func screenDidChange() {
        if let window { metalLayer.contentsScale = window.backingScaleFactor }
        updateDrawableSize()
        lastVersion = 0
    }

    /// 遮挡 / 隐藏 → 暂停 display link（不只是不画，连回调都省掉）；可见 → 恢复并立刻补画一帧。
    private func updatePause() {
        guard let link else { return }
        let visible = (window?.occlusionState.contains(.visible) ?? false) && !isHiddenOrHasHiddenAncestor
        if link.isPaused == visible {
            link.isPaused = !visible
            if visible { lastVersion = 0 }
        }
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
        // 被遮住 / 最小化 / 隐藏 / 滚出可见区：不画（display link 已按 updatePause 暂停，这里再兜一层）
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
            skipCounters.notVisible &+= 1
            return
        }
        guard let source, let frame = source.latestDisplayFrame(for: target) else { skipCounters.noFrame &+= 1; return }
        if frame.version == lastVersion { skipCounters.sameVersion &+= 1; return }   // 没有新帧就不重复 blit
        let now = HostClock.now()
        if let minPresentInterval, now - lastPresent < minPresentInterval { skipCounters.rateLimited &+= 1; return }
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
        let r = sourceRect
        let crop = CropInsets(left: r.x, top: r.y, right: max(0, 1 - r.x - r.width), bottom: max(0, 1 - r.y - r.height))
        Placement.fill(&u, sourceWidth: frame.texture.width, sourceHeight: frame.texture.height, crop: crop, transform: .identity,
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
        lastPresent = now
        presentedFrames &+= 1
        if MetalDisplayView.signpostLog.signpostsEnabled {
            switch target {
            case .program: os_signpost(.event, log: MetalDisplayView.signpostLog, name: "present-pgm")
            case .preview: os_signpost(.event, log: MetalDisplayView.signpostLog, name: "present-pvw")
            case .multiview: os_signpost(.event, log: MetalDisplayView.signpostLog, name: "present-mv")
            }
        }
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
        // NSView 的 deinit 在主线程；display link 随视图失效。通知观察者在 viewWillMove(toWindow: nil) 时已摘掉
    }
}
