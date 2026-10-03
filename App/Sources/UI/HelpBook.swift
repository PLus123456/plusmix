// 帮助菜单的两个入口（W5-G，01a O3，04 Q33 (a)）：
// - PlusMix 使用手册：随包 HTML（生成归 103：docs/user → App/Resources/Help/，这里只找入口页、用默认浏览器打开）。找法：包的 Resources/Help/<界面语言>/index.html，
//   没有分语言的目录就 Resources/Help/index.html；都没有 = 手册尚未随包（菜单项灰着、标题写明，见 HelpMenu）。
// - 快捷键一览：按当前快捷键表生成一页静态 HTML（临时目录，每次覆盖），用默认浏览器打开——改了表再点就是新的。
// 打开走 HelpBook.open（测试换掉它，不真开浏览器）。
import AppKit
import SwitcherControl

@MainActor
enum HelpBook {
    /// 打开一个本地页面（测试换掉它，不真开浏览器）。
    static var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 测试用：当成包的 Resources 目录。
    static var resourceURLOverride: URL?

    /// 现在界面用的语言（lproj 名）：覆盖语言 → 主 bundle 实际选中的本地化。
    static var language: String { L10n.languageOverride ?? Bundle.main.preferredLocalizations.first ?? "en" }

    /// 随包手册的入口页；不在包里为 nil。
    static func manualURL() -> URL? {
        guard let resources = resourceURLOverride ?? Bundle.main.resourceURL else { return nil }
        let help = resources.appendingPathComponent("Help", isDirectory: true)
        let candidates = [help.appendingPathComponent(language, isDirectory: true).appendingPathComponent("index.html"),
                          help.appendingPathComponent("index.html")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 打开手册（不在包里就什么都不做；菜单项那时是灰的）。
    static func openManual() {
        guard let url = manualURL() else { return }
        open(url)
    }

    /// 按这张表生成快捷键一览、写进临时目录、打开。写不进去返回 nil。
    @discardableResult
    static func openHotkeyList(table: HotkeyTable) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlusMix-\(L("hotkeyList.fileName")).html")
        do {
            try Data(HotkeyListPage.html(table: table).utf8).write(to: url, options: .atomic)
        } catch {
            NSLog("快捷键一览写不进临时目录：\(error)")
            return nil
        }
        open(url)
        return url
    }
}

/// 快捷键一览（一页静态 HTML，没有脚本）：表头 + 每条绑定一行（按键 / 动作 / 备注），顺序 = 表里的顺序；文字走本地化表，深浅色跟系统。
@MainActor
enum HotkeyListPage {
    static func html(table: HotkeyTable) -> String {
        let rows = table.bindings.map { b in
            "<tr><td><kbd>\(escape(HotkeyText.display(b.key)))</kbd></td><td>\(escape(HotkeyText.describe(b.action)))</td><td>\(escape(b.note ?? ""))</td></tr>"
        }
        let lang = HelpBook.language
        return """
        <!doctype html>
        <html lang="\(escape(lang))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(L("hotkeyList.title")))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, "PingFang SC", sans-serif; margin: 32px; max-width: 760px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: 6px 12px; border-bottom: 1px solid #8884; vertical-align: top; }
        th { font-weight: 600; }
        kbd { font: 13px ui-monospace, Menlo, monospace; padding: 1px 6px; border: 1px solid #8888; border-radius: 4px; white-space: nowrap; }
        p.note { color: #888; }
        </style>
        </head>
        <body>
        <h1>\(escape(L("hotkeyList.title")))</h1>
        <p class="note">\(escape(L("hotkeyList.intro")))</p>
        <table>
        <tr><th>\(escape(L("hotkeyList.key")))</th><th>\(escape(L("hotkeyList.action")))</th><th>\(escape(L("hotkeyList.note")))</th></tr>
        \(rows.joined(separator: "\n"))
        </table>
        </body>
        </html>
        """
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
