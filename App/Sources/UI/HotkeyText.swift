// 快捷键的显示文字（W5-A：转场列按钮的提示从当前快捷键表反查，01a C5 / X40）：修饰键用 ⌃⌥⇧⌘ 符号（苹果的顺序），
// 命名键翻成人话（空格 / 回车 / Esc / 方向键…），字母大写。表里的 JSON 写法（"shift+1"）不变，只是给人看的样子。
// W5-G：动作的匹配（HotkeyMatch，转场列提示与"切换"菜单右列共用一套）、一条绑定的动作写成人话（帮助 › 快捷键一览）。
import SwitcherContracts
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

    /// 表里绑到某个动作的组合键（按表里的顺序，停用的行不算），连成"空格、⇧C"；修饰键相同的连号数字（3 个及以上）写成"⌥1–⌥4"
    /// （W5-J：默认表的 ⌥1–⌥4 在转场槽落地前都是"执行当前转场"）。没有返回 nil。
    static func keys(in table: HotkeyTable, matching match: (ControlAction) -> Bool) -> String? {
        let combos = table.bindings.filter { $0.enabled && match($0.action) }.map(\.key)
        guard !combos.isEmpty else { return nil }
        var parts: [String] = []
        var i = 0
        while i < combos.count {
            var j = i
            if let first = Int(combos[i].key), combos[i].key.count == 1 {
                while j + 1 < combos.count, combos[j + 1].modifiers == combos[i].modifiers, let next = Int(combos[j + 1].key), combos[j + 1].key.count == 1,
                      next == first + (j + 1 - i) { j += 1 }
            }
            if j - i >= 2 {
                parts.append(display(combos[i]) + "–" + display(combos[j]))
            } else {
                parts += combos[i...j].map(display)
            }
            i = j + 1
        }
        return parts.joined(separator: L("key.listSeparator"))
    }

    /// 一条绑定的动作写成人话（快捷键一览）："选进 PVW · 输入 2""叠加开关 · 通道 3"——与快捷键页行上的摘要同一套（ActionText，W5-J）；
    /// 整条替换类用命令目录的说明（CommandText）。
    static func describe(_ action: ControlAction) -> String { ActionText.summary(action) }
}

/// 快捷键表里"这条绑定是不是这个动作"（W5-G：转场列按钮提示、"切换"菜单右列、快捷键一览都按它反查，口径一处定）。
enum HotkeyMatch {
    static func cut(_ a: ControlAction) -> Bool { if case .command(.cut) = a { return true }; return false }
    static func fade(_ a: ControlAction) -> Bool { if case .command(.fade) = a { return true }; return false }
    /// 按已选转场执行（回车的默认绑定）。
    static func auto(_ a: ControlAction) -> Bool { if case .command(.autoTransition) = a { return true }; return false }
    static func ftb(_ a: ControlAction) -> Bool {
        if case .toggleFTB = a { return true }
        if case .command(.ftb) = a { return true }
        return false
    }
    static func overlay(_ channel: Int) -> (ControlAction) -> Bool {
        { a in
            if case .toggleOverlay(let ch) = a { return ch == channel }
            if case .command(.overlay(let ch, _, _)) = a { return ch == channel }
            return false
        }
    }
    /// 只改"下一次转场"的类型（不执行）：setTransition 到这种类型（时长不论）。
    static func selectType(_ type: TransitionType) -> (ControlAction) -> Bool {
        { a in
            if case .command(.setTransition(let t, _)) = a { return t == type }
            return false
        }
    }
}
