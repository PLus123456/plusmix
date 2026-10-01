// 时钟：24 小时制大字 + 12 小时制小字，每秒对齐整秒刷新。
// W5-A（03-目视检查.md §1.3 第 6 条、V-08）：56 pt 高、1 pt 分隔线色边框、圆角 6、字号 20 / 11（原来 2 pt 白框是整列最"响"的东西）；
// 12 小时制按界面语言的 hmma 模板排（中文"上午12:13"，英文"12:13 PM"；原来写死 "hh:mm a" 成了"12:13 上午"）。
import AppKit

@MainActor
final class ClockView: NSView {
    private let big = Theme.monoLabel("00:00:00", size: 20, color: .white)
    private let small = Theme.monoLabel("", size: 11, color: Theme.dimText)
    private var timer: Timer?
    private let f24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let f12: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("hmma")
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        big.alignment = .center
        small.alignment = .center
        let lines = NSStackView(views: [big, small])
        lines.orientation = .vertical
        lines.alignment = .centerX
        lines.spacing = 1
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            lines.centerXAnchor.constraint(equalTo: centerXAnchor),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        tick()
        scheduleAligned()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func scheduleAligned() {
        timer?.invalidate()
        let now = Date()
        let next = ceil(now.timeIntervalSince1970) + 0.005
        let t = Timer(fire: Date(timeIntervalSince1970: next), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = Date()
        big.stringValue = f24.string(from: now)
        small.stringValue = f12.string(from: now)
    }

    var displayedTime: String { big.stringValue }
    /// 12 小时制那一行用的格式（测试看）。
    var twelveHourFormat: String { f12.dateFormat }
}
