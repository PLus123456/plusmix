// 下栏：输入缩略图条，横向滚动 + 搜索框。格子按 MixerState.inputs 的顺序（编号升序）增删复用，不整条重建。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class InputStripView: NSView, NSSearchFieldDelegate {
    var send: ((Command) -> Void)? {
        didSet { for c in cells.values { c.send = send } }
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

        searchField.placeholderString = "搜索输入（编号或名字）"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        let title = Theme.label("输入", size: 12, weight: .semibold, color: Theme.dimText)

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

    /// 输入数量变了格子网格会变（4×2 → 6×3），全部重算。
    private func relayoutThumbnails() {
        let count = lastState.inputs.count
        for (i, config) in lastState.inputs.enumerated() {
            cells[config.number]?.setThumbnail(index: i, inputCount: count, textureWidth: textureSize.width, textureHeight: textureSize.height)
        }
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
