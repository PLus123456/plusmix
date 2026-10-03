// 菜单项右列的"键"（W5-G，01a O1，docs/ui-study/01-菜单逻辑.md §5）：从当前快捷键表反查出来、只显示，不设 keyEquivalent——设了的话菜单栏会在
// 主窗口 keyDown 之前先截这个键，和 HotkeyDispatcher 各触发一次（或者抢走它：来源从 hotkey 变成 ui，MIDI / API 的口径就对不上了）。
// 做法：attributedTitle = "标题\t键"，同一个菜单里所有带键的项用同一个右对齐制表位（最长标题 + 间隔 + 最长的键），键就对成一列；
// 字体是菜单字体、不设颜色（高亮时跟系统一起反白）。探针（reports/w5-app-toolbar.md §5）：设了 attributedTitle 之后 item.title 也变成"标题\t键"，
// 所以按标题找项一律走 title(of:)。
import AppKit

@MainActor
enum MenuKeyColumn {
    /// 标题与键之间至少留多宽（pt）。
    static let gap: CGFloat = 28

    /// 菜单项的标题（不含右列）。
    static func title(of item: NSMenuItem) -> String {
        guard let tab = item.title.firstIndex(of: "\t") else { return item.title }
        return String(item.title[..<tab])
    }

    /// 菜单项右列的键（没有为 nil）。
    static func keys(of item: NSMenuItem) -> String? {
        guard let tab = item.title.firstIndex(of: "\t") else { return nil }
        let keys = String(item.title[item.title.index(after: tab)...])
        return keys.isEmpty ? nil : keys
    }

    /// 一行：菜单项、标题、右列的键（nil = 没有键）。
    struct Row {
        var item: NSMenuItem
        var title: String
        var keys: String?
    }

    /// 给同一个菜单里的一组项设标题与右列（要一起设，键才对得齐）。没变就不重设。
    static func apply(_ rows: [Row], font: NSFont = .menuFont(ofSize: 0)) {
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let keyed = rows.filter { $0.keys != nil }
        let titleWidth = keyed.map { width($0.title) }.max() ?? 0
        let keyWidth = keyed.compactMap(\.keys).map(width).max() ?? 0
        let stop = ceil(titleWidth + gap + keyWidth)
        for row in rows {
            guard let keys = row.keys else {
                if row.item.attributedTitle != nil { row.item.attributedTitle = nil }
                if row.item.title != row.title { row.item.title = row.title }
                continue
            }
            let text = "\(row.title)\t\(keys)"
            if row.item.title == text, let current = row.item.attributedTitle,
               (current.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.first?.location == stop { continue }
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: stop)]
            row.item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style])
        }
    }
}
