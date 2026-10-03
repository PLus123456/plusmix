// 中列：转场按钮（Cut / Fade / Wipe / Zoom / Stinger / FTB）、时长（0.5 / 1 / 2 s + 自定义…）、Overlay 1–4 开关、T-bar 用哪种转场 + 参数…、T-bar、时钟。
// Wipe / Zoom / Stinger 在 W3-B 合入后（G4）接通：点 = setTransition(type, 当前时长) + autoTransition；类型留在状态里，T-bar 与回车按它推。
// 时长改的是唯一的 durationTicks，五种转场都用它（Cut 没有中间态）。参数经 TransitionParamsModel 发 setTransitionParams（提案 016，见那里的说明）。
// FTB 是开关；Overlay 开关：通道已指定输入 → 只改 on；没指定 → 用当前 PVW 那一路打开（W5-A / C6，原来开了也没画面）；关的时候不清空通道设置
// （W5-G：这条口径抽成 OverlayToggle，菜单栏"切换 › Overlay ▸"共用；按钮提示的反查口径抽成 HotkeyMatch，"切换"菜单右列共用）。
// 所有动作只发 Command，显示只读快照。
// W5-A（prompt 86）排版按 docs/ui-study/03-目视检查.md §1.3：每行宽 = 列宽 − 16、左对齐（原来的 alignment = .width 是 NSStackView 不支持的值，读回 0，等于没对齐）；
// 两档控件（主操作 regular 24 pt / 13 pt 字，次要控件 small 20 pt / 11 pt 字）；组内 4、组间 8、组标题到控件 2；列最小高 483 → ≤ 409。
// "最小步"（04-待拍板 Q01 默认：B 的最小一步，不改契约）：T-bar 上方那行是菜单，选 = 只发 setTransition（不执行）；类型被改了（点 Fade / 菜单 切换 › 类型
// 也会改）那一行高亮一阵；时长分段加"自定义…"；按钮提示从当前快捷键表反查（原来 Fade 写死"回车"，默认表里回车其实是"按已选转场"）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherControl

@MainActor
final class TransitionPanelView: NSView {
    var send: ((Command) -> Void)? {
        didSet { params.send = send }
    }
    /// 底栏提示（Overlay 空通道又没有 PVW 可用时说一句）。
    var onNotice: ((String) -> Void)?
    /// 当前快捷键表：按钮提示从它反查（换 session / 快捷键编辑器保存时设）。
    var hotkeyTable: HotkeyTable = .default {
        didSet { refreshTooltips() }
    }

    let cutButton: NSButton
    let fadeButton: NSButton
    let wipeButton: NSButton
    let zoomButton: NSButton
    let stingerButton: NSButton
    let ftbButton: NSButton
    let durationControl: NSSegmentedControl
    let paramsButton: NSButton
    /// T-bar 推的是哪种转场（= 状态里的 transition.type）：点开是类型菜单，选 = 只设、不执行。按钮上只写"Wipe ▾"：
    /// 这一行 134 pt，"T-bar · Stinger ▾"（106.5）加"参数…"（51）放不下；"T-bar 和回车用"写在提示、辅助功能标签和菜单的段标题里。
    let tbarTypeButton: NSButton
    /// "Overlay"组标题。
    let overlayHeader = Theme.label("Overlay", size: NSFont.systemFontSize(for: .small), color: Theme.dimText)
    /// Wipe / Stinger 参数（弹出面板的模型）。
    let params = TransitionParamsModel()
    private var paramsPopover: NSPopover?
    let overlayButtons: [NSButton]
    let tbar = TBarView(frame: .zero)
    let clock = ClockView(frame: .zero)

    /// 预设时长（秒）。
    static let durationPresets: [Double] = [0.5, 1, 2]
    /// 时长分段里"自定义…"那一段的下标。
    static let customSegment = durationPresets.count
    /// 自定义时长的范围（秒）。
    static let customDurationRange: ClosedRange<Double> = 0.1...10
    /// T-bar 菜单里列的类型（契约里的五种）。
    static let tbarTypes: [TransitionType] = [.cut, .fade, .wipe, .zoom, .stinger]
    /// 类型变了以后 T-bar 那一行高亮多久（秒）。
    static let typeHighlightSeconds: TimeInterval = 1.5
    private var frameRate: FrameRate = .fps60
    private var state = MixerState()
    /// 上一次显示的类型（nil = 还没收到快照）：变了就高亮那一行。
    private var shownType: TransitionType?
    private var typeHighlightTimer: Timer?
    /// T-bar 那一行正在高亮（类型刚被改过）。
    private(set) var isTbarTypeHighlighted = false
    /// 最近一次从这一列弹出的菜单（模态；测试开着时量位置、量完 cancelTracking）。
    private(set) var activeMenu: NSMenu?

