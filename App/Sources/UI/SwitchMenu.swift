// 菜单栏"切换"（W5-G，01a O1，docs/ui-study/01-菜单逻辑.md §5）：只放现场操作——
//   Cut ／ 执行当前转场（类型 · 时长）／ ─ ／ 五种类型 ／ ─ ／ FTB（✓ = 开着）／ Overlay ▸ 1–4（✓ = 开着，标题带输入名）。
// 五种类型是"T-bar 和回车用哪种"（与转场列 T-bar 上方那行的菜单同一口径：选 = 只发 setTransition、不执行，当前的打勾，转场进行中灰着；
// 契约的五种都列、含 Cut，用户 2026-10-03 定）；"执行当前转场"按它和当前时长做。槽落地之后（100）这一段换成"转场 1–4"。
// 右列的键从当前快捷键表反查（MenuKeyColumn：只显示、不设 keyEquivalent，HotkeyDispatcher 是唯一的触发口）；
// 快捷键… / MIDI 映射… 挪到 App 菜单"设置…"下（F3）。
// 项在菜单建的时候建好、打开时（menuNeedsUpdate）就地改标题 / 勾 / 右列；动作是 nil target 的 AppDelegate 方法（validateMenuItem 管灰不灰）。
// 这个菜单不认任何键（menuHasKeyEquivalent 一律 false）：菜单栏在主窗口 keyDown 之前先截键，不能让它抢走快捷键表里的键。
import AppKit
import SwitcherContracts
import SwitcherControl

@MainActor
final class SwitchMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: L("menu.transition"))
    let overlayMenu = NSMenu(title: "Overlay")
    let cutItem = NSMenuItem(title: "Cut", action: #selector(AppDelegate.transitionCut(_:)), keyEquivalent: "")
    let autoItem = NSMenuItem(title: "", action: #selector(AppDelegate.transitionAuto(_:)), keyEquivalent: "")
    let typeItems: [NSMenuItem]
    let ftbItem = NSMenuItem(title: "FTB", action: #selector(AppDelegate.transitionFTB(_:)), keyEquivalent: "")
    let overlayItems: [NSMenuItem]
    /// 当前快照（没有 session 为 nil）与快捷键表：AppController 给。
    var state: () -> MixerState? = { nil }
    var hotkeyTable: () -> HotkeyTable = { .default }

    override init() {
        typeItems = TransitionPanelView.tbarTypes.map { type in
            let item = NSMenuItem(title: L("transition.type.\(type.rawValue)"), action: #selector(AppDelegate.pickTransitionType(_:)), keyEquivalent: "")
            item.representedObject = type.rawValue
            return item
        }
        overlayItems = (1...MixerState.overlayCount).map { channel in
            let item = NSMenuItem(title: "Overlay \(channel)", action: #selector(AppDelegate.transitionOverlay(_:)), keyEquivalent: "")
            item.tag = channel
            return item
        }
        super.init()
        menu.delegate = self
        overlayMenu.delegate = self
        menu.addItem(cutItem)
        menu.addItem(autoItem)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("transition.tbarTypeMenu.header")))
        for item in typeItems { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(ftbItem)
        let overlay = NSMenuItem(title: "Overlay", action: nil, keyEquivalent: "")
        overlay.submenu = overlayMenu
        menu.addItem(overlay)
        for item in overlayItems { overlayMenu.addItem(item) }
        overlayMenu.addItem(.separator())
        overlayMenu.addItem(NSMenuItem(title: L("overlay.settingsMenuItem"), action: #selector(AppDelegate.showOverlaySettings(_:)), keyEquivalent: ""))   // W5-K：叠加设置窗
        refresh()
    }

    /// 按当前快照与快捷键表改标题、勾、右列。
    func refresh() {
        let state = state()
        let table = hotkeyTable()
        func keys(_ match: (ControlAction) -> Bool) -> String? { HotkeyText.keys(in: table, matching: match) }
        let current = state?.transition
        let autoTitle: String
        if let current, current.type != .cut {
            let fps = Double(state?.format.frameRate.nominalFramesPerSecond ?? 60)
            autoTitle = L("menu.switch.auto", L("transition.type.\(current.type.rawValue)"),
                          TransitionPanelView.secondsText(Double(current.durationTicks) / max(fps, 1)))
        } else {
            autoTitle = current == nil ? L("menu.switch.autoNoShow") : L("menu.switch.autoCut")
        }
        for (item, type) in zip(typeItems, TransitionPanelView.tbarTypes) {
            item.state = current?.type == type ? .on : .off
        }
        ftbItem.state = state?.ftb.on == true ? .on : .off
        var rows: [MenuKeyColumn.Row] = [
            .init(item: cutItem, title: "Cut", keys: keys(HotkeyMatch.cut)),
            .init(item: autoItem, title: autoTitle, keys: keys(HotkeyMatch.auto)),
            .init(item: ftbItem, title: "FTB", keys: keys(HotkeyMatch.ftb)),
        ]
        rows += zip(typeItems, TransitionPanelView.tbarTypes).map { item, type in
            .init(item: item, title: L("transition.type.\(type.rawValue)"), keys: keys(HotkeyMatch.selectType(type)))
        }
        MenuKeyColumn.apply(rows)
        var overlayRows: [MenuKeyColumn.Row] = []
        for (index, item) in overlayItems.enumerated() {
            let channel = index + 1
            let overlay = state?.overlays[index]
            let title: String
            if let input = overlay?.input {
                title = L("menu.switch.overlayInput", channel, state?.input(input)?.name ?? L("monitor.missingInput", input))
            } else {
                title = L("menu.switch.overlayEmpty", channel)
            }
            item.state = overlay?.on == true ? .on : .off
            overlayRows.append(.init(item: item, title: title, keys: keys(HotkeyMatch.overlay(channel))))
        }
        MenuKeyColumn.apply(overlayRows)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    /// 不认任何键：右列只是显示（菜单栏先于主窗口 keyDown 截键，认了就和 HotkeyDispatcher 抢）。
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool { false }
}
