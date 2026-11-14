// 中列（W5-M，prompt 100；docs/ui-study/01-菜单逻辑.md §3.3、01a C1–C4 / C7 / C8、04 Q01 A / Q05 (a) / Q07 (a) / Q37 (a)）：
//   Cut ｜ 转场 1–4（主体 + ▾）｜ FTB（主体 + ▾）｜ Overlay 1–4 ｜ "T-bar"组：弹出菜单（当前槽）、当前槽的时长分段、横放的 T-bar ｜ 时钟。
// 转场 1–4 = 提案 020 的四个槽（出厂 1 Fade 0.5 s、2 Wipe 1 s、3 Zoom 1 s、4 Stinger 1 s，与原来四个固定按钮等价）：
//   主体 = useTransitionSlot(n, start: true)：一拍内选中并开始；按钮上的字 = 槽的效果与时长；执行中蓝底；当前槽（T-bar / 回车用的）左边常亮一条。
//   Stinger 槽没选输入时点主体 = 弹出这个槽的输入选择、不执行（X18：不然是一次延迟硬切）。
//   ▾ 或右键主体 = 菜单：效果单选（Cut / Fade / Zoom / Wipe 五向平铺 / Stinger：输入 ▸）、时长 0.5 / 1 / 2 秒 / 自定义…、参数…、
//   用于 T-bar（不执行）= useTransitionSlot(n, start: false)、恢复出厂；只改配置不执行（setTransitionSlot，进行中也收），当前项打勾。
//   菜单列 Cut（用户 2026-10-03 定）：T-bar 推 Cut 没有过渡、推到顶才切，菜单项写明。
// T-bar 那一行是弹出菜单：列四个槽，点了就做（用户 2026-10-10 裁定：useTransitionSlot(n, start: true)；"只选不执行"只留在每个槽的 ▾ 里）。
// 时长分段 = 当前槽的时长（改它 = setTransitionSlot(当前槽)；当前那组不在槽里时 = setTransition）。FTB 的 ▾ / 右键 = FTB 自己的时长（setFTBDuration）。
// T-bar 横放（TBarView）：左 0 右 1，过 97% 松手提交后回弹。转场 / FTB 都不在转场中置灰：一条原子命令，进行中状态机自己忽略（格子上的"转场 / Cut"
// 是 setPreview + 转场两条，进行中必须灰，那是 InputCellView 的事）。
// 排版沿用 W5-A（prompt 86，03-目视检查.md §1.3）：每行宽 = 列宽 − 16、左对齐，所有可见边落在 8…列宽 − 8；两档控件（主操作 regular 24 pt / 13 pt 字，
// 次要控件 small 20 pt / 11 pt 字）；组内 4、组间 8、组标题到控件 2。T-bar 横放后不再吃剩下的高度：多出来的高度给 T-bar 与时钟之间的空白。
// Overlay 开关的口径（OverlayToggle）与按钮提示的反查口径（HotkeyMatch）和菜单栏"切换"共用。所有动作只发 Command，显示只读快照。
// W6-A（docs/spec/大屏与时间线方案.md §2.1 规则 9）：这一列按高度分四档自动收放——全 → 不带时钟 → 紧凑（再收"当前槽"和"时长"两行，每个槽的 ▾ 里都有）
// → 最小（再收 T-bar，只留 Cut、转场 1–4、FTB、叠加）。哪一档由主窗口按排布算（MainLayoutModel），各档的高用 fittingSize 量（fittingHeight(of:)，
// 先量好存着：T-bar 下面那行提示出没时重量、告诉主窗口重排），不写死。收起时钟时时间改在状态行右端（StatusBarView.setClockShown）。
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
    /// Overlay k 的右键"叠加设置…"：打开叠加设置窗并停在第 k 路（W5-K / I1）。
    var onOverlaySettings: ((Int) -> Void)?
    /// 当前快捷键表：按钮提示从它反查（换 session / 快捷键编辑器保存时设）。
    var hotkeyTable: HotkeyTable = .default {
        didSet { refreshTooltips(force: true) }
    }

    let cutButton: NSButton
    /// 转场 1–4。
    let slotButtons: [ColumnSplitButton]
    /// FTB：主体开关 + ▾ 时长菜单。
    let ftbSplit: ColumnSplitButton
    /// FTB 的主体（开关）。
    var ftbButton: NSButton { ftbSplit.bodyButton }
    /// "Overlay"组标题。
    let overlayHeader = Theme.label("Overlay", size: NSFont.systemFontSize(for: .small), color: Theme.dimText)
    let overlayButtons: [NSButton]
    /// "T-bar"组标题。
    let tbarHeader = Theme.label("T-bar", size: NSFont.systemFontSize(for: .small), color: Theme.dimText)
    /// T-bar 和回车用哪个槽："转场 2 · Wipe → 1 秒 ▾"；点开 = 四个槽（点了就做）。整行"T-bar：转场 2 · Wipe 1 秒 ▾"在 small 下要 161 pt、这一行只有 134，
    /// 所以"T-bar"挪到上面的组标题。自定义时长这类长的会截尾，提示与辅助功能标签写全。
    let tbarSlotButton: NSButton
    /// 当前槽的时长：0.5 / 1 / 2 s + "…"（自定义）。
    let durationControl: NSSegmentedControl
    /// Wipe / Stinger 参数（弹出面板的模型；按槽编辑）。
    let params = TransitionParamsModel()
    private var paramsPopover: NSPopover?
    let tbar = TBarView(frame: .zero)
    /// T-bar 下面那一行提示（当前槽是没选输入的 Stinger 时："转场 n 是 Stinger、还没选输入"；平时藏着、不占高度）。
    let tbarHint = Theme.label("", size: NSFont.systemFontSize(for: .small), color: .systemOrange)
    let clock = ClockView(frame: .zero)
    /// T-bar 与时钟之间的空白（列里多出来的高度都给它）。
    private let spacer = NSView()
    /// 整列的竖排（换档时改"叠加那一行之后"的组间距）与叠加那一行。
    private var stack: NSStackView!
    private var overlayRow: NSStackView!

    /// 中间那一列的四档（规则 9）：全 → 不带时钟 → 紧凑 → 最小。
    enum ColumnTier: Int, CaseIterable, Comparable {
        case full, noClock, compact, minimal
        static func < (a: ColumnTier, b: ColumnTier) -> Bool { a.rawValue < b.rawValue }
    }
    /// 现在这一档。
    private(set) var tier: ColumnTier = .full
    /// 时钟在列里（全档）。
    var isClockShown: Bool { tier == .full }
    /// 各档的高（fittingSize 量的，下标 = 档）：T-bar 下面那行提示出没 / 换字时重量。
    private var tierHeights: [CGFloat] = []
    /// 各档的高变了（提示出没）：主窗口重排。
    var onTierHeightsChange: (() -> Void)?
    /// 现在这一档变了（时钟出没）：主窗口把时间挪到状态行 / 挪回来。
    var onTierChange: ((ColumnTier) -> Void)?
    /// T-bar 下面那行提示该不该出来（当前槽是没选输入的 Stinger；最小档没有 T-bar，提示也不出）。
    private var hintWanted = false

    /// 预设时长（秒）：转场槽、时长分段、FTB 共用。
    static let durationPresets: [Double] = [0.5, 1, 2]
    /// 时长分段里"自定义…"那一段的下标。
    static let customSegment = durationPresets.count
    /// 自定义时长的范围（秒）。
    static let customDurationRange: ClosedRange<Double> = 0.1...10
    /// 当前槽变了以后 T-bar 那一行高亮多久（秒）。
    static let slotHighlightSeconds: TimeInterval = 1.5
    private var frameRate: FrameRate = .fps60
    private var state = MixerState()
    /// 上一次显示的当前槽与当前那组（nil = 还没收到快照）：变了就高亮那一行。
    private var shownCurrent: CurrentKey?
    private var highlightTimer: Timer?
    /// T-bar 那一行正在高亮（当前槽 / 当前那组刚被换掉）。
    private(set) var isTbarSlotHighlighted = false
    /// 最近一次从这一列弹出的菜单（模态；测试开着时量位置、量完 cancelTracking）。
    private(set) var activeMenu: NSMenu?
    /// 上一次刷新提示时的状态（提示只在这些变了时重写，不每帧设 toolTip）。
    private var tooltipKey: TooltipKey?

    override init(frame: NSRect) {
        cutButton = Theme.button("Cut", target: nil, action: nil)
        slotButtons = TransitionSlot.indexRange.map { ColumnSplitButton(title: "", menuLabel: L("slot.menuA11y", $0)) }
        ftbSplit = ColumnSplitButton(title: "FTB", menuLabel: L("ftb.menuA11y"))
        tbarSlotButton = Theme.button("", target: nil, action: nil)
        durationControl = NSSegmentedControl(labels: Self.durationPresets.map(Self.compactSeconds) + [L("transition.duration.customSegment")],
                                             trackingMode: .selectOne, target: nil, action: nil)
        overlayButtons = (1...MixerState.overlayCount).map { Theme.toggleButton("\($0)", target: nil, action: nil) }
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor

        cutButton.target = self; cutButton.action = #selector(cutPressed)
        cutButton.refusesFirstResponder = true
        for (i, s) in slotButtons.enumerated() {
            let n = i + 1
            s.bodyAction = { [weak self] in self?.executeSlot(n) }
            s.makeMenu = { [weak self] in self?.slotMenu(slot: n) ?? NSMenu() }
            s.willPopUp = { [weak self] menu in self?.activeMenu = menu }
        }
        ftbSplit.bodyAction = { [weak self] in self?.ftbPressed() }
        ftbSplit.makeMenu = { [weak self] in self?.ftbMenu() ?? NSMenu() }
        ftbSplit.willPopUp = { [weak self] menu in self?.activeMenu = menu }
        durationControl.target = self; durationControl.action = #selector(durationChanged)
        durationControl.translatesAutoresizingMaskIntoConstraints = false
        durationControl.segmentDistribution = .fillProportionally
        durationControl.refusesFirstResponder = true
        durationControl.setAccessibilityLabel(L("transition.durationLabel"))
        durationControl.cell?.setAccessibilityLabel(L("transition.durationLabel"))
        durationControl.setToolTip(L("transition.duration.customTip"), forSegment: Self.customSegment)
        tbarSlotButton.target = self; tbarSlotButton.action = #selector(tbarSlotPressed)
        tbarSlotButton.alignment = .left
        tbarSlotButton.lineBreakMode = .byTruncatingTail
        tbarSlotButton.refusesFirstResponder = true
        for (i, b) in overlayButtons.enumerated() {
            b.tag = i + 1
            b.target = self
            b.action = #selector(overlayPressed(_:))
            b.refusesFirstResponder = true
            b.menu = OverlaySettingsMenu.make(channel: i + 1, target: self, action: #selector(overlaySettingsPressed(_:)))
        }
        // 两档控件：次要控件 small 20 pt、配 small 字号 11 pt
        let smallFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        for c in [durationControl, tbarSlotButton] + overlayButtons as [NSControl] {
            c.controlSize = .small
            c.font = smallFont
        }
        tbar.onProgress = { [weak self] p in self?.send?(.tbar(progress: p)) }
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let overlayRow = NSStackView(views: overlayButtons)
        self.overlayRow = overlayRow
        overlayRow.orientation = .horizontal
        overlayRow.spacing = 4
        overlayRow.distribution = .fillEqually
        overlayRow.translatesAutoresizingMaskIntoConstraints = false

        tbarHint.isHidden = true
        tbarHint.lineBreakMode = .byWordWrapping
        tbarHint.maximumNumberOfLines = 2
        tbarHint.cell?.wraps = true
        let stack = NSStackView(views: [cutButton] + slotButtons + [ftbSplit, overlayHeader, overlayRow, tbarHeader, tbarSlotButton, durationControl, tbar, tbarHint, spacer, clock])
        self.stack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 4                                       // 组内
        stack.setCustomSpacing(8, after: slotButtons[3])        // 组间：Cut + 转场 1–4 | FTB | Overlay | T-bar | 时钟
        stack.setCustomSpacing(8, after: ftbSplit)
        stack.setCustomSpacing(2, after: overlayHeader)         // 组标题到控件
        stack.setCustomSpacing(8, after: overlayRow)
        stack.setCustomSpacing(2, after: tbarHeader)
        stack.setCustomSpacing(4, after: tbarSlotButton)
        stack.setCustomSpacing(4, after: durationControl)
        stack.setCustomSpacing(0, after: tbar)
        stack.setCustomSpacing(0, after: tbarHint)
        stack.setCustomSpacing(8, after: spacer)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // 每一行都和列一样宽（减左右内边距）：可见的左右边一律落在 8 和列宽 − 8
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        overlayRow.setHuggingPriority(.defaultHigh, for: .vertical)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Theme.transitionColumnWidth),
            clock.heightAnchor.constraint(equalToConstant: 56),
        ])
        apply(state: state)
        shownCurrent = nil   // 第一份真快照不算"换了当前槽"
        tierHeights = measureTierHeights()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 快照 → 按钮状态（≤ 60 Hz；字和提示没变就不重设，W5-F：每帧重设标题会让整窗重新布局）。
    func apply(state: MixerState) {
        self.state = state
        frameRate = state.format.frameRate
        let t = state.transition
        for (i, s) in slotButtons.enumerated() {
            let n = i + 1
            let title = i < t.slots.count ? SlotText.buttonTitle(t.slots[i], rate: frameRate) : ""
            if s.bodyButton.title != title { s.bodyButton.title = title }
            let executing = t.isActive && t.currentSlot == n
            Theme.setHighlighted(s.bodyButton, executing)
            s.setMarker(t.currentSlot == n, onHighlightedBody: executing)
        }
        Theme.setHighlighted(ftbButton, state.ftb.on, color: Theme.ftbActive)
        updateDurationControl()
        for (i, b) in overlayButtons.enumerated() {
            Theme.setHighlighted(b, state.overlays[i].on)
        }
        tbar.apply(state: state)
        updateTbarGuard()
        updateTbarSlot()
        refreshTooltips(force: false)
        params.apply(state: state)
    }

    // MARK: 四档（W6-A，规则 9）

    /// 换到这一档（主窗口按排布算好的）：收起 / 放回时钟、"当前槽"和"时长"两行、T-bar 组。
    func setTier(_ newTier: ColumnTier) {
        guard newTier != tier else { return }
        tier = newTier
        applyTierFlags(newTier)
        onTierChange?(newTier)
    }

    /// 这一档摆出来多高（fittingSize 量的）。
    func fittingHeight(of t: ColumnTier) -> CGFloat {
        if tierHeights.isEmpty { tierHeights = measureTierHeights() }
        return tierHeights[t.rawValue]
    }

    /// 按档藏 / 放各行。组间距跟着：最小档没有 T-bar 组，叠加那一行后面不再留组间的 8。
    private func applyTierFlags(_ t: ColumnTier) {
        let clockHidden = t != .full
        if clock.isHidden != clockHidden { clock.isHidden = clockHidden }
        let rowsHidden = t >= .compact
        if tbarSlotButton.isHidden != rowsHidden { tbarSlotButton.isHidden = rowsHidden }
        if durationControl.isHidden != rowsHidden { durationControl.isHidden = rowsHidden }
        let tbarHidden = t == .minimal
        if tbarHeader.isHidden != tbarHidden { tbarHeader.isHidden = tbarHidden }
        if tbar.isHidden != tbarHidden { tbar.isHidden = tbarHidden }
        let hintShown = hintWanted && !tbarHidden
        if tbarHint.isHidden == hintShown { tbarHint.isHidden = !hintShown }
        stack.setCustomSpacing(tbarHidden ? 0 : 8, after: overlayRow)
    }

    /// 四档各摆一次量 fittingSize，再摆回现在这一档（只在初始化和提示出没时量，不在主窗口排布的那一趟里量）。
    private func measureTierHeights() -> [CGFloat] {
        let current = tier
        var out: [CGFloat] = []
        for t in ColumnTier.allCases {
            applyTierFlags(t)
            updateConstraintsForSubtreeIfNeeded()
            out.append(fittingSize.height)
        }
        applyTierFlags(current)
        return out
    }

    // MARK: 转场 1–4

    /// 槽 n 现在的配置（槽号不对为 nil）。
    private func slot(_ n: Int) -> TransitionSlot? {
        TransitionSlot.indexRange.contains(n) && n - 1 < state.transition.slots.count ? state.transition.slots[n - 1] : nil
    }

    /// 当前槽（当前那组）是没选输入的 Stinger 时 T-bar 灰掉、下面写一行（W5-P，112 留下的，用户 2026-10-17 定）：契约不拦 T-bar（提案 029 只拒
    /// autoTransition / useTransitionSlot(start)），推下去等于一次硬切——渲染器推过换底拍的位置（出厂 cutAtTick 0 = 一推动）就整幅画新画面
    /// （CompositorPasses 的 stingerShowsNewUnder；没有 Stinger 画面可叠），推到顶只是对调 PGM / PVW；界面拦。选了输入 / 换了当前槽就恢复。
    /// 转场进行中不动它（进行中的不是这种组）。
    private func updateTbarGuard() {
        let t = state.transition
        let unset = !t.isActive && t.currentGroup.isStingerWithoutInput
        if tbar.isEnabled == unset { tbar.isEnabled = !unset }
        let hint = unset ? (t.currentSlot.map { L("tbar.stingerUnsetHint", $0) } ?? L("tbar.stingerUnsetHintNoSlot")) : ""
        let textChanged = tbarHint.stringValue != hint
        if textChanged { tbarHint.stringValue = hint }
        let wantedChanged = hintWanted != unset
        hintWanted = unset
        let shown = unset && tier != .minimal
        if tbarHint.isHidden == shown { tbarHint.isHidden = !shown }
        // 提示占高度：出没（或出着时换了字）各档的高都变了，重量、让主窗口重排（W6-A）
        if !tierHeights.isEmpty, wantedChanged || (unset && textChanged) {
            tierHeights = measureTierHeights()
            onTierHeightsChange?()
        }
        let tip: String? = unset ? (t.currentSlot.map { L("tbar.stingerUnsetTip", $0) } ?? L("tbar.stingerUnsetTipNoSlot")) : nil
        if tbar.toolTip != tip { tbar.toolTip = tip }
    }

    /// 格子"转场"遇当前那组是没选输入的 Stinger（W5-P）：弹这个槽的输入选择（与点转场列那个槽的主体同一个菜单，选了只改槽、不执行），
    /// 菜单挂在格子的按钮下面；当前那组不对应槽（API 用 setTransition 设的）没有槽可选，状态行说一句。
    func showStingerInputs(slot: Int?, below anchor: NSView) {
        guard let n = slot, self.slot(n) != nil else {
            onNotice?(L("feedback.stingerWithoutInput"))
            return
        }
        let menu = stingerInputMenu(slot: n)
        activeMenu = menu
        ScreenMenu.popUpBelow(menu, anchor)
    }

    /// 点主体 / T-bar 那一行的菜单 / 菜单栏"切换 › 转场 n"：执行转场 n。Stinger 槽没选输入 = 弹出这个槽的输入选择、不执行（X18）。
    func executeSlot(_ n: Int) {
        guard let slot = slot(n) else { return }
        if SlotText.isUnsetStinger(slot) {
            let menu = stingerInputMenu(slot: n)
            activeMenu = menu
            ScreenMenu.popUpBelow(menu, slotButtons[n - 1].bodyButton)
            return
        }
        send?(.useTransitionSlot(slot: n, start: true))
    }

    /// 菜单项改槽的哪一处（发的时候按最新快照里的槽改这一处：菜单开着时别处改了时长 / 参数，不会被菜单建时的旧值盖掉）。
    private enum SlotChange {
        case type(TransitionType)
        case wipe(WipeDirection)
        case stingerInput(Int)
        case duration(seconds: Double)
        case factory
    }

    private struct SlotEdit {
        let slot: Int
        let change: SlotChange
    }

    /// 转场 n 的 ▾ / 右键菜单。
    func slotMenu(slot n: Int) -> NSMenu {
        let menu = NSMenu(title: L("slot.name", n))
        menu.autoenablesItems = false
        guard let slot = slot(n) else { return menu }
        menu.addItem(.sectionHeader(title: L("slot.menu.effect")))
        menu.addItem(editItem(L("slot.menu.cut"), slot: n, change: .type(.cut), on: slot.type == .cut))
        menu.addItem(editItem(L("transition.type.fade"), slot: n, change: .type(.fade), on: slot.type == .fade))
        menu.addItem(editItem(L("transition.type.zoom"), slot: n, change: .type(.zoom), on: slot.type == .zoom))
        for d in TransitionParamsModel.directions {
            menu.addItem(editItem(L("slot.menu.wipe", L("transition.wipe.direction.\(d.rawValue)")), slot: n, change: .wipe(d),
                                  on: slot.type == .wipe && slot.wipe.direction == d))
        }
        let stingerTitle = slot.stinger.input.map { L("slot.menu.stingerInput", SlotText.inputName($0, state: state)) } ?? L("slot.menu.stingerPick")
        let stinger = NSMenuItem(title: stingerTitle, action: nil, keyEquivalent: "")
        stinger.state = slot.type == .stinger ? .on : .off
        let inputs = NSMenu(title: stingerTitle)
        inputs.autoenablesItems = false
        addStingerInputs(to: inputs, slot: n)
        stinger.submenu = inputs
        menu.addItem(stinger)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("slot.menu.duration")))
        addDurationItems(to: menu, ticks: slot.durationTicks, tag: n, preset: #selector(slotDurationPicked(_:)), custom: #selector(slotCustomDurationPicked(_:)))
        menu.addItem(.separator())
        let paramsItem = NSMenuItem(title: L("slot.menu.params"), action: #selector(slotParamsPicked(_:)), keyEquivalent: "")
        paramsItem.target = self
        paramsItem.tag = n
        menu.addItem(paramsItem)
        let use = NSMenuItem(title: L("slot.menu.useForTbar"), action: #selector(useForTbarPicked(_:)), keyEquivalent: "")
        use.target = self
        use.tag = n
        use.state = state.transition.currentSlot == n ? .on : .off
        use.isEnabled = !state.transition.isActive   // 进行中状态机会忽略
        use.toolTip = L("slot.menu.useForTbarTip")
        menu.addItem(use)
        let factory = editItem(L("slot.menu.factory"), slot: n, change: .factory, on: false)
        factory.isEnabled = slot != TransitionSlot.factoryDefaults(for: state.format)[n - 1]
        menu.addItem(factory)
        return menu
    }

    /// X18：Stinger 槽没选输入时点主体弹的菜单（停在输入选择上）：段标题 + 各路输入；选 = 只改这个槽的输入，不执行。
    func stingerInputMenu(slot n: Int) -> NSMenu {
        let menu = NSMenu(title: L("slot.stingerMenu.header", n))
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: L("slot.stingerMenu.header", n)))
        addStingerInputs(to: menu, slot: n)
        return menu
    }

    private func addStingerInputs(to menu: NSMenu, slot n: Int) {
        guard let slot = slot(n) else { return }
        guard !state.inputs.isEmpty else {
            let none = NSMenuItem(title: L("slot.stingerMenu.noInputs"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for input in state.inputs {
            menu.addItem(editItem(L("source.input", input.number, input.name), slot: n, change: .stingerInput(input.number),
                                  on: slot.type == .stinger && slot.stinger.input == input.number))
        }
    }

    private func editItem(_ title: String, slot n: Int, change: SlotChange, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(slotEditPicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = SlotEdit(slot: n, change: change)
        item.state = on ? .on : .off
        return item
    }

    @objc private func slotEditPicked(_ sender: NSMenuItem) {
        guard let edit = sender.representedObject as? SlotEdit else { return }
        applySlotChange(edit.slot, edit.change)
    }

    @objc private func slotDurationPicked(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        applySlotChange(sender.tag, .duration(seconds: seconds))
    }

    @objc private func slotCustomDurationPicked(_ sender: NSMenuItem) {
        let n = sender.tag
        guard let slot = slot(n) else { return }
        promptDuration(title: L("slot.duration.customTitle", n), current: SlotText.seconds(slot.durationTicks, rate: frameRate)) { [weak self] seconds in
            self?.applyCustomSlotDuration(slot: n, seconds: seconds)
        }
    }

    /// 转场 n 的自定义时长（秒）；超出范围不发。
    func applyCustomSlotDuration(slot n: Int, seconds: Double) {
        guard Self.customDurationRange.contains(seconds) else { return }
        applySlotChange(n, .duration(seconds: seconds))
    }

    /// 按最新快照里的槽改一处，变了才发 setTransitionSlot（只改配置、不执行；进行中也收）。
    private func applySlotChange(_ n: Int, _ change: SlotChange) {
        guard let current = slot(n) else { return }
        var config = current
        switch change {
        case .type(let type): config.type = type
        case .wipe(let direction):
            config.type = .wipe
            config.wipe.direction = direction
        case .stingerInput(let input):
            config.type = .stinger
            config.stinger.input = input
        case .duration(let seconds): config.durationTicks = max(1, ticks(forSeconds: seconds))
        case .factory: config = TransitionSlot.factoryDefaults(for: state.format)[n - 1]
        }
        guard config != current else { return }
        send?(.setTransitionSlot(slot: n, config: config))
    }

    @objc private func useForTbarPicked(_ sender: NSMenuItem) {
        guard slot(sender.tag) != nil, !state.transition.isActive else { return }
        send?(.useTransitionSlot(slot: sender.tag, start: false))
    }

    @objc private func slotParamsPicked(_ sender: NSMenuItem) { showSlotParams(slot: sender.tag) }

    /// 参数面板的内容视图（开着时；测试看）。
    var paramsPopoverContentView: NSView? { paramsPopover?.isShown == true ? paramsPopover?.contentViewController?.view : nil }

    /// 转场 n 的参数…：Wipe 方向 / 软边、Stinger 输入 / 换底拍的弹出面板（在这个槽的右边）。
    func showSlotParams(slot n: Int) {
        guard slot(n) != nil else { return }
        closeSlotParams()
        params.slot = n
        params.apply(state: state)
        let popover = NSPopover()
        let host = NSHostingController(rootView: TransitionParamsView(model: params))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        let anchor = slotButtons[n - 1]
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        paramsPopover = popover
    }

    func closeSlotParams() {
        paramsPopover?.close()
        paramsPopover = nil
    }

    // MARK: T-bar 那一行

    /// T-bar 那一行的文字（测试看；末尾带 ▾）。
    var tbarSlotText: String { tbarSlotButton.title }

    private struct CurrentKey: Equatable {
        let slot: Int?
        let group: TransitionSlot
    }

    private func updateTbarSlot() {
        let t = state.transition
        let current = SlotText.current(t, rate: frameRate)
        let title = SlotText.tbarRowTitle(t, rate: frameRate)
        if tbarSlotButton.title != title {
            tbarSlotButton.title = title
            tbarSlotButton.setAccessibilityLabel(L("slot.tbarRowAX", current))
            if isTbarSlotHighlighted { Theme.setTitleColor(tbarSlotButton, .white) }
        }
        let key = CurrentKey(slot: t.currentSlot, group: t.currentGroup)
        if let shown = shownCurrent, shown != key { highlightTbarSlot() }
        shownCurrent = key
    }

    /// 当前槽 / 当前那组被换掉了（执行别的槽、"用于 T-bar"、⌥n、API）：那一行高亮一阵，提醒 T-bar 和回车已经换了转场。
    private func highlightTbarSlot() {
        isTbarSlotHighlighted = true
        Theme.setHighlighted(tbarSlotButton, true)
        highlightTimer?.invalidate()
        let timer = Timer(timeInterval: Self.slotHighlightSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTbarSlotHighlighted = false
                Theme.setHighlighted(self.tbarSlotButton, false)
                self.highlightTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightTimer = timer
    }

    /// T-bar 那一行的菜单：四个槽、当前的打勾；点 = 执行这个槽（之后 T-bar 和回车也用它）；进行中四项灰着（状态机会忽略）。
    func tbarSlotMenu() -> NSMenu {
        let menu = NSMenu(title: L("slot.tbarMenu.header"))
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: L("slot.tbarMenu.header")))
        for (i, slot) in state.transition.slots.enumerated() {
            let item = NSMenuItem(title: SlotText.menuTitle(i + 1, slot, rate: frameRate), action: #selector(tbarSlotPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i + 1
            item.state = state.transition.currentSlot == i + 1 ? .on : .off
            item.isEnabled = !state.transition.isActive
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: L("slot.tbarMenu.hint"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        return menu
    }

    @objc private func tbarSlotPressed() {
        let menu = tbarSlotMenu()
        activeMenu = menu
        ScreenMenu.popUpBelow(menu, tbarSlotButton)
    }

    @objc private func tbarSlotPicked(_ sender: NSMenuItem) {
        guard !state.transition.isActive else { return }
        executeSlot(sender.tag)
    }

    // MARK: 时长（当前槽）

    /// 预设秒数换成拍数（按标称帧率取整：59.94 → 60）。
    func ticks(forSeconds seconds: Double) -> Int {
        Int((seconds * Double(frameRate.nominalFramesPerSecond)).rounded())
    }

    /// 时长分段显示的拍数：当前槽的时长（当前那组不在槽里时 = 当前那组的时长）。
    private var currentDurationTicks: Int {
        state.transition.currentSlot.flatMap { slot($0)?.durationTicks } ?? state.transition.durationTicks
    }

    private var currentSeconds: Double { SlotText.seconds(currentDurationTicks, rate: frameRate) }

    private static func presetIndex(_ seconds: Double) -> Int? { durationPresets.firstIndex { abs($0 - seconds) < 0.01 } }

    /// "0.75"、"1.5"、"2"：最多两位小数、去掉末尾的 0。
    static func secondsText(_ seconds: Double) -> String {
        var text = String(format: "%.2f", (seconds * 100).rounded() / 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 分段与按钮上的写法："0.5s"、"1s"、"0.75s"。
    static func compactSeconds(_ seconds: Double) -> String { secondsText(seconds) + "s" }

    /// 时长分段跟快照：是预设就选那一段、最后一段写"…"（提示"自定义时长…"）；不是预设就选最后一段、写实际值。
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
        applyCurrentDuration(ticks: ticks(forSeconds: Self.durationPresets[i]))
    }

    /// 自定义时长的菜单：时长不是预设时第一项是"✓ 自定义：0.75 秒"，下面"自定义…"打开输入框。
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
        menu.addItem(edit)
        return menu
    }

    @objc private func promptCustomDuration() {
        promptDuration(title: L("transition.duration.customTitle"), current: currentSeconds) { [weak self] seconds in
            self?.applyCustomDuration(seconds: seconds)
        }
    }

    /// 当前槽的自定义时长（秒）；超出范围不发。
    func applyCustomDuration(seconds: Double) {
        guard Self.customDurationRange.contains(seconds) else { return }
        applyCurrentDuration(ticks: max(1, ticks(forSeconds: seconds)))
    }

    /// 改当前槽的时长（setTransitionSlot，进行中也收）；当前那组不在槽里时照旧 setTransition（进行中状态机会拒，不发）。
    private func applyCurrentDuration(ticks: Int) {
        let t = state.transition
        if let n = t.currentSlot, var slot = slot(n) {
            guard slot.durationTicks != ticks else { return }
            slot.durationTicks = ticks
            send?(.setTransitionSlot(slot: n, config: slot))
        } else {
            guard !t.isActive, t.durationTicks != ticks else { return }
            send?(.setTransition(type: t.type, durationTicks: ticks))
        }
    }

    /// 测试入口：选第 i 个时长预设（= 点那一段）。
    func selectDurationPresetForTesting(_ i: Int) {
        durationControl.selectedSegment = i
        durationChanged()
    }

    /// 时长的几项（转场槽 / FTB 的菜单共用）：0.5 / 1 / 2 秒（当前的打勾）、不是预设时"✓ 自定义：0.75 秒"、"自定义…"。
    private func addDurationItems(to menu: NSMenu, ticks: Int, tag: Int, preset: Selector, custom: Selector) {
        let seconds = SlotText.seconds(ticks, rate: frameRate)
        let index = Self.presetIndex(seconds)
        for (i, s) in Self.durationPresets.enumerated() {
            let item = NSMenuItem(title: L("slot.duration.seconds", Self.secondsText(s)), action: preset, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = s
            item.state = index == i ? .on : .off
            menu.addItem(item)
        }
        if index == nil {
            let current = NSMenuItem(title: L("transition.duration.customCurrent", Self.secondsText(seconds)), action: nil, keyEquivalent: "")
            current.state = .on
            current.isEnabled = false
            menu.addItem(current)
        }
        let edit = NSMenuItem(title: L("transition.duration.customEllipsis"), action: custom, keyEquivalent: "")
        edit.target = self
        edit.tag = tag
        menu.addItem(edit)
    }

    /// 输入时长（秒）的对话框（sheet），确定后交给 apply；超出范围由 apply 自己不发。
    private func promptDuration(title: String, current: Double, apply: @escaping @MainActor (Double) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L("transition.duration.customInfo", Self.secondsText(Self.customDurationRange.lowerBound), Self.secondsText(Self.customDurationRange.upperBound))
        let field = NSTextField(string: Self.secondsText(current))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        field.setAccessibilityLabel(title)
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let seconds = Self.parseSeconds(field.stringValue) else { return }
                apply(seconds)
            }
        }
    }

    /// "0.75"、"0,75"、" 1.5 " → 秒。
    static func parseSeconds(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    // MARK: FTB

    @objc private func ftbPressed() { send?(.ftb(on: !state.ftb.on)) }

    /// FTB 的 ▾ / 右键：FTB 自己的时长（setFTBDuration，按节目帧率换拍；不跟随转场时长）。
    func ftbMenu() -> NSMenu {
        let menu = NSMenu(title: L("ftb.menu.header"))
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: L("ftb.menu.header")))
        addDurationItems(to: menu, ticks: state.ftb.durationTicks, tag: 0, preset: #selector(ftbDurationPicked(_:)), custom: #selector(ftbCustomDurationPicked(_:)))
        return menu
    }

    @objc private func ftbDurationPicked(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        setFTBDuration(ticks: ticks(forSeconds: seconds))
    }

    @objc private func ftbCustomDurationPicked(_ sender: NSMenuItem) {
        promptDuration(title: L("ftb.duration.customTitle"), current: SlotText.seconds(state.ftb.durationTicks, rate: frameRate)) { [weak self] seconds in
            self?.applyCustomFTBDuration(seconds: seconds)
        }
    }

    /// FTB 的自定义时长（秒）；超出范围不发。
    func applyCustomFTBDuration(seconds: Double) {
        guard Self.customDurationRange.contains(seconds) else { return }
        setFTBDuration(ticks: max(1, ticks(forSeconds: seconds)))
    }

    private func setFTBDuration(ticks: Int) {
        guard ticks != state.ftb.durationTicks else { return }
        send?(.setFTBDuration(ticks: ticks))
    }

    // MARK: 提示（从快捷键表反查）

    private struct TooltipKey: Equatable {
        let slots: [TransitionSlot]
        let current: Int?
        let group: TransitionSlot
        let ftbTicks: Int
        let overlayInputs: [Int?]
        let inputNames: [String]
        let fps: Int
    }

    /// 提示里用到的东西变了才重写（每帧设 toolTip 也会拖慢整窗，W5-F）。
    private func refreshTooltips(force: Bool) {
        let t = state.transition
        let key = TooltipKey(slots: t.slots, current: t.currentSlot, group: t.currentGroup, ftbTicks: state.ftb.durationTicks,
                             overlayInputs: state.overlays.map(\.input), inputNames: state.inputs.map(\.name), fps: frameRate.nominalFramesPerSecond)
        guard force || key != tooltipKey else { return }
        tooltipKey = key
        cutButton.toolTip = tip(L("transition.tip.cut"), matching: HotkeyMatch.cut)
        for (i, s) in slotButtons.enumerated() {
            let n = i + 1
            guard let slot = slot(n) else { continue }
            let detail = SlotText.detail(slot, rate: frameRate, state: state)
            let text = SlotText.isUnsetStinger(slot) ? L("slot.tip.stingerUnset", n, detail) : L("slot.tip", n, detail)
            s.bodyButton.toolTip = tip(text, matching: HotkeyMatch.slot(n))
            s.bodyButton.setAccessibilityLabel(L("slot.a11y", n, detail))
        }
        let ftbSeconds = Self.secondsText(SlotText.seconds(state.ftb.durationTicks, rate: frameRate))
        ftbButton.toolTip = tip(L("transition.tip.ftbDuration", ftbSeconds), matching: HotkeyMatch.ftb)
        let current = SlotText.current(t, rate: frameRate)
        let base = L("slot.tip.tbarRow", current)
        tbarSlotButton.toolTip = HotkeyText.keys(in: hotkeyTable, matching: HotkeyMatch.auto).map { L("slot.tip.tbarRowKeys", base, $0) } ?? base
        durationControl.toolTip = t.currentSlot.map { L("slot.tip.duration", $0) } ?? L("slot.tip.durationNoSlot")
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

    @objc private func overlaySettingsPressed(_ sender: NSMenuItem) { onOverlaySettings?(sender.tag) }

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
