// 设置 / 表单类面板的窗口宿主（设计方案 §10：SwiftUI 只做设置、表单类面板，放 NSHostingView）。
// 每个面板 = 一个 ObservableObject 模型 + 一个 SwiftUI 视图 + 这里的窗口；模型只发 Command、只读快照，窗口本身不碰引擎。
import AppKit
import SwiftUI

/// 能拦按键的面板窗口（快捷键编辑器录键用）。
@MainActor
final class PanelWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
class PanelWindowController: NSWindowController, NSWindowDelegate {
    /// 窗口关掉时（用户点关闭或 close()）。
    var onClose: (() -> Void)?

    init<Content: View>(title: String, size: NSSize, autosaveName: String, content: Content, minSize: NSSize? = nil) {
        let window = PanelWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = minSize ?? NSSize(width: 360, height: 240)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.setFrameAutosaveName(autosaveName)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 显示并置前。
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
