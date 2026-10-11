// 外部显示路由菜单（底栏"⚙ 外部显示"、菜单栏"输出 › 外部显示 ▸"；W3-C 交付 1 起，W5-A 拍平，W5-F 改单选，01a M1–M4）：
// 每块显示器一段（段标题 = 显示器），段里单选——最上"关闭"（这块屏不出画面、配置留着；这块屏有配置时才列，见下），下面是源（PGM / PVW / 多画面 / 各输入）；
// 勾 = 这块屏正在输出的源（enabled），关着的那一路在它的源后面标"（已关）"。点源：这块屏已有输出 = 换源（setOutputSettings，窗不重开）并打开；没有 = addOutput；
// 同一块屏不再叠出第二路（老节目里同屏的别的路一并关掉，配置留着）。不用子菜单（底栏菜单朝上开，子菜单的方向由系统定、会往下伸，03 §2.2）。
// 已有的外部显示输出在倒数第二段：逐路"删除 n …（状态）"（removeOutput）与"关闭全部外部显示"（只关不删）；最后一段"外部显示设置… / NDI® 发送设置…"（M3）。
// W5-G：工具条正中"外部显示▾"弹的就是这个菜单（向下开）；监视器右键"全屏输出到 ▸"用 fullscreenMenu(source:)——每块屏一项，点 = 这块屏改出这个监视器的画面
// （同"点源"），已经在出它的那块再点 = 关（同"关闭"，配置留着）。
// "关闭"只在这块屏有配置时列：两块屏 × 6 路输入时菜单已经 549 pt 高（W5-A 实测），每段再加一行、末尾再加一段，最小窗口（1100×700）里就放不下了
// （E1：整块在窗口里），而没有配置的屏本来就没东西可关（报告 §3）。
// 主体（M1，04 Q03 第 3 条）= toggleAll：有开着的 → 全部关（配置留着）；都关着 → 全部按原配置开（每块屏一路）；一路都没配 → 在第一块非主屏上开 PGM；
// 没有第二块屏 → 底栏弹这个菜单。全部走命令：外部窗口跟着快照开关（ExternalDisplayManager 只给 enabled 的输出开窗口），节目文件里也就带着它们。
// 源的名字用 App 的 OutputSource.title；"删除 n …（状态）"里的状态与帧数只读 Stats.display[]（提案 013）。输入那一组（Aux）前面一行说明
// "Aux = 原始画面（抠像 / 裁切 / 变换不生效）"，每个输入项的提示也是这句（W3-E3；G4 裁定 Aux 画该路原始帧）。
// "每块屏一路"的规则（哪一路算这块屏的、选源 / 关闭发什么命令）只有一份，在 ExternalDisplayRouting（W5-I 的设置页也用它）；
// 这里只拼菜单（W5-N 顺带，问题单 G7-w5-app-external-routing-two-implementations）。
import AppKit
import SwitcherContracts
import SwitcherExternal

@MainActor
final class ExternalOutputMenuBuilder: NSObject {
    var send: ((Command) -> Void)?
    /// 菜单末尾的"外部显示设置… / NDI® 发送设置…"：打开输出设置的那一页。
    var onOutputSettings: ((OutputSettingsModel.Tab) -> Void)?
    private var state: MixerState
    private let displays: [DisplayInfo]
    /// 最近一行 Stats 的 display[]（没有 Stats 时空）。
    private let displayStats: [Stats.DisplayEntry]

    init(state: MixerState, displays: [DisplayInfo] = ExternalDisplays.all(), displayStats: [Stats.DisplayEntry] = []) {
        self.state = state
        self.displays = displays
        self.displayStats = displayStats
    }

    /// 这块屏的"那一路"：开着的优先，否则编号最小的（老节目里同屏可能有好几路，W5-F 起不再叠）。规则在 ExternalDisplayRouting。
    static func primaryOutput(on display: DisplayInfo, in state: MixerState) -> OutputState? {
        ExternalDisplayRouting.primaryOutput(on: display, in: state)
    }

    /// 现有的外部显示输出里，显示器 + 源都匹配的那个。
    static func existingOutput(in state: MixerState, displayID: UInt32?, source: OutputSource) -> OutputState? {
        state.outputs.first { o in
            guard o.kind == .externalDisplay else { return false }
            let spec = ExternalDisplaySpec(settings: o.settings)
            return spec.displayID == displayID && spec.source == source
        }
    }

