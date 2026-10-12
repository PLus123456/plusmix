// 输入分类（W5-H，01a D1 / 04 Q14）：输入条左端"全部 + 六色"标签，点 = 只显示这一类（与搜索叠加），右键标签改名；格子右键"分类 ▸"（无 + 六色），
// 格子标题条上画一个色点。六色用 Finder 标签同一套（红 / 橙 / 黄 / 绿 / 蓝 / 紫）。
//
// 数据放哪：**颜色是每路输入的 `InputConfig.color`**（提案 023 第四节，P5-2 落进契约；W5-O 起 App 读写它）——改分类发 `setInputColor`，
// 快照回来格子跟着变（API / 脚本改的也一样），API 全量状态、多画面、Stream Deck 读同一份；删掉一路颜色跟着它的配置没了（编号再给别的输入用不继承）。
// **名字**（"红色 = 机位"）只是界面标签，留在 Show.layout（023 四 (a)，契约不解释）：
//   "inputCategoryNames"  = { "<颜色>": "<名字>" }，只写起过名的颜色；没起名时整个键不写
// W5-H 原来把颜色也存在 layout 的 "inputCategories" = { "<输入编号>": "<颜色>" }（InputConfig.legacyCategoriesLayoutKey）：老节目打开时由
// ShowDocuments.prepared 调 `Show.migratingLegacyInputCategories()` 搬一次（读文件、读 LastSession 两处，同 101 对 025 的做法），搬完删键。
// 名字键算节目内容（AppController.documentContent 不剥掉，改名算未保存）。
import AppKit
import SwitcherContracts

/// 分类的颜色就是契约里的 InputColor（rawValue = W5-H 存进 layout 的值）；界面上的叫法 / 画色在这里。
extension InputColor {
    /// 没起名时的叫法（"红色"）。
    var defaultTitle: String { L("category.color.\(rawValue)") }

    @MainActor var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }

    /// 色块上写字用黑还是白（黄 / 橙 / 绿底压白字对比不够）。
    @MainActor var textColor: NSColor {
        switch self {
        case .yellow, .orange, .green: .black
        case .red, .blue, .purple: .white
        }
    }
}

struct InputCategories: Equatable {
    typealias Color = InputColor

    enum Keys {
        /// 起过名的颜色 → 名字（Show.layout 里唯一的分类键）。
        static let names = "inputCategoryNames"
        /// 节目内容里算数的 layout 键（AppController.documentContent 留着它们）。
        static let all = [names]
    }

    /// 输入编号 → 颜色（没分类的不在里面）：快照里各路的 InputConfig.color。
    var assignments: [Int: Color] = [:]
    /// 起过名的颜色 → 名字。
    var names: [Color: String] = [:]

    init() {}

    /// 颜色读各路的 InputConfig.color，名字读 Show.layout（认不出的条目跳过：别的版本写的、手改坏的）。
    init(inputs: [InputConfig], layout values: [String: JSONValue]) {
        assignments = Self.assignments(of: inputs)
        if case .object(let map)? = values[Keys.names] {
            for (key, value) in map {
                if let color = Color(rawValue: key), case .string(let name) = value, !name.isEmpty { names[color] = name }
            }
        }
    }

    /// 快照里各路的颜色。
    static func assignments(of inputs: [InputConfig]) -> [Int: Color] {
        var out: [Int: Color] = [:]
        for input in inputs { if let color = input.color { out[input.number] = color } }
        return out
    }

    /// 名字写回 Show.layout（没起过名就删键）。颜色不在 layout 里（走 setInputColor）。
    func write(into values: inout [String: JSONValue]) {
        values[Keys.names] = names.isEmpty ? nil
            : .object(Dictionary(uniqueKeysWithValues: names.map { ($0.key.rawValue, JSONValue.string($0.value)) }))
    }

    /// 标签 / 菜单上的叫法：起过名写名字，没起写"红色"。
    func title(of color: Color) -> String { names[color] ?? color.defaultTitle }

    /// 辅助功能名：颜色总是在（读屏的人分得清是哪一个），起过名再带名字。
    func accessibilityTitle(of color: Color) -> String {
        names[color].map { L("category.a11yNamed", color.defaultTitle, $0) } ?? color.defaultTitle
    }
}

