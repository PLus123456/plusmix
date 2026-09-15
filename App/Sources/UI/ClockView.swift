// 时钟：24 小时制大字 + 12 小时制小字，每秒对齐整秒刷新。
import AppKit

@MainActor
final class ClockView: NSView {
    private let big = Theme.monoLabel("00:00:00", size: 22, color: .white)
    private let small = Theme.monoLabel("", size: 12, color: Theme.dimText)
    private var timer: Timer?
    private let f24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let f12: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "hh:mm a"
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 2
        big.alignment = .center
        small.alignment = .center
        addSubview(big)
        addSubview(small)
        NSLayoutConstraint.activate([
            big.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            big.centerXAnchor.constraint(equalTo: centerXAnchor),
            small.topAnchor.constraint(equalTo: big.bottomAnchor, constant: 2),
            small.centerXAnchor.constraint(equalTo: centerXAnchor),
            small.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
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
}
