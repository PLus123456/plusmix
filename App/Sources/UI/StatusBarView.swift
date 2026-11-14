// 状态行（W5-F，01a E9 / 03 V-22 / 04 Q45）：窗口最底一行、全宽，原来塞在底栏按钮下面（上下留白 6 / 24 / 10 / 14 / 4 不对称、左沿差 2 pt）。
// 左边是 Stats 算出来的那一行（StatusLineFormatter，铁律 4：和 stats.jsonl 同一秒逐字一致）；右端是提示文字（命令被忽略、录制起停、重连……几秒后清掉），
// 平时显示本机信息"芯片 · 内存"（纯本机、启动时取一次，不进 Stats，Q45）。左右各留 10 pt，两段文字都上下居中；顶上一条 1 pt 分隔线。
// W5-L（N02）：提示文字左边是提醒条（琥珀底黑字，有提醒才出现：没在录 / 推、FTB 开着、Master 过低），窄窗口时先截提示、再截状态那一行、最后才截提醒。
// W6-A（docs/spec/大屏与时间线方案.md §2.1 规则 9）：中间那一列收起时钟时，时间改在状态行最右端用小字显示（clockLabel，HH:mm:ss，每秒对齐整秒刷新）；
// 列里有时钟时藏起来、不占位。只加这一样，状态行别的不动。
import AppKit
import Darwin

@MainActor
final class StatusBarView: NSView {
    let statusLabel = Theme.monoLabel("", size: 11, color: Theme.dimText)
    let noticeLabel = Theme.label("", size: 11, color: Theme.dimText)
    /// 提醒条（W5-L，N02）：没有提醒时藏起来。
    let reminderView = PanelView(color: Theme.reminderBackground)
    private let reminderLabel = Theme.label("", size: 11, weight: .semibold, color: Theme.reminderText)
    /// 提醒条上的字（没有提醒为空串）。
    var reminderText: String { reminderView.isHidden ? "" : reminderLabel.stringValue }
    /// 左右留白（两边一样）。
    static let padding: CGFloat = 10
    /// 正在显示的提示（没有为空串；本机信息不算提示）。
    private(set) var notice = ""
    private let divider = PanelView(color: Theme.divider)
    /// 中间那一列收起时钟时的小字时间（W6-A）：最右端，平时藏着。
    let clockLabel = Theme.monoLabel("", size: 10, color: Theme.dimText)
    private var clockTimer: Timer?
    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    /// 状态行上显示的时间（藏着为空串）。
    var displayedClock: String { clockLabel.isHidden ? "" : clockLabel.stringValue }

    /// 本机信息："Apple M5 Max · 128 GB"（芯片名取 sysctl machdep.cpu.brand_string，内存取 physicalMemory，按 2^30 取整）。
    static let machineInfo: String = {
        var size = 0
        var chip = "Mac"
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                chip = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return L("status.machine", chip, gb)
    }()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBackground.cgColor
        statusLabel.setAccessibilityLabel(L("bottom.statusLine"))
        noticeLabel.setAccessibilityLabel(L("bottom.notice"))
        statusLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.alignment = .right
        // 窄窗口时先截提示 / 本机信息，状态那一行（Stats）尽量完整；提醒条比状态行还优先（只在出问题时出现）
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        noticeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        reminderLabel.lineBreakMode = .byTruncatingTail
        reminderLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultHigh.rawValue + 1), for: .horizontal)
        reminderLabel.setAccessibilityLabel(L("reminder.a11y"))
        reminderView.layer?.cornerRadius = 3
        reminderView.addSubview(reminderLabel)
        reminderView.isHidden = true
        // 提醒条与提示一组靠右：藏起来的提醒条不占位（NSStackView 默认 detachesHiddenViews）
        clockLabel.isHidden = true
        clockLabel.setAccessibilityLabel(L("status.clock.a11y"))
        clockLabel.toolTip = L("status.clock.tip")
        clockLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultHigh.rawValue + 1), for: .horizontal)
        clockLabel.setContentHuggingPriority(.required, for: .horizontal)
        let right = NSStackView(views: [reminderView, noticeLabel, clockLabel])
        right.orientation = .horizontal
        right.spacing = 10
        right.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        addSubview(statusLabel)
        addSubview(right)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 16),
            reminderLabel.leadingAnchor.constraint(equalTo: reminderView.leadingAnchor, constant: 6),
            reminderLabel.trailingAnchor.constraint(equalTo: reminderView.trailingAnchor, constant: -6),
            reminderLabel.centerYAnchor.constraint(equalTo: reminderView.centerYAnchor),
            reminderView.heightAnchor.constraint(equalToConstant: Theme.statusBarHeight - 5),
        ])
        showNotice("")
    }

    /// 提醒条：给几句就显示几句（"⚠︎ 甲 · 乙"），空数组 = 藏起来。没变不动（每秒都会调）。
    func showReminders(_ texts: [String]) {
        let text = texts.isEmpty ? "" : L("reminder.prefix") + texts.joined(separator: L("reminder.separator"))
        if reminderView.isHidden != texts.isEmpty { reminderView.isHidden = texts.isEmpty }
        if reminderLabel.stringValue != text {
            reminderLabel.stringValue = text
            reminderView.toolTip = text.isEmpty ? nil : text
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 时钟收进状态行 / 回到中间那一列（W6-A）：显示时每秒对齐整秒刷新，藏起来时停。
    func setClockShown(_ shown: Bool) {
        guard shown == clockLabel.isHidden else { return }
        clockLabel.isHidden = !shown
        clockTimer?.invalidate()
        clockTimer = nil
        guard shown else { return }
        tickClock()
        let next = ceil(Date().timeIntervalSince1970) + 0.005
        let timer = Timer(fire: Date(timeIntervalSince1970: next), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func tickClock() {
        let text = clockFormatter.string(from: Date())
        if clockLabel.stringValue != text { clockLabel.stringValue = text }
    }

    /// 右端：有提示写提示（强调色），空串 = 回到本机信息（暗灰）。
    func showNotice(_ text: String) {
        notice = text
        noticeLabel.stringValue = text.isEmpty ? Self.machineInfo : text
        noticeLabel.textColor = text.isEmpty ? Theme.dimText : Theme.accent
        noticeLabel.toolTip = text.isEmpty ? nil : text
    }
}
