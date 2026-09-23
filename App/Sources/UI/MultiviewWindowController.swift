// 多画面独立窗口（W3-C 交付 5）：一个 MetalDisplayView（target = .multiview，跟显示器刷新率），16:9，可拖到任何显示器 / 全屏；
// 窗口位置记在 Show.layout["multiviewWindowFrame"]。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class MultiviewWindowController: NSWindowController {
    let displayView = MetalDisplayView(frame: .zero)
    static let layoutKey = "multiviewWindowFrame"

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
        displayView.source = source
        window.contentView = displayView
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var source: (any DisplayFrameSource)? {
        get { displayView.source }
        set { displayView.source = newValue }
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    var isShowing: Bool { window?.isVisible ?? false }

    func toggle() {
        if isShowing { window?.orderOut(nil) } else { show() }
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
