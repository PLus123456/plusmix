// 输入分类（W5-H，01a D1 / 04 Q14）：输入条左端"全部 + 六色"标签，点 = 只显示这一类（与搜索叠加），右键标签改名；格子右键"分类 ▸"。
// 红灯轮：只给签名。
import AppKit
import SwitcherContracts

struct InputCategories: Equatable {
    enum Color: String, CaseIterable {
        case red, orange, yellow, green, blue, purple
    }
    enum Keys {
        static let assignments = "inputCategories"
        static let names = "inputCategoryNames"
    }
    var assignments: [Int: Color] = [:]
    var names: [Color: String] = [:]
    init() {}
    init(layout values: [String: JSONValue]) {}
    func write(into values: inout [String: JSONValue]) {}
}

/// 输入条左端的分类标签（红灯轮：只给签名）。
@MainActor
final class CategoryTagBar: NSStackView {
    private(set) var tagButtons: [NSButton] = []
    private let placeholderButton = NSButton(title: "", target: nil, action: nil)
    func button(for color: InputCategories.Color?) -> NSButton { placeholderButton }
    func menu(for color: InputCategories.Color) -> NSMenu? { nil }
}
