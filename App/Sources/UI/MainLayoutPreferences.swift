// 主窗口排布的本机偏好（W6-A，docs/spec/大屏与时间线方案.md §2.1 规则 7 / 8 / 9、§2.5）：新 / 旧排布、时钟显示方式、分隔条位置。
// 存 UserDefaults（本机偏好，和节目文件无关；测试宿主是自己的 suite，AppTest.freshSession 每条用例开头清掉）。不碰契约。
import AppKit

/// 窗口 › 排布：新排布（默认：监看贴合画布、调音台在下边一行 / 竖屏时在右边一栏）/ 旧排布（今天的样子：调音台在右侧通高、监看区自由高度）。
enum WindowArrangement: String, CaseIterable {
    case adaptive = "new"
    case legacy

    var title: String { L("arrangement.\(rawValue)") }
}

/// 时钟（设置 › 常规 › 显示）：自动（默认：中间那一列放不下就收起来，时间改在状态行右端）/ 一直显示（今天的样子）/ 不显示。
enum ClockDisplay: String, CaseIterable {
    case auto, always, never

    var title: String { L("clockDisplay.\(rawValue)") }
}

@MainActor
final class MainLayoutPreferences {
    enum Keys {
        static let arrangement = "mainWindowArrangement"
        static let clockDisplay = "mainWindowClockDisplay"
        /// 横屏下边一行想要的高（用户拖过上下之间的分隔条；没有 = 按规则）。
        static let bottomRowHeight = "mainWindowBottomRowHeight"
        /// 横屏调音台的宽（用户拖过输入 ｜ 调音台中间的分隔条；没有 = 340）。
        static let mixerWidth = "mainWindowMixerWidth"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 新 / 旧排布（没存过 = 新排布）。
    var arrangement: WindowArrangement {
        get { defaults.string(forKey: Keys.arrangement).flatMap(WindowArrangement.init(rawValue:)) ?? .adaptive }
        set { defaults.set(newValue.rawValue, forKey: Keys.arrangement) }
    }

    /// 时钟（没存过 = 自动）。
    var clockDisplay: ClockDisplay {
        get { defaults.string(forKey: Keys.clockDisplay).flatMap(ClockDisplay.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Keys.clockDisplay) }
    }

    var bottomRowHeight: CGFloat? {
        get { number(Keys.bottomRowHeight) }
        set { setNumber(newValue, Keys.bottomRowHeight) }
    }

    var mixerWidth: CGFloat? {
        get { number(Keys.mixerWidth) }
        set { setNumber(newValue, Keys.mixerWidth) }
    }

    private func number(_ key: String) -> CGFloat? {
        (defaults.object(forKey: key) as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private func setNumber(_ value: CGFloat?, _ key: String) {
        if let value { defaults.set(Double(value), forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// 回到默认（测试每条用例开头调）。
    func reset() {
        for key in [Keys.arrangement, Keys.clockDisplay, Keys.bottomRowHeight, Keys.mixerWidth] { defaults.removeObject(forKey: key) }
    }
}