    /// 新的外部显示输出。
    static func makeOutput(in state: MixerState, displayID: UInt32?, displayName: String, source: OutputSource) -> OutputState {
        let number = (state.outputs.map(\.number).max() ?? 0) + 1
        let spec = ExternalDisplaySpec(displayID: displayID, source: source, fallbackToMain: false)
        return OutputState(number: number, kind: .externalDisplay, name: ExternalDisplayRouting.autoName(displayName: displayName, source: source, in: state),
                           enabled: true, settings: spec.outputSettings)
    }

    /// 主体按下去发生了什么。
    enum ToggleResult: Equatable {
        /// 有开着的：全部关了（配置留着）。
        case turnedOff
        /// 都关着：全部按原配置开了。
        case turnedOn
        /// 一路都没配：在第一块非主屏上开了一路 PGM。
        case created
        /// 一路都没配、也没有第二块屏：该弹路由菜单。
        case needsMenu
    }

    /// 外部显示主体（M1）：全部外部显示一起开 / 关、配置保留。开的时候每块屏只开一路（同一块屏不叠）。
    static func toggleAll(state: MixerState, displays: [DisplayInfo], send: (Command) -> Void) -> ToggleResult {
        let all = state.outputs.filter { $0.kind == .externalDisplay }
        if all.contains(where: \.enabled) {
            for o in all where o.enabled { send(.setOutputEnabled(output: o.number, on: false)) }
            return .turnedOff
        }
        if !all.isEmpty {
            var screens = Set<UInt32?>()
            for o in all {
                let id = ExternalDisplaySpec(settings: o.settings).displayID ?? displays.first(where: \.isMain)?.id
                guard screens.insert(id).inserted else { continue }
                send(.setOutputEnabled(output: o.number, on: true))
            }
            return .turnedOn
        }
        guard let second = displays.first(where: { !$0.isMain }) else { return .needsMenu }
        send(.addOutput(config: makeOutput(in: state, displayID: second.id, displayName: second.name, source: .program)))
        return .created
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: L("bottom.external"))
        if displays.isEmpty {
            menu.addItem(withTitle: L("externalMenu.noDisplays"), action: nil, keyEquivalent: "").isEnabled = false
        }
        for (index, display) in displays.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: Self.displayTitle(display)))
            let primary = Self.primaryOutput(on: display, in: state)
            if let primary {
                let off = NSMenuItem(title: L("externalMenu.off"), action: #selector(offPicked(_:)), keyEquivalent: "")
                off.target = self
                off.representedObject = Pick(displayID: display.id, displayName: display.name, source: nil)
                off.state = primary.enabled ? .off : .on
                off.toolTip = L("externalMenu.offTip")
                menu.addItem(off)
            }
            var auxNoted = false
            for source in ExternalDisplayRouting.sources(in: state) {
                // 输入那一组（Aux）前面一行说明：外部显示的"输入 n"画的是该路原始画面，抠像 / 裁切 / 变换不生效（G4 裁定、W3-C2 本包自己画输入帧）
                if source.inputNumber != nil, !auxNoted {
                    menu.addItem(.sectionHeader(title: L("aux.rawPictureNote")))
                    auxNoted = true
                }
                let configuredOff = primary.map { !$0.enabled && $0.settings.source == source } ?? false
                let title = configuredOff ? L("externalMenu.offSuffix", source.title(in: state)) : source.title(in: state)
                let item = NSMenuItem(title: title, action: #selector(sourcePicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Pick(displayID: display.id, displayName: display.name, source: source)
                item.state = primary.map { $0.enabled && $0.settings.source == source } == true ? .on : .off
                if source.inputNumber != nil { item.toolTip = L("aux.rawPictureNote") }
                menu.addItem(item)
            }
        }
        let existing = state.outputs.filter { $0.kind == .externalDisplay }
        if !existing.isEmpty {
            menu.addItem(.separator())
            for o in existing {
                let status = displayStats.first { $0.kind == "externalDisplay" && $0.output == o.number }.map(OutputStatusText.display)
                let title = status.map { L("externalMenu.removeWithStatus", o.number, o.name, $0) } ?? L("externalMenu.remove", o.number, o.name)
                let item = NSMenuItem(title: title, action: #selector(removeOutput(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = o.number as NSNumber
                menu.addItem(item)
            }
            if existing.contains(where: \.enabled) {
                let all = NSMenuItem(title: L("externalMenu.closeAll"), action: #selector(closeAll), keyEquivalent: "")
                all.target = self
                menu.addItem(all)
            }
        }
        // M3：设置入口放最后
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("menu.output.external"), action: #selector(openExternalSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let ndi = NSMenuItem(title: L("menu.output.ndi"), action: #selector(openNDISettings), keyEquivalent: "")
        ndi.target = self
        menu.addItem(ndi)
        return menu
    }

    /// 一块屏的名字："LG ULTRAGEAR（2560×1440 60 Hz，主屏）"。
    static func displayTitle(_ display: DisplayInfo) -> String {
        let size = (Int(display.frame.width), Int(display.frame.height), display.maximumFramesPerSecond)
        return display.isMain ? L("externalMenu.displayMain", display.name, size.0, size.1, size.2)
                              : L("externalMenu.display", display.name, size.0, size.1, size.2)
    }

    /// 监视器右键"全屏输出到 ▸"（W5-G，01a B3）：每块屏一项，勾 = 这块屏正在出这个来源；点没勾的 = 这块屏改出它（同路由菜单里点源：
    /// 有输出就换源、没有就加一路，同屏别的路关掉），点有勾的 = 关这块屏（同"关闭"，配置留着）。
    func fullscreenMenu(source: OutputSource) -> NSMenu {
        let menu = NSMenu(title: L("monitor.menu.fullscreen"))
        menu.autoenablesItems = false
        if displays.isEmpty {
            menu.addItem(withTitle: L("externalMenu.noDisplays"), action: nil, keyEquivalent: "").isEnabled = false
        }
        for display in displays {
            let showing = Self.primaryOutput(on: display, in: state).map { $0.enabled && $0.settings.source == source } ?? false
            let item = NSMenuItem(title: Self.displayTitle(display), action: #selector(fullscreenPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Pick(displayID: display.id, displayName: display.name, source: showing ? nil : source)
            item.state = showing ? .on : .off
            item.toolTip = showing ? L("monitor.menu.fullscreenOffTip") : L("monitor.menu.fullscreenTip", source.title(in: state))
            menu.addItem(item)
        }
        return menu
    }

    @objc private func fullscreenPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let display = display(for: pick) else { return }
        if let source = pick.source {
            select(source, on: display)
        } else {
            turnOff(display)
        }
    }

    final class Pick: NSObject {
        let displayID: UInt32
        let displayName: String
        /// nil = "关闭"。
        let source: OutputSource?
        init(displayID: UInt32, displayName: String, source: OutputSource?) {
            self.displayID = displayID
            self.displayName = displayName
            self.source = source
        }
    }

    private func display(for pick: Pick) -> DisplayInfo? { displays.first { $0.id == pick.displayID } }

    /// 选源：这块屏已有输出 = 换源（同一个输出，窗不重开）并打开，同屏别的路关掉；没有 = 加一路。
    @objc private func sourcePicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let source = pick.source, let display = display(for: pick) else { return }
        select(source, on: display)
    }

    /// 这块屏改出 source（路由菜单点源、监视器右键"全屏输出到"共用）：有那一路 = 换源并打开、同屏别的路关掉；没有 = 加一路（ExternalDisplayRouting.pick）。
    private func select(_ source: OutputSource, on display: DisplayInfo) {
        for c in ExternalDisplayRouting.pick(display: display, source: source, in: state) { send?(c) }
    }

    /// 关闭：这块屏不出画面，配置留着。
    @objc private func offPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let display = display(for: pick) else { return }
        turnOff(display)
    }

    private func turnOff(_ display: DisplayInfo) {
        for c in ExternalDisplayRouting.pick(display: display, source: nil, in: state) { send?(c) }
    }

    @objc private func removeOutput(_ sender: NSMenuItem) {
        guard let n = (sender.representedObject as? NSNumber)?.intValue else { return }
        send?(.removeOutput(output: n))
    }

    /// 全部关闭：开着的都关掉（setOutputEnabled），配置留着。
    @objc private func closeAll() {
        for o in state.outputs where o.kind == .externalDisplay && o.enabled { send?(.setOutputEnabled(output: o.number, on: false)) }
    }

    @objc private func openExternalSettings() { onOutputSettings?(.external) }
    @objc private func openNDISettings() { onOutputSettings?(.ndi) }
}
