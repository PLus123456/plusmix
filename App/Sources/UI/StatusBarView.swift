// 状态行（W5-F，01a E9 / 03 V-22 / 04 Q45）：窗口最底一行、全宽，原来塞在底栏按钮下面（上下留白 6 / 24 / 10 / 14 / 4 不对称、左沿差 2 pt）。
// 左边是 Stats 算出来的那一行（StatusLineFormatter，铁律 4：和 stats.jsonl 同一秒逐字一致）；右端是提示文字（命令被忽略、录制起停、重连……几秒后清掉），
// 平时显示本机信息"芯片 · 内存"（纯本机、启动时取一次，不进 Stats，Q45）。左右各留 10 pt，两段文字都上下居中；顶上一条 1 pt 分隔线。
import AppKit
import Darwin

@MainActor
final class StatusBarView: NSView {
    let statusLabel = Theme.monoLabel("", size: 11, color: Theme.dimText)
    let noticeLabel = Theme.label("", size: 11, color: Theme.dimText)
    /// 左右留白（两边一样）。
    static let padding: CGFloat = 10
    /// 正在显示的提示（没有为空串；本机信息不算提示）。
    private(set) var notice = ""
    private let divider = PanelView(color: Theme.divider)

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
        // 窄窗口时先截提示 / 本机信息，状态那一行（Stats）尽量完整
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        noticeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(divider)
        addSubview(statusLabel)
        addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            noticeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            noticeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 16),
        ])
        showNotice("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 右端：有提示写提示（强调色），空串 = 回到本机信息（暗灰）。
    func showNotice(_ text: String) {
        notice = text
        noticeLabel.stringValue = text.isEmpty ? Self.machineInfo : text
        noticeLabel.textColor = text.isEmpty ? Theme.dimText : Theme.accent
        noticeLabel.toolTip = text.isEmpty ? nil : text
    }
}
