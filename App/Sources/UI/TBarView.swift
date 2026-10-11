// T-bar：自绘 NSView，横放（W5-M，04 Q05 (a)：与参考、界面稿同一方向；原来竖放是 W2-B 的取舍）。左 = 0、右 = 1。
// 拖动手柄发 tbar(progress)；松手时过 97% 就提交（发 tbar(1)，状态机对调）并回弹到最左，没过就停在原位（真推杆的行为）。
// 不拖的时候跟着快照走（auto 转场时能看到它自己往右走）。MIDI 推子不经过这里，照旧到两端换向（MIDIMapper.TBarMapper）。
// 可见的左右边就是视图的左右边（轨道铺满整宽、把手在 0 时左边贴左沿、在 1 时右边贴右沿），转场列按 86 的口径对齐（8…列宽 − 8）。
import AppKit
import SwitcherContracts

@MainActor
final class TBarView: NSView {
    /// 拖动时每次位置变化都调（去重后）；松手过 97% 时最后一次是 1。
    var onProgress: ((Double) -> Void)?
    /// 当前显示的位置 0–1。
    private(set) var progress: Double = 0 {
        didSet {
            needsDisplay = true
            setAccessibilityValue(NSNumber(value: progress))
        }
    }
    private(set) var isDragging = false
    private var grabOffset: CGFloat = 0
    private var springTimer: Timer?
    /// 松手时视为"到顶"的阈值。
    static let commitThreshold = 0.97
    /// 把手的宽（横放：竖的小条）。
    static let handleWidth: CGFloat = 14
    /// 视图高（固定；列里多出来的高度不给它）。
    static let height: CGFloat = 28
    static let trackHeight: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("T-bar")
        setAccessibilityValue(NSNumber(value: 0))
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    /// 快照来了：不在拖动就把位置同步到转场进度（空闲 = 0）。
    func apply(state: MixerState) {
        guard !isDragging, springTimer == nil else { return }
        let p = state.transition.isActive ? state.transition.progress : 0
        if p != progress { progress = p }
    }

    // MARK: 几何

    /// 把手中心能走的范围（行程 = 宽 − 把手宽）。
    private var travel: CGFloat { max(1, bounds.width - Self.handleWidth) }

    /// 推杆在 p 时把手的位置。
    func handleFrame(at p: Double) -> NSRect {
        NSRect(x: CGFloat(min(max(p, 0), 1)) * travel, y: 2, width: Self.handleWidth, height: max(1, bounds.height - 4))
    }

    /// 把手现在的位置（测试量左右边）。
    var handleFrame: NSRect { handleFrame(at: progress) }

    private var trackRect: NSRect {
        NSRect(x: 0, y: bounds.midY - Self.trackHeight / 2, width: bounds.width, height: Self.trackHeight)
    }

    private func progress(forX x: CGFloat) -> Double {
        Double(min(max((x - Self.handleWidth / 2) / travel, 0), 1))
    }

    // MARK: 画

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        let track = trackRect
        Theme.divider.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        // 已推过的部分（从左沿到把手中心）
        let handle = handleFrame
        let filled = NSRect(x: track.minX, y: track.minY, width: handle.midX - track.minX, height: track.height)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        // 刻度：0 / 25 / 50 / 75 / 100（把手中心走到的位置）
        Theme.dimText.setFill()
        for k in 0...4 {
            let x = Self.handleWidth / 2 + travel * CGFloat(k) / 4
            NSRect(x: x - 0.5, y: track.minY - 4, width: 1, height: track.height + 8).fill()
        }
        (isDragging ? NSColor.white : NSColor(white: 0.8, alpha: 1)).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4).fill()
        Theme.windowBackground.setFill()
        NSRect(x: handle.midX - 1, y: handle.minY + 5, width: 2, height: handle.height - 10).fill()
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        springTimer?.invalidate()
        springTimer = nil
        isDragging = true
        if handleFrame.contains(p) {
            grabOffset = p.x - handleFrame.midX
        } else {
            grabOffset = 0
            update(progress: progress(forX: p.x))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        update(progress: progress(forX: p.x - grabOffset))
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag()
    }

    /// 松手：过 97% 就提交（tbar(1)）并回弹，否则停在原位。
    private func finishDrag() {
        guard isDragging else { return }
        isDragging = false
        if progress >= Self.commitThreshold {
            progress = 1
            onProgress?(1)
            springBack()
        }
        needsDisplay = true
    }

    /// 拖动中最多发 0.999：1 只在松手时发（1 = 提交，发两次会对调两次）。
    private func update(progress new: Double) {
        let quantized = min((new * 1000).rounded() / 1000, 0.999)
        guard quantized != progress else { return }
        progress = quantized
        onProgress?(quantized)
    }

    /// 提交后回弹到最左（约 150 ms）。
    private func springBack() {
        let start = Date()
        let from = progress
        springTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.springStep(start: start, from: from) }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func springStep(start: Date, from: Double) {
        let t = min(Date().timeIntervalSince(start) / 0.15, 1)
        progress = from * (1 - t)
        if t >= 1 {
            springTimer?.invalidate()
            springTimer = nil
        }
    }

    /// 测试用：模拟一次从 0 拖到 target 再松手。
    func simulateDrag(to target: Double) {
        isDragging = true
        var p = 0.0
        while p < target {
            p = min(p + 0.1, target)
            update(progress: p)
        }
        finishDrag()
    }
}
