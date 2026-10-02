// T-bar：自绘 NSView。拖动手柄发 tbar(progress)（0 = 底，1 = 顶）；松手时到顶就提交（发 tbar(1)，状态机对调）并回弹到底，
// 没到顶就停在原位（真推杆的行为）。不拖的时候跟着快照走（auto 转场时能看到它自己往上走）。
import AppKit
import SwitcherContracts

@MainActor
final class TBarView: NSView {
    /// 拖动时每次位置变化都调（去重后）；松手到顶时最后一次是 1。
    var onProgress: ((Double) -> Void)?
    /// 当前显示的位置 0–1。
    private(set) var progress: Double = 0 {
        didSet { needsDisplay = true }
    }
    private(set) var isDragging = false
    private var grabOffset: CGFloat = 0
    private var springTimer: Timer?
    /// 松手时视为"到顶"的阈值。
    static let commitThreshold = 0.97
    static let handleHeight: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// 快照来了：不在拖动就把位置同步到转场进度（空闲 = 0）。
    func apply(state: MixerState) {
        guard !isDragging, springTimer == nil else { return }
        progress = state.transition.isActive ? state.transition.progress : 0
    }

    // MARK: 几何

    private var trackRect: NSRect {
        let inset: CGFloat = Self.handleHeight / 2 + 4
        return NSRect(x: bounds.midX - 3, y: inset, width: 6, height: max(1, bounds.height - 2 * inset))
    }

    /// 把手与列里的按钮同宽（W5-A：原来左右各缩 6，比按钮窄 12）。
    private var handleRect: NSRect {
        let track = trackRect
        let y = track.minY + CGFloat(progress) * track.height
        return NSRect(x: 0, y: y - Self.handleHeight / 2, width: bounds.width, height: Self.handleHeight)
    }

    /// 把手的位置（测试量左右边）。
    var handleFrame: NSRect { handleRect }

    private func progress(forY y: CGFloat) -> Double {
        let track = trackRect
        return Double(min(max((y - track.minY) / track.height, 0), 1))
    }

    // MARK: 画

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        let track = trackRect
        Theme.divider.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        // 已推过的部分
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width, height: CGFloat(progress) * track.height)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        // 刻度：0 / 25 / 50 / 75 / 100
        Theme.dimText.setFill()
        for k in 0...4 {
            let y = track.minY + track.height * CGFloat(k) / 4
            NSRect(x: track.minX - 5, y: y - 0.5, width: track.width + 10, height: 1).fill()
        }
        let handle = handleRect
        (isDragging ? NSColor.white : NSColor(white: 0.8, alpha: 1)).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4).fill()
        Theme.windowBackground.setFill()
        NSRect(x: handle.minX + 6, y: handle.midY - 1, width: handle.width - 12, height: 2).fill()
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        springTimer?.invalidate()
        springTimer = nil
        isDragging = true
        if handleRect.contains(p) {
            grabOffset = p.y - (trackRect.minY + CGFloat(progress) * trackRect.height)
        } else {
            grabOffset = 0
            update(progress: progress(forY: p.y))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        update(progress: progress(forY: p.y - grabOffset))
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag()
    }

    /// 松手：到顶就提交（tbar(1)）并回弹，否则停在原位。
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

    /// 提交后回弹到底（约 150 ms）。
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
