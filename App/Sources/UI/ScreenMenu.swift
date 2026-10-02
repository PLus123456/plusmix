// 按屏幕坐标弹菜单（W5-A）：底栏的朝上菜单（BottomBarPopup）、转场列的类型菜单与自定义时长菜单都走这里。
import AppKit

/// 按屏幕坐标弹菜单：location 是菜单左上角在 view 坐标里的位置，换成屏幕坐标再弹（in: nil）。程序改过窗口位置（打开节目读回 mainWindowFrame、
/// setFrame）之后马上按视图弹，菜单用的是窗口位置的旧缓存，落在上一次的地方（BottomBarPopupTests 实测：1440×900 ↔ 1100×700 来回换，
/// 第二次弹出的菜单按旧窗口的左上角摆）；convertPoint(toScreen:) 用的是当前 frame。
@MainActor
enum ScreenMenu {
    static func popUp(_ menu: NSMenu, at location: NSPoint, in view: NSView) {
        guard let window = view.window else {
            menu.popUp(positioning: nil, at: location, in: view)
            return
        }
        menu.popUp(positioning: nil, at: window.convertPoint(toScreen: view.convert(location, to: nil)), in: nil)
    }

    /// 在 view 正下方弹，左缘对齐（翻转 / 不翻转的视图都算对）。菜单窗口比给的位置高出约 5 pt（上内边距，实测），所以往下多给 5，菜单顶边正好贴着下沿。
    static func popUpBelow(_ menu: NSMenu, _ view: NSView) {
        popUp(menu, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 5 : -5), in: view)
    }
}
