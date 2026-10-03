// PVW / PGM 监视器：标题条（编号、名字、tally 色）+ MetalDisplayView（全速，跟显示器刷新率）。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class MonitorView: NSView {
    let target: DisplayTarget
    let display = MetalDisplayView(frame: .zero)
    private let titleBar = PanelView(color: Theme.tallyOff)
    private let numberLabel = Theme.monoLabel("—", size: 14, color: .white)
    private let nameLabel = Theme.label("", size: 13, weight: .semibold, color: .white)
    private let roleLabel = Theme.label("", size: 11, weight: .bold, color: .white)
    /// 标题条右端的齿轮（W5-G）。
    let gearButton = NSButton(title: "", target: nil, action: nil)
    /// PGM 标题条上的叠加徽标（W5-G）。
    private(set) var overlayBadgeViews: [NSView] = []

    init(target: DisplayTarget) {
        self.target = target
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        display.target = target
        display.translatesAutoresizingMaskIntoConstraints = false
        roleLabel.stringValue = target == .program ? "PGM" : "PVW"
        titleBar.backgroundColor = target == .program ? Theme.tallyProgram : Theme.tallyPreview
        addSubview(titleBar)
        addSubview(display)
        titleBar.addSubview(numberLabel)
        titleBar.addSubview(nameLabel)
        titleBar.addSubview(roleLabel)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Theme.monitorTitleHeight),
            display.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            display.leadingAnchor.constraint(equalTo: leadingAnchor),
            display.trailingAnchor.constraint(equalTo: trailingAnchor),
            display.bottomAnchor.constraint(equalTo: bottomAnchor),
            numberLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 8),
            numberLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: roleLabel.leadingAnchor, constant: -8),
            roleLabel.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -8),
            roleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 标题条内容：编号 + 名字；0 = 黑场。
    func apply(state: MixerState) {
        let number = target == .program ? state.program : state.preview
        if number == MixerState.noInput {
            numberLabel.stringValue = "—"
            nameLabel.stringValue = L("monitor.black")
        } else {
            numberLabel.stringValue = "\(number)"
            nameLabel.stringValue = state.input(number)?.name ?? L("monitor.missingInput", number)
        }
        if target == .program, state.ftb.on {
            roleLabel.stringValue = "PGM · FTB"
        } else {
            roleLabel.stringValue = target == .program ? "PGM" : "PVW"
        }
    }

    var overlayBadgeTexts: [String] { [] }
    var roleText: String { roleLabel.stringValue }

    var displayedNumber: String { numberLabel.stringValue }
    var displayedName: String { nameLabel.stringValue }
}
