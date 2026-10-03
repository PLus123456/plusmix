// 节目菜单与工具条"打开▾"共用的那几项（W5-G，01a A2，03 V-24）：最近打开的节目（最多 10 个，ShowDocuments.recentURLs，两处同一份数据）、
// 打开上次退出时的节目（退出时自动存的 LastSession，和启动时恢复的是同一份）、清除列表。项都是 nil target 的 AppDelegate 动作，灰不灰由它的 validateMenuItem 定。
// 最近列表里同名的文件（几个"周日礼拜.switcher.json"）带上级目录名区分；上级目录也同名就再往上加一级（最多三级），提示是完整路径。
import AppKit

@MainActor
enum ShowMenu {
    /// 最近列表每一项的标题：不重名只写文件名；重名的写"文件名 — 上级目录"。
    static func recentTitles(_ urls: [URL]) -> [String] {
        let names = urls.map(\.lastPathComponent)
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        /// 往上 depth 级目录名，"周三" / "节目单/周三"。
        func folders(_ url: URL, _ depth: Int) -> String {
            url.deletingLastPathComponent().pathComponents.filter { $0 != "/" }.suffix(depth).joined(separator: "/")
        }
        return urls.indices.map { i in
            let name = names[i]
            guard counts[name, default: 0] > 1 else { return name }
            let others = urls.indices.filter { $0 != i && names[$0] == name }.map { urls[$0] }
            var depth = 1
            while depth < 3, others.contains(where: { folders($0, depth) == folders(urls[i], depth) }) { depth += 1 }
            return L("menu.show.recentInFolder", name, folders(urls[i], depth))
        }
    }

    /// 最近打开的节目：每个文件一项（点 = 打开它，先过换节目的问）；没有就一行灰的"（无）"。
    static func recentItems(_ urls: [URL]) -> [NSMenuItem] {
        guard !urls.isEmpty else {
            let none = NSMenuItem(title: L("menu.show.noRecent"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            return [none]
        }
        return zip(urls, recentTitles(urls)).map { url, title in
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            return item
        }
    }

    static func clearItem() -> NSMenuItem {
        NSMenuItem(title: L("menu.show.clearRecent"), action: #selector(AppDelegate.clearRecents(_:)), keyEquivalent: "")
    }

    static func lastSessionItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("menu.show.openLastSession"), action: #selector(AppDelegate.openLastSession(_:)), keyEquivalent: "")
        item.toolTip = L("menu.show.openLastSessionTip")
        return item
    }

    /// 菜单栏"节目 › 打开最近 ▸"：最近的文件 ─ 清除列表（没有最近的就只有"（无）"）。
    static func fillRecentMenu(_ menu: NSMenu, urls: [URL]) {
        menu.removeAllItems()
        for item in recentItems(urls) { menu.addItem(item) }
        guard !urls.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(clearItem())
    }

    /// 工具条"打开▾"：打开上次退出时的节目 ─ 最近的文件 ─ 清除列表。
    static func openMenu(urls: [URL]) -> NSMenu {
        let menu = NSMenu(title: L("menu.show.openRecent"))
        menu.addItem(lastSessionItem())
        menu.addItem(.separator())
        for item in recentItems(urls) { menu.addItem(item) }
        if !urls.isEmpty {
            menu.addItem(.separator())
            menu.addItem(clearItem())
        }
        return menu
    }
}
