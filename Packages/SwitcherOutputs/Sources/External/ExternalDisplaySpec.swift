import SwitcherContracts

/// 一个外部显示输出的设置：哪块显示器、送什么画面、显示器不在时怎么办。
/// 存放在契约 `OutputSettings` 里：`source` 就是 `settings.source`；显示器 ID 和退回策略放 `settings.extra`（各输出会话的附加项占位）。
public struct ExternalDisplaySpec: Hashable, Sendable {
    /// CGDirectDisplayID；nil = 主显示器。
    public var displayID: UInt32?
    /// 送什么：PGM / PVW / 多画面 / 某路输入（Aux）。
    public var source: OutputSource
    /// 目标显示器不在（拔了 / 还没插）时退到主显示器；false = 收起窗口等它回来。
    public var fallbackToMain: Bool

    public init(displayID: UInt32? = nil, source: OutputSource = .program, fallbackToMain: Bool = false) {
        self.displayID = displayID
        self.source = source
        self.fallbackToMain = fallbackToMain
    }

    /// `OutputSettings.extra` 里的键。
    public static let displayIDKey = "displayID"
    public static let fallbackKey = "fallbackToMain"

    /// 从输出设置读。
    public init(settings: OutputSettings) {
        source = settings.source
        if case .number(let n)? = settings.extra[Self.displayIDKey], n >= 0, n <= Double(UInt32.max) {
            displayID = UInt32(n)
        } else {
            displayID = nil
        }
        if case .bool(let b)? = settings.extra[Self.fallbackKey] { fallbackToMain = b } else { fallbackToMain = false }
    }

    /// 写回输出设置。
    public func apply(to settings: inout OutputSettings) {
        settings.source = source
        if let displayID { settings.extra[Self.displayIDKey] = .number(Double(displayID)) } else { settings.extra.removeValue(forKey: Self.displayIDKey) }
        if fallbackToMain { settings.extra[Self.fallbackKey] = .bool(true) } else { settings.extra.removeValue(forKey: Self.fallbackKey) }
    }

    /// 一份新的输出设置（其他字段默认）。
    public var outputSettings: OutputSettings {
        var s = OutputSettings(source: source)
        apply(to: &s)
        return s
    }

    /// 源的显示名。
    public static func describe(_ source: OutputSource, inputs: [InputConfig] = []) -> String {
        switch source {
        case .program: "PGM"
        case .preview: "PVW"
        case .multiview: "多画面"
        case .input(let n): "输入 \(n)" + (inputs.first { $0.number == n }.map { " \($0.name)" } ?? "")
        }
    }
}
