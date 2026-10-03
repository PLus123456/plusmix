// 底栏弹出物的定位（W5-A，docs/ui-study/01a-改动总表.md E1、03-目视检查.md §2.2）：一级菜单和弹出层一律朝上开、贴按钮上沿，整块留在主窗口里
// （原来往下弹：外部输出菜单伸出窗口下沿 25 pt、盖住状态行；叠加面板在窗口下方放得下时整块弹到窗口外）。子菜单的方向由系统定、会往下伸，所以底栏的菜单不用子菜单。
// NSButton 是翻转坐标（isFlipped == true，y = 0 是上沿，探针确认）：菜单左上角放在 y = −菜单高 + 1，菜单就整块落在按钮上方（实测底边在按钮上沿之上 4 pt）；
// 以后底栏加的 ▴ 菜单（录制、推流、添加输入）都走这里（W5-F：SplitBarButton 的 ⚙ / ▴ 都走 popUp）。
// 弹出层（叠加面板）W5-F 起不用 NSPopover 了：它永远以按钮为中心摆，叠加挪到右组（窗口最右）以后会伸出窗口右沿 144–174 pt（1440 / 1100 宽实测），
// 又没有公开办法挪箭头；换成 BottomBarPanel（没有箭头，按钮在窗口右半边时右缘对齐按钮、否则左缘对齐，整块夹在窗口里）。
import AppKit

@MainActor
enum BottomBarPopup {
    /// 菜单左上角在按钮坐标里的位置（朝上开）。
    static func menuLocation(for menu: NSMenu, in anchor: NSView) -> NSPoint {
        let height = menu.size.height
        return anchor.isFlipped ? NSPoint(x: 0, y: -height + 1) : NSPoint(x: 0, y: anchor.bounds.height + height - 1)
    }

    /// 按定位点算出来的菜单在屏幕上的位置（Cocoa 坐标；系统放不下时还会再挪，实测见 BottomBarPopupTests）。
    static func menuFrameInScreen(for menu: NSMenu, from anchor: NSView) -> NSRect {
        let size = menu.size
        let topLeft = menuLocation(for: menu, in: anchor)
        let local = NSRect(x: topLeft.x, y: anchor.isFlipped ? topLeft.y : topLeft.y - size.height, width: size.width, height: size.height)
        guard let window = anchor.window else { return local }
        return window.convertToScreen(anchor.convert(local, to: nil))
    }

    /// 朝上弹菜单（模态：菜单关掉才返回）。
    static func popUp(_ menu: NSMenu, from anchor: NSView) {
        ScreenMenu.popUp(menu, at: menuLocation(for: menu, in: anchor), in: anchor)
    }

    /// 弹出层的位置（屏幕坐标）：底边在按钮上沿之上 4 pt；按钮在窗口右半边时右缘对齐按钮右缘，否则左缘对齐按钮左缘；左右再夹进窗口（各留 8 pt）。
    static func panelFrame(size: NSSize, from anchor: NSView, margin: CGFloat = 8) -> NSRect {
        guard let window = anchor.window else { return NSRect(origin: .zero, size: size) }
        let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let bounds = window.frame
        var x = button.midX > bounds.midX ? button.maxX - size.width : button.minX
        x = max(bounds.minX + margin, min(x, bounds.maxX - margin - size.width))
        return NSRect(x: x, y: button.maxY + 4, width: size.width, height: size.height)
    }

    /// 叠加面板的内容尺寸：宽 400（表单要的宽度），高 min(640, 窗口内容高 − 120)，最矮 240（表单可滚动）。
    static func overlayPanelSize(windowContentHeight: CGFloat) -> NSSize {
        NSSize(width: OverlayPanelView.idealWidth, height: max(240, min(640, windowContentHeight - 120)))
    }
}

/// 底栏的弹出层（叠加面板，W5-F）：朝上开、贴按钮上沿、整块在主窗口里（位置见 BottomBarPopup.panelFrame）。外观照系统弹出层（材质、圆角、阴影），没有箭头。
/// 行为照 NSPopover 的 transient：点面板以外的地方、按 Esc 就收起；点的是锚点按钮本身时这里不收（按钮动作自己开关，不会收了又开）。
/// 挂在主窗口上当子窗口（主窗口挪动它跟着走）；不抢键盘焦点（弹出时不变成 key，点进面板里的输入框才变），空格 / 回车照旧走主窗口的快捷键表。
@MainActor
final class BottomBarPanel: NSPanel {
    let controller: NSViewController
    /// 收起之后（MainWindowController 清引用）。
    var onClose: (() -> Void)?
    private var monitor: Any?
    private weak var anchor: NSView?

    init(content controller: NSViewController) {
        self.controller = controller
        let size = controller.preferredContentSize
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false   // 和主窗口一起留在原处（NSPanel 默认切到别的 App 就藏起来；NSPopover 不会）
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let view = controller.view
        view.frame = effect.bounds
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    /// Esc = 收起。
    override func cancelOperation(_ sender: Any?) { close() }

    func show(from anchor: NSView) {
        guard let parent = anchor.window else { return }
        self.anchor = anchor
        setFrame(BottomBarPopup.panelFrame(size: frame.size, from: anchor), display: false)
        parent.addChildWindow(self, ordered: .above)
        orderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.closeIfOutside(event) }
            return event
        }
    }

    private func closeIfOutside(_ event: NSEvent) {
        guard isVisible, event.window !== self else { return }
        if let anchor, event.window === anchor.window, anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
        close()
    }

    override func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        parent?.removeChildWindow(self)
        super.close()
        onClose?()
    }
}
