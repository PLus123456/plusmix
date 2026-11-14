// 输入区的格子排法（W6-A，docs/spec/大屏与时间线方案.md §2.1 规则 4）：所有格子一样大，按顺序一格一格往右排。
//   .wrap（新排布）：一行放不下就折到下一行，整块竖向滚动；
//   .row （旧排布，今天的样子）：只排一行，横向滚动。
// 藏起来的格子（搜索 / 分类筛掉的）不占位（同 NSStackView 的 detachesHiddenViews）。格子自己有宽高约束（InputCellView / AddInputPlaceholderView），
// 这里只用 leading / top 两条约束定位、改常数，不和格子自己的约束打架；自己的宽高按排法设（滚动视图的文档视图）。
// 一行几格、露出几行的口径和方案示意页的 perRow / rowsFor 一样：每格算上它右边 / 下边的一个间距（最后一格算上外留白）。
import AppKit

@MainActor
final class InputGridView: NSView {
    enum Flow { case row, wrap }

    /// 格子外的留白（上下左右）与格子间距。
    let inset: CGFloat
    let spacing: CGFloat
    var flow: Flow = .row {
        didSet { if flow != oldValue { updateDocumentConstraints(); relayout() } }
    }
    /// 每一格的大小（输入条按缩略图那一档与裁切比例算好给）。
    var itemSize = NSSize(width: 200, height: 153) {
        didSet { if itemSize != oldValue { relayout() } }
    }
    /// 从左到右（从上到下）的格子，含最后的占位格。
    private(set) var items: [NSView] = []
    private var positions: [ObjectIdentifier: (x: NSLayoutConstraint, y: NSLayoutConstraint)] = [:]
    /// 一行几格（.row 时 = 可见格数）。
    private(set) var columns = 1
    private weak var clip: NSClipView?
    /// 可见区的宽（输入条在自己的 layout 里先给；没给就读滚动视图的可见区）。
    var viewportWidth: CGFloat?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    /// 宽 / 高跟着滚动视图的可见区（.wrap 宽跟、.row 高跟）。
    private var widthToClip: NSLayoutConstraint?
    private var heightToClip: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    init(inset: CGFloat, spacing: CGFloat) {
        self.inset = inset
        self.spacing = spacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 挂进滚动视图之后调：建跟可见区走的约束。
    func attach(to clip: NSClipView) {
        self.clip = clip
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        widthToClip = widthAnchor.constraint(equalTo: clip.widthAnchor)
        heightToClip = heightAnchor.constraint(equalTo: clip.heightAnchor)
        updateDocumentConstraints()
    }

    private func updateDocumentConstraints() {
        guard let widthConstraint, let heightConstraint, let widthToClip, let heightToClip else { return }
        let wrap = flow == .wrap
        widthToClip.isActive = wrap
        widthConstraint.isActive = !wrap
        heightToClip.isActive = !wrap
        heightConstraint.isActive = wrap
    }

    /// 换一批格子（顺序就是排的顺序）：新的加进来、没了的拿掉，不重建留下的。
    func setItems(_ views: [NSView]) {
        let keep = Set(views.map(ObjectIdentifier.init))
        for v in items where !keep.contains(ObjectIdentifier(v)) {
            positions[ObjectIdentifier(v)] = nil
            v.removeFromSuperview()
        }
        for v in views where positions[ObjectIdentifier(v)] == nil {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            let x = v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
            let y = v.topAnchor.constraint(equalTo: topAnchor, constant: inset)
            NSLayoutConstraint.activate([x, y])
            positions[ObjectIdentifier(v)] = (x, y)
        }
        items = views
        relayout()
    }

    /// 按现在的可见区宽（.wrap）重新排；格子藏 / 放、换大小、可见区变宽变窄时调。
    func relayout() {
        let visible = items.filter { !$0.isHidden }
        let w = itemSize.width, h = itemSize.height
        let viewportWidth = self.viewportWidth ?? clip?.bounds.width ?? bounds.width
        switch flow {
        case .row:
            columns = max(1, visible.count)
        case .wrap:
            columns = max(1, Int(((viewportWidth - inset) / (w + spacing)).rounded(.down)))
        }
        for (i, v) in visible.enumerated() {
            guard let p = positions[ObjectIdentifier(v)] else { continue }
            let col = flow == .row ? i : i % columns
            let row = flow == .row ? 0 : i / columns
            let x = inset + CGFloat(col) * (w + spacing), y = inset + CGFloat(row) * (h + spacing)
            if p.x.constant != x { p.x.constant = x }
            if p.y.constant != y { p.y.constant = y }
        }
        let rows = flow == .row ? 1 : max(1, Int((Double(visible.count) / Double(columns)).rounded(.up)))
        let n = CGFloat(max(1, visible.count))
        let contentWidth = 2 * inset + n * w + (n - 1) * spacing
        let contentHeight = 2 * inset + CGFloat(rows) * h + CGFloat(rows - 1) * spacing
        if let widthConstraint, widthConstraint.constant != contentWidth { widthConstraint.constant = contentWidth }
        if let heightConstraint, heightConstraint.constant != contentHeight { heightConstraint.constant = contentHeight }
    }

    /// 可见区里放得下几行（.wrap；口径同示意页 rowsFor：每行算上它下面的一个间距）。
    func fullyVisibleRows(viewportHeight: CGFloat) -> Int {
        max(0, Int(((viewportHeight - inset) / (itemSize.height + spacing)).rounded(.down)))
    }
}
