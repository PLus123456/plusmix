// 转场槽的文字（W5-M，prompt 100）：一处定，转场列、"切换"菜单、选动作面板、格子的提示都用它。
//   按钮上（13 pt，主体能放 ≈ 85 pt）：Fade 0.5s / Wipe → 1s / Zoom 1s / Stinger 1s / Stinger 未设 / Cut
//   菜单与 T-bar 那一行：转场 2 · Wipe → 1 秒 / 转场 4 · Stinger（未设）/ 转场 3 · Cut
//   提示里写全：Wipe 左 → 右 · 1 秒 / Stinger · 输入 2 合成 2 · 1 秒 / Stinger · 还没选输入 · 1 秒
// 秒数按标称帧率换（59.94 → 60，与时长分段同一口径）。
import AppKit
import SwitcherContracts

@MainActor
enum SlotText {
    /// Wipe 方向的箭头（按钮与菜单的短写法）。
    static func arrow(_ direction: WipeDirection) -> String {
        switch direction {
        case .leftToRight: "→"
        case .rightToLeft: "←"
        case .topToBottom: "↓"
        case .bottomToTop: "↑"
        case .diagonal: "↘"
        }
    }

    /// 拍 → 秒（标称帧率）。
    static func seconds(_ ticks: Int, rate: FrameRate) -> Double {
        Double(ticks) / Double(max(rate.nominalFramesPerSecond, 1))
    }

    /// 效果的短名："Fade"、"Wipe →"、"Zoom"、"Stinger"、"Cut"。
    static func effect(_ slot: TransitionSlot) -> String {
        slot.type == .wipe ? L("slot.effect.wipeArrow", arrow(slot.wipe.direction)) : L("transition.type.\(slot.type.rawValue)")
    }

    /// Stinger 槽没选输入（X18：点主体先弹输入选择、不执行）。
    static func isUnsetStinger(_ slot: TransitionSlot) -> Bool { slot.type == .stinger && slot.stinger.input == nil }

    /// 按钮上的字。
    static func buttonTitle(_ slot: TransitionSlot, rate: FrameRate) -> String {
        if slot.type == .cut { return L("transition.type.cut") }
        if isUnsetStinger(slot) { return L("slot.button.stingerUnset") }
        return L("slot.button", effect(slot), TransitionPanelView.compactSeconds(seconds(slot.durationTicks, rate: rate)))
    }

    /// 菜单与 T-bar 那一行里的写法（不带槽号）。
    static func description(_ slot: TransitionSlot, rate: FrameRate) -> String {
        if slot.type == .cut { return L("transition.type.cut") }
        if isUnsetStinger(slot) { return L("slot.stingerUnset") }
        return L("slot.description", effect(slot), TransitionPanelView.secondsText(seconds(slot.durationTicks, rate: rate)))
    }

    /// "转场 2 · Wipe → 1 秒"。
    static func menuTitle(_ index: Int, _ slot: TransitionSlot, rate: FrameRate) -> String {
        L("slot.menuTitle", index, description(slot, rate: rate))
    }

    /// 提示里的完整写法（方向写字、Stinger 写出是哪一路）。
    static func detail(_ slot: TransitionSlot, rate: FrameRate, state: MixerState?) -> String {
        let time = TransitionPanelView.secondsText(seconds(slot.durationTicks, rate: rate))
        switch slot.type {
        case .cut:
            return L("slot.detail.cut")
        case .wipe:
            return L("slot.detail.wipe", L("transition.wipe.direction.\(slot.wipe.direction.rawValue)"), time)
        case .stinger:
            guard let input = slot.stinger.input else { return L("slot.detail.stingerUnset", time) }
            return L("slot.detail.stinger", inputName(input, state: state), time)
        case .fade, .zoom:
            return L("slot.detail.plain", L("transition.type.\(slot.type.rawValue)"), time)
        }
    }

    /// "输入 2 合成 2"（节目里没有这一路时写"（不存在的输入 n）"）。
    static func inputName(_ number: Int, state: MixerState?) -> String {
        guard let input = state?.input(number) else { return L("monitor.missingInput", number) }
        return L("source.input", input.number, input.name)
    }

    /// T-bar 那一行 / "执行当前转场"括号里：当前槽（"转场 2 · Wipe → 1 秒"），当前那组不在槽里时只写效果与时长。
    static func current(_ transition: TransitionState, rate: FrameRate) -> String {
        if let n = transition.currentSlot, n - 1 < transition.slots.count {
            return menuTitle(n, transition.slots[n - 1], rate: rate)
        }
        return description(transition.currentGroup, rate: rate)
    }
}
