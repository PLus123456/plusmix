// W5-B 桩：底栏录制 / 推流主体按钮的汇总（红测试阶段，实现见后一个提交）。
import AppKit

struct OutputRouteStatus: Equatable {
    var number: Int
    var name: String
    var enabled: Bool
    var state: String?
    var frames: UInt64 = 0
    var attempt: Int? = nil
    var failure: String? = nil
}

enum OutputButtonSeverity: Int, Comparable {
    case off, live, pending, warning, error
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct OutputButtonSummary: Equatable {
    var title: String
    var toolTip: String?
    var severity: OutputButtonSeverity
    @MainActor var color: NSColor { Theme.recording }
    static func stream(_ routes: [OutputRouteStatus]) -> OutputButtonSummary { OutputButtonSummary(title: "", toolTip: nil, severity: .off) }
    static func record(_ routes: [OutputRouteStatus]) -> OutputButtonSummary { OutputButtonSummary(title: "", toolTip: nil, severity: .off) }
}

extension Theme {
    static let outputWarning = NSColor(red: 0.93, green: 0.55, blue: 0.1, alpha: 1)
    static let outputError = NSColor(red: 0.62, green: 0.06, blue: 0.06, alpha: 1)
}
