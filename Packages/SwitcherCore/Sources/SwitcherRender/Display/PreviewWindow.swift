// 调试用预览窗口：一个 MetalDisplayView，按 1 / 2 / 3 切 PGM / PVW / 多画面。switcher-headless 的 --preview 用它（G2 接线）。
import AppKit
import SwitcherContracts

@MainActor
public final class PreviewWindow: NSWindowController {
    public let displayView: MetalDisplayView

    /// 建一个 16:9 的窗口。source 可以之后再设。
    public init(source: (any DisplayFrameSource)?, target: DisplayTarget = .program, title: String = "Switcher 预览",
                contentSize: NSSize = NSSize(width: 960, height: 540)) {
        let view = MetalDisplayView(frame: NSRect(origin: .zero, size: contentSize))
        view.source = source
        view.target = target
        displayView = view
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)   // 允许切全屏（显示解耦测试要切）
        super.init(window: window)
        window.center()
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("不支持 coder") }

    /// 显示并置前。
    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "1": displayView.target = .program
        case "2": displayView.target = .preview
        case "3": displayView.target = .multiview
        default: return false
        }
        window?.title = "Switcher 预览 — \(displayView.target)"
        return true
    }

    /// 能收键盘的窗口。
    private final class KeyWindow: NSWindow {
        var onKey: ((NSEvent) -> Bool)?
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }
}
