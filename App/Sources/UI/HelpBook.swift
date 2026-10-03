// 帮助菜单的两个入口（W5-G，01a O3，04 Q33）：随包手册（生成归 103）、按当前快捷键表生成的一览页。
import AppKit
import SwitcherControl

@MainActor
enum HelpBook {
    /// 打开一个本地页面（测试换掉它，不真开浏览器）。
    static var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 测试用：当成包的 Resources 目录。
    static var resourceURLOverride: URL?

    /// 随包手册的入口页；不在包里为 nil。
    static func manualURL() -> URL? { nil }
}

@MainActor
enum HotkeyListPage {
    static func html(table: HotkeyTable) -> String { "" }
}
