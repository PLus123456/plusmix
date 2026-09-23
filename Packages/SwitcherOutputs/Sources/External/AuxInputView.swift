@preconcurrency import Metal
import AppKit
import QuartzCore
import os
import SwitcherContracts

/// Aux 窗口的内容视图：自己的 CAMetalLayer + `NSView.displayLink`（按所在显示器的刷新率回调，不用弃用的 CVDisplayLink），
/// 每次回调让 `AuxInputPresenter` 从帧槽取该路最新帧、全幅画进 drawable。渲染线程完全不参与（G4 裁定：不给渲染线程加每路全分辨率目标）。
/// 暂停规则与 MetalDisplayView 相同：被遮住 / 隐藏 / 窗口收起时暂停 display link，那段时间帧槽里挤掉的帧记 undelivered（提案 018，不算 dropped），
/// 恢复时补画一帧。
@MainActor
public final class AuxInputView: NSView {
    public let presenter: AuxInputPresenter
    /// 该路输入的运行状态（组装方给：App 的 InputRuntime.runtimeState）；nil = presenter 只看帧新不新。每次刷新读一次。
    public var inputStateProvider: (@MainActor (Int) -> InputState?)?
    /// display link 回调了多少次（测试看）。
    public private(set) var linkCallbacks: UInt64 = 0
    /// display link 现在是否被本视图主动暂停（遮挡 / 隐藏）。
    public var isLinkPaused: Bool { link?.isPaused ?? true }
    /// drawable 的像素尺寸（= 视图尺寸 × 所在屏的 backing scale）。
    public var drawableSize: CGSize { metalLayer.drawableSize }

    public var presentedFrames: UInt64 { presenter.presentedFrames }
    public var droppedFrames: UInt64 { presenter.droppedFrames }
    public var undeliveredFrames: UInt64 { presenter.undeliveredFrames }

    private let metalLayer = CAMetalLayer()
    private let queue: any MTLCommandQueue
    private var link: CADisplayLink?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var screenObserver: (any NSObjectProtocol)?

    /// Instruments：subsystem app.switcher.display，事件名 present-aux（与 MetalDisplayView 的 present-pgm 等同一个 log）。
    nonisolated static let signpostLog = OSLog(subsystem: "app.switcher.display", category: .pointsOfInterest)

    /// device 为 nil 用系统默认设备（Apple Silicon 只有一块 GPU，与渲染器同一台）。
    public init(device: (any MTLDevice)? = nil) {
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        presenter = AuxInputPresenter(device: dev)
        queue = dev.makeCommandQueue()!
        queue.label = "switcher.aux"
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = dev
        metalLayer.pixelFormat = AuxPipeline.targetFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        metalLayer.allowsNextDrawableTimeout = true
        layer = metalLayer
        layerContentsRedrawPolicy = .never
        AuxPipeline.prepare(for: dev)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("不支持 coder") }

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
        metalLayer.contentsScale = window.backingScaleFactor
        updateDrawableSize()
        let l = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        l.add(to: .main, forMode: .common)
        link = l
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

    private func screenDidChange() {
        if let window { metalLayer.contentsScale = window.backingScaleFactor }
        updateDrawableSize()
        presenter.setNeedsRedraw()
    }

    /// 遮挡 / 隐藏 → 暂停（这段帧槽里挤掉的帧记 undelivered，不记 dropped）；可见 → 恢复并补画当前内容。
    private func updatePause() {
        guard let link else { return }
        let visible = (window?.occlusionState.contains(.visible) ?? false) && !isHiddenOrHasHiddenAncestor
        if link.isPaused == visible {
            link.isPaused = !visible
            if visible { presenter.setNeedsRedraw() } else { presenter.pauseDelivery() }
        }
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            presenter.setNeedsRedraw()   // 尺寸变了：重画（占位的字也按新尺寸重排），记账不断
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        linkCallbacks &+= 1
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        // 管线在后台编；没编好之前不取帧（取了画不出来会被记成丢帧）
        guard AuxPipeline.cached(for: presenter.device) != nil else {
            AuxPipeline.prepare(for: presenter.device)
            return
        }
        if let provider = inputStateProvider, let n = presenter.input { presenter.inputState = provider(n) }
        let size = metalLayer.drawableSize
        let draw = presenter.nextDraw(now: HostClock.now(), targetWidth: Int(size.width), targetHeight: Int(size.height))
        if case .nothing = draw { return }
        guard let drawable = metalLayer.nextDrawable(), let cb = queue.makeCommandBuffer() else {
            presenter.didNotPresent(draw)
            return
        }
        cb.label = "aux"
        guard presenter.encode(draw, into: drawable.texture, commandBuffer: cb) else {
            presenter.didNotPresent(draw)
            return
        }
        cb.present(drawable)
        cb.commit()
        presenter.didPresent(draw)
        if case .frame = draw, AuxInputView.signpostLog.signpostsEnabled {
            os_signpost(.event, log: AuxInputView.signpostLog, name: "present-aux")
        }
    }
}
