// 快捷键的显示文字（W5-A：转场列按钮的提示从当前快捷键表反查，01a C5 / X40）：修饰键用 ⌃⌥⇧⌘ 符号（苹果的顺序），
// 命名键翻成人话（空格 / 回车 / Esc / 方向键…），字母大写。表里的 JSON 写法（"shift+1"）不变，只是给人看的样子。
import SwitcherControl

@MainActor
enum HotkeyText {
    static func display(_ combo: KeyCombo) -> String {
        var text = ""
        if combo.modifiers.contains(.control) { text += "⌃" }
        if combo.modifiers.contains(.option) { text += "⌥" }
        if combo.modifiers.contains(.shift) { text += "⇧" }
        if combo.modifiers.contains(.command) { text += "⌘" }
        return text + keyName(combo.key)
    }

    static func keyName(_ key: String) -> String {
        switch key {
        case "space": L("key.space")
        case "return": L("key.return")
        case "escape": "Esc"
        case "tab": "⇥"
        case "delete": "⌫"
        case "forwarddelete": "⌦"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.uppercased()   // 字母 / 数字 / 符号；f1…f20 → F1…F20
        }
    }

    /// 表里绑到某个动作的组合键（按表里的顺序），连成"空格、⇧C"；没有返回 nil。
    static func keys(in table: HotkeyTable, matching match: (ControlAction) -> Bool) -> String? {
        let keys = table.bindings.filter { match($0.action) }.map { display($0.key) }
        return keys.isEmpty ? nil : keys.joined(separator: L("key.listSeparator"))
    }
}
