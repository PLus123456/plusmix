// 新排布的容器（W6-A，docs/spec/大屏与时间线方案.md §2.1）：监看、中间那一列、输入区、调音台都按 MainLayoutModel 算出来的位置摆（frame），不用 NSSplitView——
// 上半区的高由画面算出来、分隔条只许在"最矮那一档 … 贴合高"之间拖，NSSplitView 的自动分配会和规则打架。旧排布还是原来那套 NSSplitView（MainWindowController）。
// 分隔条（LayoutDividerView）自己画一条 1 pt 的线；能拖的那几条把点得到的范围放宽到线的两边各 3 pt（同 NSSplitView 的细分隔条），盖在两边的视图上面。
import AppKit

@MainActor
final class MainLayoutView: NSView {
    /// 监看与中间那一列之间的空隙（同旧排布 NSStackView 的 spacing）。
    static let monitorGap: CGFloat = 2
    /// 分隔线的粗细（同旧排布 NSSplitView 的 .thin）。
    static let dividerThickness: CGFloat = 1

    /// 排布区要重新摆（尺寸变了 / 被标记要重排）：主窗口量尺寸、算、摆位置（MainWindowController.layoutAdaptive）。
    var onLayout: ((NSSize) -> Void)?
    /// 横屏：上 / 下之间（可拖）；竖屏：左 / 右之间（不拖，只是一条线）。
    let topDivider = LayoutDividerView(axis: .horizontal)
    /// 横屏：输入 ｜ 调音台（可拖）；竖屏：输入 / 调音台（不拖）。
    let mixerDivider = LayoutDividerView(axis: .vertical)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBackground.cgColor
        addSubview(topDivider)
        addSubview(mixerDivider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        onLayout?(bounds.size)
        super.layout()
    }

    /// 把两条分隔条放回最上面（换排布时内容视图是后加的）。
    func bringDividersToFront() {
        for d in [topDivider, mixerDivider] where d.superview === self {
            d.removeFromSuperview()
            addSubview(d)
        }
    }
}

/// 一条分隔线。axis：horizontal = 横线（分上下，拖的是 y），vertical = 竖线（分左右，拖的是 x）。
@MainActor
final class LayoutDividerView: NSView {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    /// 线放到哪里时变（横屏 / 竖屏换了方向）：横屏上下之间是横线，竖屏左右之间是竖线。
    private(set) var lineAxis: Axis
    /// 能不能拖（不能拖的只是一条线，点击穿过去）。
    private(set) var isDraggable = false
    /// 按下 / 拖动（参数 = 从按下时起的位移，排布区坐标：横线是 y、竖线是 x，朝下 / 朝右为正）/ 松开。
    var onDragBegan: (() -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    /// 能拖的线两边各放宽多少点（点得到的范围）。
    static let hitSlop: CGFloat = 3
    private var dragStart: CGFloat?
    /// 线本身（排布区坐标）。
    private(set) var line: CGRect = .zero

    init(axis: Axis) {
        self.axis = axis
        lineAxis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 摆到 line 这条线上（可拖的话点击范围放宽）；nil = 藏起来。
    func place(_ line: CGRect?, axis: Axis, draggable: Bool) {
        guard let line else {
            isHidden = true
            return
        }
        self.line = line
        let changed = lineAxis != axis || isDraggable != draggable
        lineAxis = axis
        isDraggable = draggable
        let slop = draggable ? Self.hitSlop : 0
        let target = axis == .horizontal ? line.insetBy(dx: 0, dy: -slop) : line.insetBy(dx: -slop, dy: 0)
        if frame != target { frame = target }
        if isHidden { isHidden = false }
        if changed { window?.invalidateCursorRects(for: self) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        let slop = isDraggable ? Self.hitSlop : 0
        let r = lineAxis == .horizontal ? NSRect(x: 0, y: slop, width: bounds.width, height: bounds.height - 2 * slop)
                                        : NSRect(x: slop, y: 0, width: bounds.width - 2 * slop, height: bounds.height)
        r.fill()
    }

    override func resetCursorRects() {
        guard isDraggable else { return }
        addCursorRect(bounds, cursor: lineAxis == .horizontal ? .resizeUpDown : .resizeLeftRight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isDraggable ? super.hitTest(point) : nil }

    override func mouseDown(with event: NSEvent) {
        guard isDraggable else { return super.mouseDown(with: event) }
        dragStart = position(event)
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        onDragged?(position(event) - start)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        onDragged?(position(event) - start)
        dragStart = nil
        onDragEnded?()
    }

    /// 鼠标在排布区里的位置（横线取 y、竖线取 x；排布区是翻转的，y 朝下）。
    private func position(_ event: NSEvent) -> CGFloat {
        let p = (superview ?? self).convert(event.locationInWindow, from: nil)
        return lineAxis == .horizontal ? p.y : p.x
    }
}
