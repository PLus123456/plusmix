// 下栏：输入缩略图条，横向滚动 + 搜索框。格子按 MixerState.inputs 的顺序（编号升序）增删复用，不整条重建。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class InputStripView: NSView, NSSearchFieldDelegate {
    var send: ((Command) -> Void)? {
        didSet { for c in cells.values { c.send = send } }
    }
    /// 格子右键"设置…"→ 打开该路的输入设置窗（W3-E）。
    var onOpenSettings: ((Int) -> Void)? {
        didSet { for c in cells.values { c.onOpenSettings = onOpenSettings } }
    }
    let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private(set) var cells: [Int: InputCellView] = [:]
    private var textureSize = (width: 1920, height: 1080)
    private var lastState = MixerState()
    /// 运行状态来源（session.inputs.runtimeState）。
    var runtimeState: ((Int) -> InputState?)?

    override init(frame: NSRect) {
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
        let title = Theme.label(L("strip.title"), size: 12, weight: .semibold, color: Theme.dimText)

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .top
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(searchField)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
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
        lastState = state
        let wanted = state.inputs.map(\.number)
        for number in cells.keys where !wanted.contains(number) {
            if let cell = cells.removeValue(forKey: number) {
                stack.removeArrangedSubview(cell)
                cell.removeFromSuperview()
            }
        }
        var order: [InputCellView] = []
        for config in state.inputs {
            let cell: InputCellView
            if let existing = cells[config.number] {
                cell = existing
            } else {
                cell = InputCellView(config: config)
                cell.send = send
                cell.onOpenSettings = onOpenSettings
                cell.display.source = displaySource
                cells[config.number] = cell
            }
            order.append(cell)
        }
        if stack.arrangedSubviews.map({ ObjectIdentifier($0) }) != order.map({ ObjectIdentifier($0) }) {
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
            for c in order { stack.addArrangedSubview(c) }
        }
        for config in state.inputs {
            cells[config.number]?.apply(config: config, tally: state.tally(ofInput: config.number), overlays: state.overlays,
                                        runtime: runtimeState?(config.number))
        }
        relayoutThumbnails()
        applySearch()
    }

    /// 缩略图 = 多画面纹理里这一路的格子：按当前布局算（提案 010 的 OutputSettings.multiview；没有 = 默认布局，4×2 → 6×3 随路数变）。
    /// 布局或路数变了才重算（快照每拍都可能变，布局很少变）。布局里没有的路（自定义格子没放它）缩略图画不出来，格子上说明。
    private func relayoutThumbnails() {
        let key = ThumbnailLayoutKey(layout: MultiviewLayout.layoutSettings(in: lastState), inputs: lastState.inputs.map(\.number),
                                     width: textureSize.width, height: textureSize.height)
        guard key != thumbnailLayoutKey else { return }
        thumbnailLayoutKey = key
        let placements = MultiviewLayout.placements(settings: key.layout, inputs: key.inputs, width: key.width, height: key.height)
        for number in key.inputs {
            cells[number]?.setThumbnail(rect: placements.first { $0.source == .input(number: number) }?.inner)
        }
    }

    private struct ThumbnailLayoutKey: Equatable {
        let layout: MultiviewLayoutSettings?
        let inputs: [Int]
        let width: Int
        let height: Int
    }
    private var thumbnailLayoutKey: ThumbnailLayoutKey?

    /// 纯音频输入格子上的电平表（调音台 50 ms 的表定时器转过来，同一份 AudioEngineStatus 读数）。
    func applyAudioLevels(_ peakDb: [Int: [Double]]) {
        for (number, cell) in cells where cell.isAudioOnly { cell.applyAudioLevel(peakDb[number]) }
    }

    /// 显示来源（新 session 时换）；新建的格子也从这里拿。
    var displaySource: (any DisplayFrameSource)? {
        didSet { for c in cells.values { c.display.source = displaySource } }
    }

    @objc private func searchChanged() { applySearch() }

    /// 回车 / Esc：把焦点还给窗口，数字键又是快捷键了。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { searchField.stringValue = ""; applySearch() }
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func applySearch() {
        let q = searchField.stringValue
        for c in cells.values { c.isHidden = !c.matches(search: q) }
    }

    /// 可见格子（搜索过滤后）的编号。
    var visibleNumbers: [Int] { stack.arrangedSubviews.compactMap { ($0 as? InputCellView).flatMap { $0.isHidden ? nil : $0.number } } }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