    override init(frame: NSRect) {
        cutButton = Theme.button("Cut", target: nil, action: nil)
        fadeButton = Theme.toggleButton("Fade", target: nil, action: nil)
        wipeButton = Theme.button("Wipe", target: nil, action: nil)
        zoomButton = Theme.button("Zoom", target: nil, action: nil)
        stingerButton = Theme.button("Stinger", target: nil, action: nil)
        ftbButton = Theme.toggleButton("FTB", target: nil, action: nil)
        durationControl = NSSegmentedControl(labels: Self.durationPresets.map(Self.compactSeconds) + [L("transition.duration.customSegment")],
                                             trackingMode: .selectOne, target: nil, action: nil)
        paramsButton = Theme.button(L("transition.params"), target: nil, action: nil)
        tbarTypeButton = Theme.button(L("transition.tbarType", "Fade"), target: nil, action: nil)
        overlayButtons = (1...MixerState.overlayCount).map { Theme.toggleButton("\($0)", target: nil, action: nil) }
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor

        cutButton.target = self; cutButton.action = #selector(cutPressed)
        fadeButton.target = self; fadeButton.action = #selector(fadePressed)
        wipeButton.target = self; wipeButton.action = #selector(autoPressed(_:)); wipeButton.tag = 1
        zoomButton.target = self; zoomButton.action = #selector(autoPressed(_:)); zoomButton.tag = 2
        stingerButton.target = self; stingerButton.action = #selector(autoPressed(_:)); stingerButton.tag = 3
        ftbButton.target = self; ftbButton.action = #selector(ftbPressed)
        durationControl.target = self; durationControl.action = #selector(durationChanged)
        durationControl.translatesAutoresizingMaskIntoConstraints = false
        durationControl.segmentDistribution = .fillProportionally
        durationControl.setAccessibilityLabel(L("transition.durationLabel"))
        durationControl.cell?.setAccessibilityLabel(L("transition.durationLabel"))
        durationControl.setToolTip(L("transition.duration.customTip"), forSegment: Self.customSegment)
        paramsButton.target = self; paramsButton.action = #selector(paramsPressed)
        paramsButton.toolTip = L("transition.params.title")
        tbarTypeButton.target = self; tbarTypeButton.action = #selector(tbarTypePressed)
        tbarTypeButton.alignment = .left
        tbarTypeButton.setAccessibilityLabel(L("transition.tbarTypeAX", L("transition.type.fade")))
        for (i, b) in overlayButtons.enumerated() {
            b.tag = i + 1
            b.target = self
            b.action = #selector(overlayPressed(_:))
        }
        // 两档控件：次要控件 small 20 pt、配 small 字号 11 pt（原来只改 controlSize、字还是 13 pt，字挤）
        let smallFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        for c in [durationControl, paramsButton, tbarTypeButton] + overlayButtons as [NSControl] {
            c.controlSize = .small
            c.font = smallFont
        }
        tbar.onProgress = { [weak self] p in self?.send?(.tbar(progress: p)) }

        let overlayRow = NSStackView(views: overlayButtons)
        overlayRow.orientation = .horizontal
        overlayRow.spacing = 4
        overlayRow.distribution = .fillEqually
        overlayRow.translatesAutoresizingMaskIntoConstraints = false

        // "Wipe ▾  [参数…]"：类型菜单靠左、吃掉剩下的宽度，参数…靠右
        tbarTypeButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tbarTypeButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        paramsButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        paramsButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let tbarRow = NSStackView(views: [tbarTypeButton, paramsButton])
        tbarRow.orientation = .horizontal
        tbarRow.spacing = 4
        tbarRow.distribution = .fill
        tbarRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [cutButton, fadeButton, wipeButton, zoomButton, stingerButton, ftbButton,
                                        durationControl, overlayHeader, overlayRow, tbarRow, tbar, clock])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 4                                   // 组内
        stack.setCustomSpacing(8, after: stingerButton)     // 组间：转场 | FTB | 时长 | Overlay | T-bar
        stack.setCustomSpacing(8, after: ftbButton)
        stack.setCustomSpacing(8, after: durationControl)
        stack.setCustomSpacing(2, after: overlayHeader)     // 组标题到控件
        stack.setCustomSpacing(8, after: overlayRow)
        stack.setCustomSpacing(4, after: tbarRow)
        stack.setCustomSpacing(4, after: tbar)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // 每一行都和列一样宽（减左右内边距）：可见的左右边一律落在 8 和列宽 − 8
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        overlayRow.setHuggingPriority(.defaultHigh, for: .vertical)
        tbarRow.setHuggingPriority(.defaultHigh, for: .vertical)
        tbar.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)   // 多出来的高度都给 T-bar
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Theme.transitionColumnWidth),
            tbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            clock.heightAnchor.constraint(equalToConstant: 56),
        ])
        refreshTooltips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 快照 → 按钮状态。
    func apply(state: MixerState) {
        let previous = self.state
        self.state = state
        frameRate = state.format.frameRate
        Theme.setHighlighted(ftbButton, state.ftb.on, color: Theme.ftbActive)
        Theme.setHighlighted(fadeButton, state.transition.isActive && state.transition.type == .fade)
        Theme.setHighlighted(wipeButton, state.transition.isActive && state.transition.type == .wipe)
        Theme.setHighlighted(zoomButton, state.transition.isActive && state.transition.type == .zoom)
        Theme.setHighlighted(stingerButton, state.transition.isActive && state.transition.type == .stinger)
        updateDurationControl()
        for (i, b) in overlayButtons.enumerated() {
            Theme.setHighlighted(b, state.overlays[i].on)
        }
        tbar.apply(state: state)
        updateTbarType()
        if previous.overlays.map(\.input) != state.overlays.map(\.input) { refreshTooltips() }
        params.apply(state: state)
    }

    // MARK: T-bar 用哪种转场

    /// T-bar 那一行的文字（测试看）。
    var tbarTypeText: String { tbarTypeButton.title }

    private func updateTbarType() {
        let type = state.transition.type
        let name = L("transition.type.\(type.rawValue)")
        let title = L("transition.tbarType", name)
        if tbarTypeButton.title != title {
            tbarTypeButton.title = title
            tbarTypeButton.setAccessibilityLabel(L("transition.tbarTypeAX", name))
            if isTbarTypeHighlighted { Theme.setTitleColor(tbarTypeButton, .white) }
        }
        if let shown = shownType, shown != type { highlightTbarType() }
        shownType = type
    }

    /// 类型被改了：那一行高亮一阵（点 Fade、菜单 切换 › 类型、API 改的都算），提醒 T-bar 和回车已经换了转场。
    private func highlightTbarType() {
        isTbarTypeHighlighted = true
        Theme.setHighlighted(tbarTypeButton, true)
        typeHighlightTimer?.invalidate()
        let timer = Timer(timeInterval: Self.typeHighlightSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTbarTypeHighlighted = false
                Theme.setHighlighted(self.tbarTypeButton, false)
                self.typeHighlightTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        typeHighlightTimer = timer
    }

    /// T-bar 类型菜单：五种类型、当前的打勾；选 = 只发 setTransition（不执行）；转场进行中不可选（状态机会拒）。
    func tbarTypeMenu() -> NSMenu {
        let menu = NSMenu(title: L("transition.tbarTypeMenu.header"))
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: L("transition.tbarTypeMenu.header")))
        for type in Self.tbarTypes {
            let item = NSMenuItem(title: L("transition.type.\(type.rawValue)"), action: #selector(tbarTypePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type.rawValue
            item.state = state.transition.type == type ? .on : .off
            item.isEnabled = !state.transition.isActive
            menu.addItem(item)
        }
        return menu
    }

    @objc private func tbarTypePressed() {
        let menu = tbarTypeMenu()
        activeMenu = menu
        ScreenMenu.popUpBelow(menu, tbarTypeButton)
    }

    @objc private func tbarTypePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let type = TransitionType(rawValue: raw), !state.transition.isActive else { return }
        send?(.setTransition(type: type, durationTicks: state.transition.durationTicks))
    }

    // MARK: 时长

    /// 预设秒数换成拍数（按标称帧率取整：59.94 → 60）。
    func ticks(forSeconds seconds: Double) -> Int {
        Int((seconds * Double(frameRate.nominalFramesPerSecond)).rounded())
    }

    private var currentSeconds: Double { Double(state.transition.durationTicks) / Double(frameRate.nominalFramesPerSecond) }

    private static func presetIndex(_ seconds: Double) -> Int? { durationPresets.firstIndex { abs($0 - seconds) < 0.01 } }

    /// "0.75"、"1.5"、"2"：最多两位小数、去掉末尾的 0。
    static func secondsText(_ seconds: Double) -> String {
        var text = String(format: "%.2f", (seconds * 100).rounded() / 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 分段上的写法："0.5s"、"1s"、"0.75s"。
    static func compactSeconds(_ seconds: Double) -> String { secondsText(seconds) + "s" }

    /// 时长分段跟快照：是预设就选那一段、最后一段写"…"（提示"自定义时长…"；写全"自定义…"四段要 168 pt，列里只有 134）；
    /// 不是预设就选最后一段、写实际值（X39：原来一段都不选，也看不出实际值）。
    private func updateDurationControl() {
        let seconds = currentSeconds
        let custom = Self.customSegment
        if let i = Self.presetIndex(seconds) {
            if durationControl.selectedSegment != i { durationControl.selectedSegment = i }
            setCustomSegment(label: L("transition.duration.customSegment"), tip: L("transition.duration.customTip"))
        } else {
            if durationControl.selectedSegment != custom { durationControl.selectedSegment = custom }
            setCustomSegment(label: Self.compactSeconds(seconds), tip: L("transition.duration.customCurrent", Self.secondsText(seconds)))
        }
    }

    private func setCustomSegment(label: String, tip: String) {
        let custom = Self.customSegment
        if durationControl.label(forSegment: custom) != label { durationControl.setLabel(label, forSegment: custom) }
        if durationControl.toolTip(forSegment: custom) != tip { durationControl.setToolTip(tip, forSegment: custom) }
    }

    @objc private func durationChanged() {
        let i = durationControl.selectedSegment
        if i == Self.customSegment {
            // 自定义那一段：弹菜单（当前的自定义值打勾 + "自定义…"），关掉后分段回到快照的样子
            let menu = customDurationMenu()
            activeMenu = menu
            ScreenMenu.popUpBelow(menu, durationControl)
            updateDurationControl()
            return
        }
        guard i >= 0, i < Self.durationPresets.count else { return }
        send?(.setTransition(type: state.transition.type, durationTicks: ticks(forSeconds: Self.durationPresets[i])))
    }

    /// 自定义时长的菜单：时长不是预设时第一项是"✓ 自定义：0.75 s"，下面"自定义…"打开输入框。
    func customDurationMenu() -> NSMenu {
        let menu = NSMenu(title: L("transition.durationLabel"))
        menu.autoenablesItems = false
        let seconds = currentSeconds
        if Self.presetIndex(seconds) == nil {
            let current = NSMenuItem(title: L("transition.duration.customCurrent", Self.secondsText(seconds)), action: nil, keyEquivalent: "")
            current.state = .on
            current.isEnabled = false
            menu.addItem(current)
        }
        let edit = NSMenuItem(title: L("transition.duration.customEllipsis"), action: #selector(promptCustomDuration), keyEquivalent: "")
        edit.target = self
        edit.isEnabled = !state.transition.isActive
        menu.addItem(edit)
        return menu
    }

    /// 输入自定义时长（秒），确定后发 setTransition（类型不变）。
    @objc private func promptCustomDuration() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("transition.duration.customTitle")
        alert.informativeText = L("transition.duration.customInfo", Self.secondsText(Self.customDurationRange.lowerBound), Self.secondsText(Self.customDurationRange.upperBound))
        let field = NSTextField(string: Self.secondsText(currentSeconds))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        field.setAccessibilityLabel(L("transition.durationLabel"))
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let seconds = Self.parseSeconds(field.stringValue) else { return }
                self?.applyCustomDuration(seconds: seconds)
            }
        }
    }

    /// 自定义时长（秒）→ setTransition（类型不变）；超出范围或转场进行中不发。
    func applyCustomDuration(seconds: Double) {
        guard Self.customDurationRange.contains(seconds), !state.transition.isActive else { return }
        send?(.setTransition(type: state.transition.type, durationTicks: max(1, ticks(forSeconds: seconds))))
    }

    /// "0.75"、"0,75"、" 1.5 " → 秒。
    static func parseSeconds(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// 测试入口：选第 i 个时长预设（= 点那一段）。
    func selectDurationPresetForTesting(_ i: Int) {
        durationControl.selectedSegment = i
        durationChanged()
    }

    // MARK: 提示（从快捷键表反查）

    private func refreshTooltips() {
        cutButton.toolTip = tip(L("transition.tip.cut"), matching: HotkeyMatch.cut)
        fadeButton.toolTip = tip(L("transition.tip.fade"), matching: HotkeyMatch.fade)
        for (button, name) in [(wipeButton, "Wipe"), (zoomButton, "Zoom"), (stingerButton, "Stinger")] {
            button.toolTip = tip(L("transition.tip.auto", name, name), matching: { _ in false })
        }
        ftbButton.toolTip = tip(L("transition.tip.ftb"), matching: HotkeyMatch.ftb)
        let autoKeys = HotkeyText.keys(in: hotkeyTable, matching: HotkeyMatch.auto)
        tbarTypeButton.toolTip = autoKeys.map { L("transition.tip.tbarTypeKeys", L("transition.tip.tbarType"), $0) } ?? L("transition.tip.tbarType")
        for (i, b) in overlayButtons.enumerated() {
            let channel = i + 1
            let description = state.overlays[i].input.map { L("transition.overlayInput", channel, $0) } ?? L("transition.overlayNoInput", channel, channel)
            b.toolTip = tip(description, matching: HotkeyMatch.overlay(channel))
        }
    }

    /// "说明\n快捷键：空格、⇧C"；表里没有绑定就写"没有快捷键"。
    private func tip(_ description: String, matching match: (ControlAction) -> Bool) -> String {
        guard let keys = HotkeyText.keys(in: hotkeyTable, matching: match) else { return L("transition.tip.noKeys", description) }
        return L("transition.tip.withKeys", description, keys)
    }

    // MARK: 按钮

    @objc private func cutPressed() { send?(.cut) }

    @objc private func fadePressed() { send?(.fade(durationTicks: state.transition.durationTicks)) }

    /// Wipe / Zoom / Stinger：先把类型（时长不变）写进状态，再起 auto 转场；之后 T-bar 也按这个类型推（G4 接通）。
    @objc private func autoPressed(_ sender: NSButton) {
        let type: TransitionType = sender.tag == 1 ? .wipe : (sender.tag == 2 ? .zoom : .stinger)
        send?(.setTransition(type: type, durationTicks: state.transition.durationTicks))
        send?(.autoTransition)
    }

    @objc private func ftbPressed() { send?(.ftb(on: !state.ftb.on)) }

    /// 参数弹出面板的内容视图（开着时；测试看）。
    var paramsPopoverContentView: NSView? { paramsPopover?.isShown == true ? paramsPopover?.contentViewController?.view : nil }

    /// 参数…：Wipe 方向 / 软边、Stinger 输入 / 换底拍的弹出面板。
    @objc private func paramsPressed() {
        if let paramsPopover, paramsPopover.isShown {
            paramsPopover.close()
            return
        }
        let popover = NSPopover()
        let host = NSHostingController(rootView: TransitionParamsView(model: params))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.show(relativeTo: paramsButton.bounds, of: paramsButton, preferredEdge: .maxX)
        paramsPopover = popover
    }

    /// Overlay n（菜单栏"切换 › Overlay ▸"同一口径，OverlayToggle）。
    @objc private func overlayPressed(_ sender: NSButton) {
        switch OverlayToggle.command(channel: sender.tag, in: state) {
        case .send(let command)?: send?(command)
        case .needsPreview?: onNotice?(L("transition.overlayNeedsPreview", sender.tag, sender.tag))
        case nil: break
        }
    }
}

/// Overlay n 开关按下去发什么（转场列按钮与菜单栏"切换 › Overlay ▸"共用，C6）：开着 → 关（通道设置不清空）；关着、通道已指定输入 → 开；
/// 没指定 → 用当前 PVW 那一路开；PVW 也是黑场 → 不开（needsPreview，调用方提示）。通道号不对为 nil。
enum OverlayToggle: Equatable {
    case send(Command)
    case needsPreview

    static func command(channel: Int, in state: MixerState) -> OverlayToggle? {
        guard channel >= 1, channel <= MixerState.overlayCount else { return nil }
        let overlay = state.overlays[channel - 1]
        if overlay.on || overlay.input != nil { return .send(.overlay(channel: channel, on: !overlay.on, input: nil)) }
        let preview = state.preview
        guard preview != MixerState.noInput, state.input(preview) != nil else { return .needsPreview }
        return .send(.overlay(channel: channel, on: true, input: preview))
    }
}
