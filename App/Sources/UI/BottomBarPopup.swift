// 底栏弹出物的定位（W5-A，docs/ui-study/01a-改动总表.md E1、03-目视检查.md §2.2）：一级菜单和弹出层一律朝上开、贴按钮上沿，整块留在主窗口里
// （原来往下弹：外部输出菜单伸出窗口下沿 25 pt、盖住状态行；叠加面板在窗口下方放得下时整块弹到窗口外）。子菜单的方向由系统定、会往下伸，所以底栏的菜单不用子菜单。
// NSButton 是翻转坐标（isFlipped == true，y = 0 是上沿，探针确认）：菜单左上角放在 y = −菜单高 + 1，菜单就整块落在按钮上方（实测底边在按钮上沿之上 4 pt）；
// NSPopover 的 preferredEdge 按视图自己的坐标解释，翻转坐标里 .minY 才是上沿。以后底栏加的 ▴ 菜单（录制、推流、添加输入）都走这里。
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

    /// 弹出层贴按钮上沿的那条边。
    static func popoverEdge(for anchor: NSView) -> NSRectEdge { anchor.isFlipped ? .minY : .maxY }

    /// 朝上弹出层。
    static func show(_ popover: NSPopover, from anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: popoverEdge(for: anchor))
    }

    /// 叠加面板的内容尺寸：宽 400（表单要的宽度），高 min(640, 窗口内容高 − 120)，最矮 240（表单可滚动）。
    static func overlayPanelSize(windowContentHeight: CGFloat) -> NSSize {
        NSSize(width: OverlayPanelView.idealWidth, height: max(240, min(640, windowContentHeight - 120)))
    }
}
