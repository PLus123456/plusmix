// 快捷键默认表（设计方案 §9.4，本期硬编码；配置化在 W2-C）：
//   数字 1–9、0 → 选 PVW（0 = 输入 10）；Shift + 数字 → 直切 PGM；空格 → Cut；回车 → Fade（当前时长）；F → FTB 开关。
// 在主窗口的 keyDown 里生效：文本框（搜索、名字）有焦点时按键先被字段编辑器吃掉，不会到这里，所以打字不会误触。
import AppKit
import SwitcherContracts

enum KeyCommandMap {
    /// 事件 → 命令；不认识的键返回 nil（交回响应链）。
    static func command(for event: NSEvent, state: MixerState) -> Command? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        guard let chars = event.charactersIgnoringModifiers, let key = chars.first else { return nil }
        if let digit = key.wholeNumberValue, chars.count == 1 {
            let input = digit == 0 ? 10 : digit
            return flags.contains(.shift) ? .setProgram(input: input) : .setPreview(input: input)
        }
        switch key {
        case " ": return .cut
        case "\r", "\u{3}": return .fade(durationTicks: state.transition.durationTicks)   // 回车 / 小键盘 Enter
        case "f", "F": return .ftb(on: !state.ftb.on)
        default: return nil
        }
    }

    /// 给菜单 / 帮助看的表。
    static let table: [(key: String, action: String)] = [
        ("1–9、0", "选 PVW（0 = 输入 10）"),
        ("Shift + 数字", "直切 PGM"),
        ("空格", "Cut"),
        ("回车", "Fade"),
        ("F", "FTB"),
    ]
}
