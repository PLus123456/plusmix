// 多画面独立窗口（W3-C 交付 5）：一个 MetalDisplayView（target = .multiview，跟显示器刷新率），16:9，可拖到任何显示器 / 全屏；
// 窗口位置记在 Show.layout["multiviewWindowFrame"]。
// W3-E3：渲染器与显示视图之间夹一层 DisplayFrameLedger（W3-C2 的记账源，外部显示窗口同款），Stats.display[] 里 multiviewWindow 那一项的
// dropped（两次刷新之间被覆盖的版本）/ undelivered（开着但被遮住 / 最小化时渲染器出了、窗口没画的版本）都从它来；关着 = 不在呈现，两样都不记。
import AppKit
import SwitcherContracts
import SwitcherRender
import SwitcherExternal

@MainActor
final class MultiviewWindowController: NSWindowController {
    let displayView = MetalDisplayView(frame: .zero)
    static let layoutKey = "multiviewWindowFrame"
    /// 记账源（显示视图对来源是弱引用，由窗口持有）；没有来源为 nil。
    private(set) var ledger: DisplayFrameLedger?
    /// 换过来源（换 session = 换渲染器）之前的旧账，累计值不回退。
    private var retiredDropped: UInt64 = 0
    private var retiredUndelivered: UInt64 = 0
    /// 关着（还没开过、按了开关 / 关闭按钮）。最小化不算关：那是开着但暂停呈现（记 undelivered）。
    /// 不用 isVisible 判：最小化的窗口 isVisible 也是 false，遮挡通知与最小化通知的先后又不定。
    private var closed = true
    /// 开 / 关变了（底栏"多画面"主体按它高亮，W5-F / E3；点窗口自己的关闭按钮也算）。
    var onOpenChange: ((Bool) -> Void)?
    nonisolated(unsafe) private var windowObservers: [any NSObjectProtocol] = []

    init(source: (any DisplayFrameSource)?) {
        let size = NSSize(width: 960, height: 540)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("multiview.windowTitle")
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 480, height: 270)
        displayView.target = .multiview
        window.contentView = displayView
        super.init(window: window)
        self.source = source
        window.center()
        let center = NotificationCenter.default
        // 遮挡变化（被盖住 / 最小化 / 收起 / 露出来）：断开连续呈现（MetalDisplayView 自己暂停 / 恢复 display link）
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityBreak() }
        })
        // 点关闭按钮 = 关（isReleasedWhenClosed = false，只是收起）
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markClosed() }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
    }

    /// 纹理来源（换 session 时换）：记账源包住它交给显示视图，旧账并进 retired。
    var source: (any DisplayFrameSource)? {
        get { ledger?.upstream }
        set {
            retiredDropped &+= ledger?.droppedFrames ?? 0
            retiredUndelivered &+= ledger?.undeliveredFrames ?? 0
            if let newValue {
                let l = DisplayFrameLedger(upstream: newValue, view: displayView)
                ledger = l
                displayView.source = l
            } else {
                ledger = nil
                displayView.source = nil
            }
        }
    }

    /// 累计"没赶上显示刷新的帧"（提案 013 的 dropped），换来源不清零。
    var droppedFrames: UInt64 { retiredDropped &+ (ledger?.droppedFrames ?? 0) }
    /// 累计"开着但不在呈现时没画的帧"（提案 018 的 undelivered），换来源不清零。
    var undeliveredFrames: UInt64 { retiredUndelivered &+ (ledger?.undeliveredFrames ?? 0) }

    func show() {
        closed = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        onOpenChange?(true)
    }

    var isShowing: Bool { window?.isVisible ?? false }

    /// 开着（在屏上，或最小化在 Dock 里）：Stats 里报 presenting；关着报 idle。
    var isOpen: Bool { !closed }

    func toggle() {
        if isShowing {
            markClosed()
            window?.orderOut(nil)
        } else {
            show()
        }
    }

    /// 关：不在呈现的输出没有该送的帧，关着的这段 dropped / undelivered 都不记（先断开再收起窗口，收起引起的遮挡变化也按"关着"处理）。
    private func markClosed() {
        closed = true
        ledger?.breakRun()
        onOpenChange?(false)
    }

    /// 遮挡变化：开着的窗口被遮住 / 最小化 / 又露出来 = 暂停呈现的边界，这段记 undelivered；关着不记。
    private func visibilityBreak() {
        ledger?.breakRun(countingUndelivered: !closed)
    }

    /// 从布局恢复位置。
    func restore(from layout: ShowLayout) {
        if case .string(let s)? = layout.values[Self.layoutKey], let window {
            let rect = NSRectFromString(s)
            if !rect.isEmpty { window.setFrame(rect, display: false) }
        }
    }

    /// 存位置进布局。
    func save(into values: inout [String: JSONValue]) {
        if let frame = window?.frame { values[Self.layoutKey] = .string(NSStringFromRect(frame)) }
    }
}
