// 节目菜单与工具条 打开▾ 共用的最近列表（W5-G，01a A2，03 V-24）。
import AppKit

@MainActor
enum ShowMenu {
    /// 最近列表的标题：同名文件带上级目录名。
    static func recentTitles(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }
}
