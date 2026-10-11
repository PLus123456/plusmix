// 下栏：输入缩略图条，横向滚动。格子按 MixerState.inputs 的顺序（编号升序）增删复用，不整条重建。
// W5-H（prompt 94，01a D1–D3 / D10 / D11 / G13）：头一行 = "输入" ｜ 分类标签（全部 + 六色，点 = 只显示这一类、与搜索叠加，右键改名）｜ 搜索框（常驻，⌘F）
// ……右端"调音台"开关（与"窗口 › 调音台"同一个动作）；格子后面是虚线"＋ 添加输入"占位格（空节目时是唯一一格，带拖放的小字）；
// 视频 / 图片文件拖到输入条或占位格 = 直接加一路（MainWindowController.addInputs）；缩略图小 / 中 / 大三档（右键 / 窗口菜单），
// 最小高跟着格子算（minimumHeight，主窗口的分隔条与最小窗口按它定）。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class InputStripView: NSView, NSSearchFieldDelegate {
    var send: ((Command) -> Void)? {
        didSet { for c in cells.values { c.send = send } }
    }
    /// 格子 ⚙ / 右键"设置…"→ 打开该路的输入设置窗（W3-E）。
    var onOpenSettings: ((Int) -> Void)? {
        didSet { for c in cells.values { c.onOpenSettings = onOpenSettings } }
    }
    /// 格子右键"换来源…"→ 输入设置窗停在"来源"一节。
    var onChangeSource: ((Int) -> Void)? {
        didSet { for c in cells.values { c.onChangeSource = onChangeSource } }
    }
    /// 分类数据变了（格子右键"分类 ▸"、删了一路清掉它的分类）：交给主窗口写回 Show.layout。
    var onCategoriesChange: ((InputCategories) -> Void)?
    /// 分类标签右键"改名…" / "清除名字"。
    var onRenameCategory: ((InputCategories.Color) -> Void)?
    var onClearCategoryName: ((InputCategories.Color) -> Void)?
    /// 占位格单击。
    var onAddInput: (() -> Void)?
    /// 拖进来的文件（认得的 + 跳过的）。
    var onDropFiles: ((MediaFileDrop.Result) -> Void)?
    /// 状态行提示（转场进行中点了缩略图）。
    var onNotice: ((String) -> Void)? {
        didSet { for c in cells.values { c.onNotice = onNotice } }
    }
    /// 右键 / 窗口菜单选了缩略图大小。
    var onThumbnailSizeChange: ((ThumbnailSize) -> Void)?
    /// 最小高变了（三档、裁切比例、路数变了布局）。
    var onMinimumHeightChange: (() -> Void)?

    /// 格子 Overlay k 的右键"叠加设置…"（W5-K）。
    var onOverlaySettings: ((Int) -> Void)? {
        didSet { for c in cells.values { c.onOverlaySettings = onOverlaySettings } }
    }
    let searchField = NSSearchField()
    let categoryBar = CategoryTagBar()
    let mixerToggle: NSButton
    let addPlaceholder = AddInputPlaceholderView()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private(set) var cells: [Int: InputCellView] = [:]
    private var textureSize = (width: 1920, height: 1080)
    private var lastState = MixerState()
    /// 运行状态来源（session.inputs.runtimeState）。
    var runtimeState: ((Int) -> InputState?)?

    /// 分类（Show.layout 里来的；主窗口换 session 时先设它再挂快照）。
    var categories = InputCategories() {
        didSet { if categories != oldValue { applyCategories() } }
    }
    /// 选中的分类（nil = 全部）。界面状态，不存。
    private(set) var selectedCategory: InputCategories.Color?
    /// 缩略图大小（主窗口按本机偏好设）。
    var thumbnailSize: ThumbnailSize = .medium {
        didSet {
            guard thumbnailSize != oldValue else { return }
            relayoutThumbnails()   // 宽变了，框高按新宽重算
            applySizes()
        }
    }
    /// 缩略图框的高（所有格子一样：取各路裁切后比例里最高的那个，见 relayoutThumbnails）。
    private(set) var thumbnailHeight: CGFloat = (Theme.thumbnailWidth * 9 / 16).rounded()
    /// 拖文件进来时整条高亮。
    private(set) var isDropTargetHighlighted = false {
        didSet {
            guard isDropTargetHighlighted != oldValue else { return }
            layer?.borderWidth = isDropTargetHighlighted ? 2 : 0
            layer?.borderColor = Theme.accent.cgColor
        }
    }

    /// 头一行（搜索框那一行）占的高：上边距 4 + 搜索框 + 下边距 4。
    static let headerHeight: CGFloat = 30
    /// 格子上下的留白（stack 的 edgeInsets）。
    static let stackInset: CGFloat = 6

    /// 输入条最矮多高：头一行 + 一格（标题条 + 缩略图框 + 两行按钮）+ 上下留白——格子最下一行按钮点得到（W5-A / X61 的口径，W5-H 起按格子算）。
    var minimumHeight: CGFloat {
        Self.headerHeight + Self.stackInset * 2 + InputCellView.height(thumbnailHeight: thumbnailHeight)
    }

    override init(frame: NSRect) {
        mixerToggle = Theme.toggleButton(L("strip.mixer"), target: nil, action: #selector(AppDelegate.toggleMixer(_:)))
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBackground.cgColor

        searchField.placeholderString = L("strip.searchPlaceholder")
        searchField.setAccessibilityLabel(L("strip.searchPlaceholder"))
        searchField.cell?.setAccessibilityLabel(L("strip.searchPlaceholder"))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.toolTip = L("strip.searchTip")
        let title = Theme.label(L("strip.title"), size: 12, weight: .semibold, color: Theme.dimText)
        mixerToggle.controlSize = .small
        mixerToggle.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        mixerToggle.refusesFirstResponder = true
        mixerToggle.toolTip = L("strip.mixer.tip")
        categoryBar.onSelect = { [weak self] color in self?.selectCategory(color) }
        categoryBar.onRename = { [weak self] color in self?.onRenameCategory?(color) }
        categoryBar.onClearName = { [weak self] color in self?.onClearCategoryName?(color) }
        addPlaceholder.onClick = { [weak self] in self?.onAddInput?() }
        addPlaceholder.onDropFiles = { [weak self] result in self?.onDropFiles?(result) }
        addPlaceholder.onDropHighlight = { [weak self] on in self?.isDropTargetHighlighted = on }

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .top
        stack.edgeInsets = NSEdgeInsets(top: Self.stackInset, left: 6, bottom: Self.stackInset, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(addPlaceholder)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(categoryBar)
        addSubview(searchField)
        addSubview(mixerToggle)
        addSubview(scrollView)
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 220)
        searchWidth.priority = .defaultLow   // 窄窗口 + 分类起了长名字时先让搜索框变窄
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            categoryBar.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            categoryBar.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: categoryBar.trailingAnchor, constant: 10),
            searchWidth,
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            mixerToggle.leadingAnchor.constraint(greaterThanOrEqualTo: searchField.trailingAnchor, constant: 10),
            mixerToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mixerToggle.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
        // 格子底下不钉死：输入条一时比格子矮（换缩略图大小、分隔条还没挪的那一下）时格子伸出去被裁，而不是和 required 约束撞
        let stackBottom = stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        stackBottom.priority = .defaultHigh
        stackBottom.isActive = true
        registerForDraggedTypes([.fileURL])
        relayoutThumbnails()
        applySizes()
        addPlaceholder.setHintVisible(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 多画面纹理尺寸（= 节目分辨率），算格子位置用。
    func setTextureSize(width: Int, height: Int) {
        textureSize = (width, height)
        relayoutThumbnails()
    }

    /// 快照 → 格子增删 + 每格状态。
    func apply(state: MixerState) {
        let previousNumbers = lastState.inputs.map(\.number)
        lastState = state
        let wanted = state.inputs.map(\.number)
        for number in cells.keys where !wanted.contains(number) {
            if let cell = cells.removeValue(forKey: number) {
                stack.removeArrangedSubview(cell)
                cell.removeFromSuperview()
            }
        }
        var order: [NSView] = []
        for config in state.inputs {
            let cell: InputCellView
            if let existing = cells[config.number] {
                cell = existing
            } else {
                cell = makeCell(config)
                cells[config.number] = cell
            }
            order.append(cell)
        }
        order.append(addPlaceholder)   // 占位格永远在最后
        if stack.arrangedSubviews.map({ ObjectIdentifier($0) }) != order.map({ ObjectIdentifier($0) }) {
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
            for v in order { stack.addArrangedSubview(v) }
        }
        let label = transitionLabel(state)
        for config in state.inputs {
            guard let cell = cells[config.number] else { continue }
            cell.apply(config: config, tally: state.tally(ofInput: config.number), overlays: state.overlays, runtime: runtimeState?(config.number))
            cell.applySwitching(program: state.program, transitionActive: state.transition.isActive, transitionLabel: label)
            cell.removalImpacts = InputRemovalImpact.impacts(of: config.number, in: state)   // 删之前要不要问（W5-B）
        }
        addPlaceholder.setHintVisible(state.inputs.isEmpty)
        // 删掉的路：分类跟着清（编号以后被别的输入用上时不继承）
        if wanted != previousNumbers {
            var pruned = categories
            if pruned.prune(keeping: Set(wanted)) {
                categories = pruned
                onCategoriesChange?(pruned)
            }
            applyCategories()
        }
        relayoutThumbnails()
        applyFilter()
    }

    private func makeCell(_ config: InputConfig) -> InputCellView {
        let cell = InputCellView(config: config)
        cell.send = send
        cell.onOpenSettings = onOpenSettings
        cell.onOverlaySettings = onOverlaySettings   // W5-K：Overlay 小按钮右键"叠加设置…"
        cell.onChangeSource = onChangeSource
        cell.onNotice = onNotice
        cell.onSetCategory = { [weak self] number, color in self?.setCategory(color, for: number) }
        cell.categoryTitles = { [weak self] color in self?.categories.title(of: color) ?? color.defaultTitle }
        cell.display.source = displaySource
        cell.setSize(width: thumbnailSize.width, thumbnailHeight: thumbnailHeight)
        cell.setCategory(categories.assignments[config.number], title: categories.assignments[config.number].map { categories.title(of: $0) })
        return cell
    }

    /// "按当前转场送上 PGM（…）"括号里那段：当前槽"转场 2 · Wipe → 1 秒"（W5-M：格子上的"转场"= 执行当前槽，与回车 / T-bar 同一个；
    /// 当前那组不在槽里时只写效果与时长）。当前槽 / 当前那组 / 帧率不变就用上次拼好的。
    private func transitionLabel(_ state: MixerState) -> String {
        let key = TransitionLabelKey(slot: state.transition.currentSlot, group: state.transition.currentGroup, rate: state.format.frameRate)
        if key == transitionLabelKey { return transitionLabelText }
        transitionLabelKey = key
        transitionLabelText = SlotText.current(state.transition, rate: state.format.frameRate)
        return transitionLabelText
    }
    private struct TransitionLabelKey: Equatable {
        let slot: Int?
        let group: TransitionSlot
        let rate: FrameRate
    }
    private var transitionLabelKey: TransitionLabelKey?
    private var transitionLabelText = ""

    /// 缩略图 = 多画面纹理里这一路的格子：按当前布局算（提案 010 的 OutputSettings.multiview；没有 = 默认布局，4×2 → 6×3 随路数变）。
    /// 布局或路数变了才重算（快照每拍都可能变，布局很少变）。布局里没有的路（自定义格子没放它）缩略图画不出来，格子上说明。
    /// 缩略图框的高（V-23）：按裁切后那块的比例，所有格子取最高的那个（默认布局各格一样；自定义布局里扁的那几格左右留一点边），没有输入时按默认布局一路算。
    private func relayoutThumbnails() {
        // 与渲染器同一个来源：只读正式字段 OutputSettings.multiview（W3-B2 起过渡键 extra["layout"] 一律忽略；Show.load 会把旧键搬进正式字段）
        let settings = MultiviewLayout.layoutSettings(in: lastState)
        let key = ThumbnailLayoutKey(layout: settings, inputs: lastState.inputs.map(\.number), width: textureSize.width, height: textureSize.height, size: thumbnailSize)
        guard key != thumbnailLayoutKey else { return }
        thumbnailLayoutKey = key
        let placements = MultiviewLayout.placements(settings: key.layout, inputs: key.inputs, width: key.width, height: key.height)
        var rects: [NormalizedRect] = []
        for number in key.inputs {
            let placement = placements.first { $0.source == .input(number: number) }
            let rect = placement.map { Self.thumbnailRect(for: $0, width: key.width, height: key.height) }
            if let rect { rects.append(rect) }
            cells[number]?.setThumbnail(rect: rect)
        }
        if rects.isEmpty, let first = MultiviewLayout.placements(settings: nil, inputs: [1], width: key.width, height: key.height).first(where: { $0.source == .input(number: 1) }) {
            rects = [Self.thumbnailRect(for: first, width: key.width, height: key.height)]
        }
        let width = thumbnailSize.width
        let height = rects.map { InputCellView.thumbnailHeight(width: width, rect: $0, textureWidth: key.width, textureHeight: key.height) }.max()
            ?? InputCellView.thumbnailHeight(width: width, rect: nil, textureWidth: key.width, textureHeight: key.height)
        if height != thumbnailHeight {
            thumbnailHeight = height
            applySizes()
        }
    }

    /// 缩略图切多画面格子的哪一块：内框去掉底部渲染器画的名字条（W3-E3 交付第 5 条：名字只在标题条出现一次——标题条是主标签，带编号和 tally 色；
    /// 缩略图只要画面）。名字条的几何与 CompositorPasses.drawCellLabel 同一个算式（Float）：贴内框底边，高 = 格高 × 14%，≥ 12 px，≤ 画面高 × 3.5%；
    /// 再多切 2 px，缩略图下采样的采样脚印碰不到名字条的上沿。切完不是 16:9：W5-H 起缩略图框按切完的比例定高（V-23），不再上下留黑边。
    nonisolated static func thumbnailRect(for placement: MultiviewCellPlacement, width: Int, height: Int) -> NormalizedRect {
        let frameHeight = Float(height)
        let cellHeight = Float(placement.outer.height * Double(height))
        let label = max(12, min((cellHeight * 0.14).rounded(), (frameHeight * 0.035).rounded()))
        let cut = Double(label + thumbnailLabelMargin) / Double(height)
        let inner = placement.inner
        return NormalizedRect(x: inner.x, y: inner.y, width: inner.width, height: max(0, inner.height - cut))
    }

    /// 名字条上面再多切的像素（多画面纹理的像素）。
    nonisolated static let thumbnailLabelMargin: Float = 2

    private struct ThumbnailLayoutKey: Equatable {
        let layout: MultiviewLayoutSettings?
        let inputs: [Int]
        let width: Int
        let height: Int
        let size: ThumbnailSize
    }
    private var thumbnailLayoutKey: ThumbnailLayoutKey?

    /// 格子 / 占位格的尺寸跟三档与缩略图框高走；最小高变了告诉主窗口。
    private func applySizes() {
        for cell in cells.values { cell.setSize(width: thumbnailSize.width, thumbnailHeight: thumbnailHeight) }
        addPlaceholder.setSize(width: thumbnailSize.width, height: InputCellView.height(thumbnailHeight: thumbnailHeight))
        let minimum = minimumHeight
        if minimum != appliedMinimumHeight {
            appliedMinimumHeight = minimum
            onMinimumHeightChange?()
        }
    }
    private var appliedMinimumHeight: CGFloat = 0

    /// 纯音频输入格子上的电平表（调音台 50 ms 的表定时器转过来，同一份 AudioEngineStatus 读数）。
    func applyAudioLevels(_ peakDb: [Int: [Double]]) {
        for (number, cell) in cells where cell.isAudioOnly { cell.applyAudioLevel(peakDb[number]) }
    }

    /// 显示来源（新 session 时换）；新建的格子也从这里拿。
    var displaySource: (any DisplayFrameSource)? {
        didSet { for c in cells.values { c.display.source = displaySource } }
    }

    // MARK: 分类

    /// 点分类标签：只显示这一类（nil = 全部），与搜索叠加。
    func selectCategory(_ color: InputCategories.Color?) {
        selectedCategory = color
        categoryBar.apply(categories: categories, selected: color)
        applyFilter()
    }

    /// 格子右键"分类 ▸"：改这一路的分类，交给主窗口写回 Show.layout。
    func setCategory(_ color: InputCategories.Color?, for number: Int) {
        var next = categories
        next.assignments[number] = color
        guard next != categories else { return }
        categories = next
        onCategoriesChange?(next)
    }

    private func applyCategories() {
        categoryBar.apply(categories: categories, selected: selectedCategory)
        for (number, cell) in cells {
            let color = categories.assignments[number]
            cell.setCategory(color, title: color.map { categories.title(of: $0) })
        }
        applyFilter()
    }

    // MARK: 搜索 / 筛选

    @objc private func searchChanged() { applyFilter() }

    /// ⌘F：焦点进搜索框（输入 › 搜索输入）。
    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    /// 回车 / Esc：把焦点还给窗口，数字键又是快捷键了。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { searchField.stringValue = ""; applyFilter() }
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    /// 搜索与分类叠加；占位格不受筛选影响。
    private func applyFilter() {
        let q = searchField.stringValue
        for (number, cell) in cells {
            let visible = cell.matches(search: q) && (selectedCategory == nil || categories.assignments[number] == selectedCategory)
            if cell.isHidden == visible { cell.isHidden = !visible }
        }
    }

    /// 可见格子（搜索 / 分类过滤后）的编号。
    var visibleNumbers: [Int] { stack.arrangedSubviews.compactMap { ($0 as? InputCellView).flatMap { $0.isHidden ? nil : $0.number } } }

    /// 条里从左到右的格子（含最后的占位格）。
    var arrangedItems: [NSView] { stack.arrangedSubviews }

    // MARK: 调音台开关

    /// 调音台开着 = 高亮（与"窗口 › 调音台"的勾同一个状态）。
    func setMixerVisible(_ visible: Bool) {
        Theme.setHighlighted(mixerToggle, visible)
    }

    // MARK: 缩略图大小（右键 / 窗口 › 输入缩略图 ▸）

    /// 小 / 中 / 大，当前的打勾。每次新建（菜单项不能同时挂在两个菜单里）。
    func thumbnailSizeMenu() -> NSMenu {
        let menu = NSMenu(title: L("strip.size.menu"))
        menu.autoenablesItems = false
        for size in ThumbnailSize.allCases {
            menu.addItem(.action(size.title, state: size == thumbnailSize ? .on : .off) { [weak self] in self?.onThumbnailSizeChange?(size) })
        }
        return menu
    }

    /// 条的空白处右键：添加输入… / 缩略图大小 ▸。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.action(L("strip.add.menu")) { [weak self] in self?.onAddInput?() })
        let sizes = NSMenuItem(title: L("strip.size.menu"), action: nil, keyEquivalent: "")
        sizes.submenu = thumbnailSizeMenu()
        menu.addItem(sizes)
        return menu
    }

    // MARK: 拖放（G13：视频 / 图片文件拖进来直接加一路）

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = MediaFileDrop.accepts(sender.draggingPasteboard)
        isDropTargetHighlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTargetHighlighted = false }

    override func draggingEnded(_ sender: any NSDraggingInfo) { isDropTargetHighlighted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTargetHighlighted = false
        let result = MediaFileDrop.read(sender.draggingPasteboard)
        guard !result.accepted.isEmpty else { return false }
        onDropFiles?(result)
        return true
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
