import AppKit
import SwitcherContracts
import SwitcherRender

/// 一块显示器上的全屏输出窗口（设计方案 §8 外部显示行）：无边框、盖满该显示器、黑底，里面一个 `MetalDisplayView`
/// 按该显示器自己的刷新率 blit "最新完成的纹理"（§3.3：渲染线程不碰 drawable，所以拖主窗口、这块屏 60 Hz 主屏 120 Hz 都不影响渲染）。
/// 源：PGM / PVW / 多画面直接对应显示视图的 target；某路输入（Aux）取多画面纹理里它的格子（`MultiviewLayout.inputCell`），
/// 分辨率是格子的（1080p 多画面里约 470×260），全分辨率的 Aux 要渲染器给每路一张纹理（W3-B / W1-C 的活，见报告 §4）。
/// 显示器插拔：`screensDidChange()` 重新找目标屏；不在就收起（或按 `fallbackToMain` 退到主屏），回来了放回去。
/// Esc 关窗口（关 = 组装方收到 `onCloseRequested`，把对应输出删掉；窗口本身由管理器按快照增删）。
@MainActor
public final class ExternalDisplayWindow: NSWindowController {
    /// 窗口现在在哪。
    public enum Status: Hashable, Sendable {
        /// 在目标显示器上全屏。
        case showing(displayID: UInt32)
        /// 目标显示器不在，窗口收起等它回来。
        case waitingForDisplay(displayID: UInt32)
        /// 目标显示器不在，退到主显示器。
        case fallbackToMain(displayID: UInt32)
    }

    public let displayView = MetalDisplayView(frame: .zero)
    public private(set) var spec: ExternalDisplaySpec
    public private(set) var status: Status
    /// 纹理来源。
    public var source: (any DisplayFrameSource)? {
        didSet { displayView.source = source }
    }
    /// 用户按 Esc / 关窗口时回调（组装方删输出）。
    public var onCloseRequested: (() -> Void)?
    /// 状态变化回调。
    public var onStatusChange: ((Status) -> Void)?
    /// Aux 源找不到那路输入（被删了）时显示视图隐藏：true = 现在画黑。
    public private(set) var auxUnresolved = false

    private var inputs: [InputConfig] = []
    private var textureWidth = 1920
    private var textureHeight = 1080

    /// 全屏输出用的窗口：能成 key（收 Esc），不进窗口循环。
    private final class OutputWindow: NSWindow {
        var onKey: ((NSEvent) -> Bool)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }

    public init(spec: ExternalDisplaySpec, source: (any DisplayFrameSource)?, inputs: [InputConfig] = [], textureWidth: Int = 1920, textureHeight: Int = 1080) {
        self.spec = spec
        self.source = source
        self.inputs = inputs
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        status = .waitingForDisplay(displayID: spec.displayID ?? 0)
        let window = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
        window.title = "Switcher 外部输出"
        displayView.source = source
        window.contentView = displayView
        super.init(window: window)
        window.onKey = { [weak self] event in
            guard event.keyCode == 53 else { return false }   // Esc
            self?.onCloseRequested?()
            return true
        }
        applySource()
        place()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("不支持 coder") }

    /// 换设置（显示器 / 源 / 退回策略）。
    public func update(spec: ExternalDisplaySpec) {
        guard spec != self.spec else { return }
        self.spec = spec
        applySource()
        place()
    }

    /// 输入表 / 纹理尺寸变了（Aux 格子随输入顺序和多画面尺寸变）。
    public func apply(inputs: [InputConfig], textureWidth: Int, textureHeight: Int) {
        self.inputs = inputs
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        applySource()
    }

    /// 显示器接上 / 拔掉 / 换分辨率之后调（管理器观察 NSApplication.didChangeScreenParametersNotification）。
    public func screensDidChange() { place() }

    /// 关掉窗口（管理器在输出被删时调）。
    public func closeOutput() {
        window?.orderOut(nil)
        displayView.source = nil
        close()
    }

    /// 窗口在屏上可见。
    public var isShowing: Bool { window?.isVisible ?? false }

    // MARK: 内部

    private func applySource() {
        switch spec.source {
        case .program:
            displayView.target = .program
            displayView.sourceRect = .full
            setAuxUnresolved(false)
        case .preview:
            displayView.target = .preview
            displayView.sourceRect = .full
            setAuxUnresolved(false)
        case .multiview:
            displayView.target = .multiview
            displayView.sourceRect = .full
            setAuxUnresolved(false)
        case .input(let number):
            displayView.target = .multiview
            if let index = inputs.firstIndex(where: { $0.number == number }),
               let cell = MultiviewLayout.inputCell(index: index, inputCount: inputs.count, width: textureWidth, height: textureHeight) {
                displayView.sourceRect = cell
                setAuxUnresolved(false)
            } else {
                displayView.sourceRect = .full
                setAuxUnresolved(true)
            }
        }
    }

    private func setAuxUnresolved(_ unresolved: Bool) {
        auxUnresolved = unresolved
        displayView.isHidden = unresolved
    }

    /// 找目标屏、盖满它；不在就收起或退到主屏。
    private func place() {
        guard let window else { return }
        let wanted = spec.displayID
        let newStatus: Status
        var screen = ExternalDisplays.screen(for: wanted)
        if screen != nil {
            newStatus = .showing(displayID: wanted ?? screen.map(ExternalDisplays.id(of:)) ?? 0)
        } else if spec.fallbackToMain, let main = NSScreen.main {
            screen = main
            newStatus = .fallbackToMain(displayID: wanted ?? 0)
        } else {
            newStatus = .waitingForDisplay(displayID: wanted ?? 0)
        }
        if let screen {
            if window.frame != screen.frame || window.screen != screen { window.setFrame(screen.frame, display: true) }
            if !window.isVisible { window.orderFront(nil) }
        } else if window.isVisible {
            window.orderOut(nil)
        }
        if newStatus != status {
            status = newStatus
            onStatusChange?(newStatus)
        }
    }
}