/// 输入条左端的分类标签：全部 + 六色。点 = 只显示这一类（再点一次已选的 = 回到全部）；右键颜色标签 = 改名 / 清除名字。
/// 只管显示和把点击交出去：选中哪一类、分类数据由 InputStripView / MainWindowController 管。
@MainActor
final class CategoryTagBar: NSView {
    /// 点了某个标签（nil = 全部）。
    var onSelect: ((InputCategories.Color?) -> Void)?
    /// 右键"改名…"。
    var onRename: ((InputCategories.Color) -> Void)?
    /// 右键"清除名字"。
    var onClearName: ((InputCategories.Color) -> Void)?
    /// 全部 + 六色，从左到右。
    let tagButtons: [NSButton]
    private let stack = NSStackView()
    private var categories = InputCategories()
    private(set) var selected: InputCategories.Color?
    private var shown: (InputCategories, InputCategories.Color?)?

    override init(frame: NSRect) {
        tagButtons = [CategoryTagButton(color: nil)] + InputCategories.Color.allCases.map { CategoryTagButton(color: $0) }
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for case let b as CategoryTagButton in tagButtons {
            b.target = self
            b.action = #selector(tagPressed(_:))
            b.bar = self
            stack.addArrangedSubview(b)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(categories: InputCategories(), selected: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 名字 / 选中变了才重画标签（快照每拍都会调到这里）。
    func apply(categories: InputCategories, selected: InputCategories.Color?) {
        if let shown, shown.0 == categories, shown.1 == selected { return }
        shown = (categories, selected)
        self.categories = categories
        self.selected = selected
        for case let b as CategoryTagButton in tagButtons {
            b.update(title: b.color.map { categories.names[$0] ?? "" } ?? L("category.all"),
                     accessibility: b.color.map { categories.accessibilityTitle(of: $0) } ?? L("category.all"),
                     toolTip: b.color.map { L("category.tagTip", categories.title(of: $0)) } ?? L("category.allTip"),
                     selected: b.color == selected)
        }
    }

    func button(for color: InputCategories.Color?) -> NSButton {
        tagButtons.first { ($0 as? CategoryTagButton)?.color == color } ?? tagButtons[0]
    }

    /// 颜色标签的右键菜单：改名… / 清除名字（起过名才有）。
    func menu(for color: InputCategories.Color) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.action(L("category.rename")) { [weak self] in self?.onRename?(color) })
        if categories.names[color] != nil {
            menu.addItem(.action(L("category.clearName")) { [weak self] in self?.onClearName?(color) })
        }
        return menu
    }

    @objc private func tagPressed(_ sender: CategoryTagButton) {
        // 再点一次已选的那一类 = 回到全部
        onSelect?(sender.color != nil && sender.color == selected ? nil : sender.color)
    }
}

/// 一个分类标签：色块（没名字时是 18 pt 的小方块，有名字写名字），选中时白框。"全部"是灰底写字。
@MainActor
private final class CategoryTagButton: NSButton {
    let color: InputCategories.Color?
    weak var bar: CategoryTagBar?
    private var widthConstraint: NSLayoutConstraint!

    init(color: InputCategories.Color?) {
        self.color = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = (color?.nsColor ?? Theme.tallyOff).cgColor
        layer?.borderColor = NSColor.white.cgColor
        font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        widthConstraint = widthAnchor.constraint(equalToConstant: 18)
        widthConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(title text: String, accessibility: String, toolTip tip: String, selected: Bool) {
        let textColor = color?.textColor ?? .white
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: textColor, .font: font ?? .systemFont(ofSize: 10), .paragraphStyle: style])
        let textWidth = text.isEmpty ? 0 : ceil(attributedTitle.size().width)
        widthConstraint.constant = text.isEmpty ? 18 : min(max(textWidth + 12, 18), 80)
        setAccessibilityLabel(accessibility)
        toolTip = tip
        layer?.borderWidth = selected ? 2 : 0
        layer?.backgroundColor = (color?.nsColor ?? Theme.tallyOff).cgColor
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let color else { return nil }
        return bar?.menu(for: color)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = (color?.nsColor ?? Theme.tallyOff).cgColor
    }
}
