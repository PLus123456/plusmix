import AppKit
import SwitcherContracts
import SwitcherRender

/// 一块显示器上的全屏输出窗口（设计方案 §8 外部显示行）：无边框、盖满该显示器、黑底。
/// - PGM / PVW / 多画面：`MetalDisplayView` 按该显示器自己的刷新率 blit "最新完成的纹理"（§3.3：渲染线程不碰 drawable，
///   所以拖主窗口、这块屏 60 Hz 主屏 120 Hz 都不影响渲染）。数据源夹一层 `DisplayFrameLedger` 记"没赶上刷新"的帧。
/// - 某路输入（Aux，W3-C2）：`AuxInputView` 每次显示刷新从该路的帧槽分支（组装方经 `auxFrames` 给）取最新帧，全分辨率画——
///   不再用多画面纹理里它的格子。Aux = 原始画面：抠像 / 裁切 / 变换不生效。输入无信号 / 没接上画占位。
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

    /// 窗口开在主屏（带菜单栏的那块）上时的层级（包内选项，不进 `OutputSettings.display`；W3-C 报告 §3 第 5 条）。
    public enum MainScreenLayering: Hashable, Sendable {
        /// 默认（W3-C 起的行为不变）：普通层级、在最前，盖住主屏上的界面。
        case front
        /// 垫在普通窗口下面（层级 normal − 1）：主界面和别的 App 的窗口都在它上面，点它也不会翻上来；界面没盖住的地方看得见它。
        /// 只影响主屏，外接屏上照常。
        case behindInterface
    }

    /// 垫在普通窗口下面用的层级。
    public static let behindInterfaceLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)

    /// 窗口标题的默认值（全屏无边框，平时看不见；Mission Control / 窗口菜单里看得见）。包里非有不可的文字用 ASCII，
    /// 组装方传本地化后的（`windowTitle` / 管理器的 `windowTitle`；W3-C3）。
    public static let defaultWindowTitle = "Switcher External Output"

    public let displayView = MetalDisplayView(frame: .zero)
    public let auxView: AuxInputView
    public private(set) var spec: ExternalDisplaySpec
    public private(set) var status: Status
    /// 纹理来源（PGM / PVW / 多画面）。
    public var source: (any DisplayFrameSource)? {
        didSet { rebuildLedger() }
    }
    /// Aux 的帧来源（组装方开 / 还帧槽分支）；nil = Aux 画占位。
    public var auxFrames: AuxFrameTap? {
        didSet {
            releaseAuxSlot()
            applySource()
        }
    }
    /// Aux 那路输入的运行状态（组装方给）；nil = 只看帧新不新。
    public var inputStateProvider: (@MainActor (Int) -> InputState?)? {
        didSet { auxView.inputStateProvider = inputStateProvider }
    }
    /// Aux 占位的"无信号"文案。
    public var noSignalText: String {
        get { auxView.presenter.noSignalText }
        set { auxView.presenter.noSignalText = newValue }
    }
    /// 开在主屏上时的层级。
    public var mainScreenLayering: MainScreenLayering = .front {
        didSet {
            if mainScreenLayering != oldValue { place(reorder: true) }
        }
    }
    /// 窗口标题（组装方给本地化后的；默认 `defaultWindowTitle`）。
    public var windowTitle: String {
        didSet { window?.title = windowTitle }
    }
    /// 用户按 Esc / 关窗口时回调（组装方删输出）。
    public var onCloseRequested: (() -> Void)?
    /// 状态变化回调。
    public var onStatusChange: ((Status) -> Void)?
    /// Aux 源找不到那路输入（被删了）：true = 画占位、没有帧槽。
    public private(set) var auxUnresolved = false

    /// 累计呈现的帧：显示视图（PGM / PVW / 多画面）+ Aux 视图，换源不清零。
    public var presentedFrames: UInt64 { displayView.presentedFrames &+ auxView.presentedFrames }
    /// 累计"没赶上显示刷新的帧"（提案 013 的 dropped）：记账源 + Aux，换源 / 换渲染器不清零。
    public var droppedFrames: UInt64 { retiredLedgerDropped &+ (ledger?.droppedFrames ?? 0) &+ auxView.droppedFrames }
    /// 累计"不在呈现时没送出去的帧"（提案 018 的 undelivered）：窗口收起（目标显示器不在）/ 被遮住期间当前源出的帧；换源那段不算。
    public var undeliveredFrames: UInt64 { retiredLedgerUndelivered &+ (ledger?.undeliveredFrames ?? 0) &+ auxView.undeliveredFrames }

    private var inputs: [InputConfig] = []
    private var ledger: DisplayFrameLedger?
    private var retiredLedgerDropped: UInt64 = 0
    private var retiredLedgerUndelivered: UInt64 = 0
    /// Aux 现在拿着的帧槽分支（哪一路、那路当时的来源、怎么还）。
    private var auxSlot: (input: Int, source: InputSource, slot: any FrameSlot, close: @MainActor (Int, any FrameSlot) -> Void)?
    nonisolated(unsafe) private var occlusionObserver: (any NSObjectProtocol)?

    /// 全屏输出用的窗口：能成 key（收 Esc），不进窗口循环。
    private final class OutputWindow: NSWindow {
        var onKey: ((NSEvent) -> Bool)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }

    /// textureWidth / textureHeight：G4 时 Aux 取多画面格子要用；W3-C2 起 Aux 自己画输入帧，不再用，参数留着兼容调用方。
    public init(spec: ExternalDisplaySpec, source: (any DisplayFrameSource)?, inputs: [InputConfig] = [], textureWidth: Int = 1920, textureHeight: Int = 1080,
                auxFrames: AuxFrameTap? = nil, mainScreenLayering: MainScreenLayering = .front, windowTitle: String = ExternalDisplayWindow.defaultWindowTitle) {
        self.spec = spec
        self.source = source
        self.inputs = inputs
        self.auxFrames = auxFrames
        self.mainScreenLayering = mainScreenLayering
        self.windowTitle = windowTitle
        auxView = AuxInputView()
        status = .waitingForDisplay(displayID: spec.displayID ?? 0)
        let window = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
        window.title = windowTitle
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        for v in [displayView, auxView] as [NSView] {
            v.frame = container.bounds
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
        }
        auxView.isHidden = true
        window.contentView = container
        super.init(window: window)
        rebuildLedger()
        window.onKey = { [weak self] event in
            guard event.keyCode == 53 else { return false }   // Esc
            self?.onCloseRequested?()
            return true
        }
        // 遮挡变化（收起 / 放回 / 被盖住）：记账源断开，这段记 undelivered（MetalDisplayView 自己会暂停 / 恢复 display link；Aux 视图自己记）
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityBreak() }
        }
        applySource()
        place(reorder: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// 换设置（显示器 / 源 / 退回策略）。
    public func update(spec: ExternalDisplaySpec) {
        guard spec != self.spec else { return }
        self.spec = spec
        applySource()
        place(reorder: false)
    }

    /// 输入表变了（Aux 那路被删 / 改名 / 换来源）。纹理尺寸参数不再用（见 init）。
    public func apply(inputs: [InputConfig], textureWidth: Int, textureHeight: Int) {
        self.inputs = inputs
        applySource()
    }

    /// 显示器接上 / 拔掉 / 换分辨率之后调（管理器观察 NSApplication.didChangeScreenParametersNotification）。
    public func screensDidChange() { place(reorder: false) }

    /// 关掉窗口（管理器在输出被删时调）：还掉 Aux 的帧槽分支。
    public func closeOutput() {
        window?.orderOut(nil)
        releaseAuxSlot()
        auxView.presenter.detach()
        displayView.source = nil
        close()
    }

    /// 窗口在屏上可见。
    public var isShowing: Bool { window?.isVisible ?? false }

    // MARK: 内部

    /// 窗口收起 / 放回 / 遮挡变化：显示视图在用时这段记 undelivered；Aux 时显示视图本来就收着，只断开不记（不是这个源）。
    private func visibilityBreak() {
        ledger?.breakRun(countingUndelivered: !displayView.isHidden)
    }

    /// 记账源包住渲染器，交给显示视图（显示视图对来源是弱引用，记账源由窗口持有）。换渲染器时旧账并进 retired，累计值不回退。
    private func rebuildLedger() {
        retiredLedgerDropped &+= ledger?.droppedFrames ?? 0
        retiredLedgerUndelivered &+= ledger?.undeliveredFrames ?? 0
        if let source {
            let l = DisplayFrameLedger(upstream: source, view: displayView)
            ledger = l
            displayView.source = l
        } else {
            ledger = nil
            displayView.source = nil
        }
    }

    private func applySource() {
        switch spec.source {
        case .program: showDisplayView(.program)
        case .preview: showDisplayView(.preview)
        case .multiview: showDisplayView(.multiview)
        case .input(let number):
            if !displayView.isHidden { ledger?.breakRun() }   // 换源：显示视图收起的这段不是它的源，不记
            displayView.isHidden = true
            auxView.isHidden = false
            if let config = inputs.first(where: { $0.number == number }) {
                auxUnresolved = false
                attachAux(config)
            } else {
                releaseAuxSlot()
                auxView.presenter.attach(input: number, name: "", slot: nil)
                auxUnresolved = true
            }
        }
    }

    private func showDisplayView(_ target: DisplayTarget) {
        releaseAuxSlot()
        auxView.presenter.detach()
        auxView.isHidden = true
        if displayView.target != target { displayView.target = target }
        displayView.sourceRect = .full
        if displayView.isHidden {
            displayView.isHidden = false
            ledger?.breakRun()   // 从 Aux 换回来：收着的那段不是这个源的，不记
        }
        auxUnresolved = false
    }

    /// Aux 绑到这一路：已经拿着这一路（来源没变）的分支就只更新名字；否则还掉旧的、开新的（开不到就画占位，下次快照再试）。
    private func attachAux(_ config: InputConfig) {
        if let held = auxSlot, held.input == config.number, held.source == config.source {
            auxView.presenter.attach(input: config.number, name: config.name, slot: held.slot)
            return
        }
        releaseAuxSlot()
        var slot: (any FrameSlot)?
        if let tap = auxFrames, let opened = tap.open(config.number) {
            auxSlot = (config.number, config.source, opened, tap.close)
            slot = opened
        }
        auxView.presenter.attach(input: config.number, name: config.name, slot: slot)
    }

    private func releaseAuxSlot() {
        guard let held = auxSlot else { return }
        auxSlot = nil
        held.close(held.input, held.slot)
    }

    /// 找目标屏、盖满它；不在就收起或退到主屏。reorder = 层级选项变了，要重新排前后。
    private func place(reorder: Bool) {
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
            let behind = mainScreenLayering == .behindInterface && screen == NSScreen.screens.first
            let level = behind ? Self.behindInterfaceLevel : .normal
            let levelChanged = window.level != level
            if levelChanged { window.level = level }
            if window.frame != screen.frame || window.screen != screen { window.setFrame(screen.frame, display: true) }
            if !window.isVisible || reorder || levelChanged {
                window.orderFront(nil)
                visibilityBreak()
            }
        } else if window.isVisible {
            window.orderOut(nil)
            visibilityBreak()
        }
        if newStatus != status {
            status = newStatus
            onStatusChange?(newStatus)
        }
    }
}
