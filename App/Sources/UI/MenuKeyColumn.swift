// 菜单项右列的"键"（W5-G，01a O1）：从当前快捷键表反查出来、只显示，不设 keyEquivalent（免得菜单和 HotkeyDispatcher 各触发一次）。
import AppKit

@MainActor
enum MenuKeyColumn {
    /// 菜单项的标题（不含右列）。
    static func title(of item: NSMenuItem) -> String { item.title }

    /// 菜单项右列的键（没有为 nil）。
    static func keys(of item: NSMenuItem) -> String? { nil }
}
