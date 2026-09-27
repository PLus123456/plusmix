import SwitcherContracts

/// 一个外部显示输出的设置：哪块显示器、送什么画面、显示器不在时怎么办。
/// 存放在契约 `OutputSettings` 里：`source` 就是 `settings.source`；显示器 ID 和退回策略是正式字段 `settings.display`（提案 013）。
public struct ExternalDisplaySpec: Hashable, Sendable {
    /// CGDirectDisplayID；nil = 主显示器。
    public var displayID: UInt32?
    /// 送什么：PGM / PVW / 多画面 / 某路输入（Aux = 该路原始画面，抠像 / 裁切 / 变换不生效）。
    public var source: OutputSource
    /// 目标显示器不在（拔了 / 还没插）时退到主显示器；false = 收起窗口等它回来。
    public var fallbackToMain: Bool

    public init(displayID: UInt32? = nil, source: OutputSource = .program, fallbackToMain: Bool = false) {
        self.displayID = displayID
        self.source = source
        self.fallbackToMain = fallbackToMain
    }

    /// P3 之前放显示器 ID / 退回策略的 `OutputSettings.extra` 过渡键。本类型从 W3-C2 起**不再读**它们（旧节目文件由 `Show.load`
    /// 一次性搬进正式字段，P3 报告 §4 第 1 条）；写出时仍顺手清掉。常量留着给还在做后备读取的 App `OutputExtras`（W4 / G5 一起删）。
    public static let displayIDKey = DisplayOutputSettings.legacyDisplayIDKey
    public static let fallbackKey = DisplayOutputSettings.legacyFallbackKey

    /// 从输出设置读：只看正式字段 `settings.display`；没有就是它的默认（主显示器、不退回，提案 015）。
    public init(settings: OutputSettings) {
        source = settings.source
        let d = settings.display ?? DisplayOutputSettings()
        displayID = d.displayID
        fallbackToMain = d.fallbackToMain
    }

    /// 写回输出设置：只写正式字段，顺手清掉过渡键。
    public func apply(to settings: inout OutputSettings) {
        settings.source = source
        settings.display = DisplayOutputSettings(displayID: displayID, fallbackToMain: fallbackToMain)
        settings.extra.removeValue(forKey: Self.displayIDKey)
        settings.extra.removeValue(forKey: Self.fallbackKey)
    }

    /// 一份新的输出设置（其他字段默认）。
    public var outputSettings: OutputSettings {
        var s = OutputSettings(source: source)
        apply(to: &s)
        return s
    }
    // 源的显示名由组装方查表（App 的 OutputSource.title(in:)）；包里的 describe 在 W3-C3 删了。
}
