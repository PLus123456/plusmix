// 外部显示路由菜单（底栏"⚙ 外部显示"、菜单栏"输出 › 外部显示 ▸"；W3-C 交付 1 起，W5-A 拍平，W5-F 改单选，01a M1–M4）：
// 每块显示器一段（段标题 = 显示器），段里单选——最上"关闭"（这块屏不出画面、配置留着；这块屏有配置时才列，见下），下面是源（PGM / PVW / 多画面 / 各输入）；
// 勾 = 这块屏正在输出的源（enabled），关着的那一路在它的源后面标"（已关）"。点源：这块屏已有输出 = 换源（setOutputSettings，窗不重开）并打开；没有 = addOutput；
// 同一块屏不再叠出第二路（老节目里同屏的别的路一并关掉，配置留着）。不用子菜单（底栏菜单朝上开，子菜单的方向由系统定、会往下伸，03 §2.2）。
// 已有的外部显示输出在倒数第二段：逐路"删除 n …（状态）"（removeOutput）与"关闭全部外部显示"（只关不删）；最后一段"外部显示设置… / NDI® 发送设置…"（M3）。
// "关闭"只在这块屏有配置时列：两块屏 × 6 路输入时菜单已经 549 pt 高（W5-A 实测），每段再加一行、末尾再加一段，最小窗口（1100×700）里就放不下了
// （E1：整块在窗口里），而没有配置的屏本来就没东西可关（报告 §3）。
// 主体（M1，04 Q03 第 3 条）= toggleAll：有开着的 → 全部关（配置留着）；都关着 → 全部按原配置开（每块屏一路）；一路都没配 → 在第一块非主屏上开 PGM；
// 没有第二块屏 → 底栏弹这个菜单。全部走命令：外部窗口跟着快照开关（ExternalDisplayManager 只给 enabled 的输出开窗口），节目文件里也就带着它们。
// 源的名字用 App 的 OutputSource.title；"删除 n …（状态）"里的状态与帧数只读 Stats.display[]（提案 013）。输入那一组（Aux）前面一行说明
// "Aux = 原始画面（抠像 / 裁切 / 变换不生效）"，每个输入项的提示也是这句（W3-E3；G4 裁定 Aux 画该路原始帧）。
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

    /// 某块屏上的外部显示输出（按编号）。displayID 为 nil 的老输出算在主屏上。
    static func outputs(on display: DisplayInfo, in state: MixerState) -> [OutputState] {
        state.outputs.filter { o in
            guard o.kind == .externalDisplay else { return false }
            let id = ExternalDisplaySpec(settings: o.settings).displayID
            return id == display.id || (id == nil && display.isMain)
        }
    }

    /// 这块屏的"那一路"：开着的优先，否则编号最小的（老节目里同屏可能有好几路，W5-F 起不再叠）。
    static func primaryOutput(on display: DisplayInfo, in state: MixerState) -> OutputState? {
        let list = outputs(on: display, in: state)
        return list.first(where: \.enabled) ?? list.first
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
        return OutputState(number: number, kind: .externalDisplay, name: autoName(displayName: displayName, source: source, in: state),
                           enabled: true, settings: spec.outputSettings)
    }

    /// 菜单起的名字："显示器 · 源"。
    static func autoName(displayName: String, source: OutputSource, in state: MixerState) -> String {
        L("externalMenu.outputName", displayName, source.title(in: state))
    }

    /// 可选的源：PGM / PVW / 多画面 / 各输入。
    static func sources(in state: MixerState) -> [OutputSource] {
        [.program, .preview, .multiview] + state.inputs.map { .input(number: $0.number) }
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
            let size = (Int(display.frame.width), Int(display.frame.height), display.maximumFramesPerSecond)
            menu.addItem(.sectionHeader(title: display.isMain ? L("externalMenu.displayMain", display.name, size.0, size.1, size.2)
                                                              : L("externalMenu.display", display.name, size.0, size.1, size.2)))
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
            for source in Self.sources(in: state) {
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
        guard let primary = Self.primaryOutput(on: display, in: state) else {
            send?(.addOutput(config: Self.makeOutput(in: state, displayID: pick.displayID, displayName: pick.displayName, source: source)))
            return
        }
        if primary.settings.source != source {
            var settings = primary.settings
            settings.source = source
            send?(.setOutputSettings(output: primary.number, settings: settings))
            // 名字还是菜单起的"显示器 · 旧源"就跟着换（用户改过的名字不动）
            if primary.name == Self.autoName(displayName: pick.displayName, source: primary.settings.source, in: state) {
                send?(.renameOutput(output: primary.number, name: Self.autoName(displayName: pick.displayName, source: source, in: state)))
            }
        }
        if !primary.enabled { send?(.setOutputEnabled(output: primary.number, on: true)) }
        for o in Self.outputs(on: display, in: state) where o.number != primary.number && o.enabled {
            send?(.setOutputEnabled(output: o.number, on: false))
        }
    }

    /// 关闭：这块屏不出画面，配置留着。
    @objc private func offPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let display = display(for: pick) else { return }
        for o in Self.outputs(on: display, in: state) where o.enabled { send?(.setOutputEnabled(output: o.number, on: false)) }
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
