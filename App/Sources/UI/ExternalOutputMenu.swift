// 外部输出菜单（底栏"外部输出"按钮 / 菜单栏"输出 → 外部输出"，W3-C 交付 1）：每块显示器一个子菜单，里面是源（PGM / PVW / 多画面 / 各输入）；
// 选中 = 节目里加一个 kind = .externalDisplay 的输出（addOutput，enabled）；已有的打勾，再选一次 = 删（removeOutput）。
// 全部走命令：外部窗口跟着快照开关（AuxOutputRuntime），节目文件里也就带着它们。
// 文案走 L10n（W3-E2）；源的名字用 App 的 OutputSource.title（包里的 ExternalDisplaySpec.describe 是中文）；
// "关闭 n …（状态）"里的状态与帧数只读 Stats.display[]（提案 013）。输入那一组（Aux）前面一行说明"Aux = 原始画面（抠像 / 裁切 / 变换不生效）"，
// 每个输入项的提示也是这句（W3-E3；G4 裁定 Aux 画该路原始帧）。
import AppKit
import SwitcherContracts
import SwitcherExternal

@MainActor
final class ExternalOutputMenuBuilder: NSObject {
    var send: ((Command) -> Void)?
    private var state: MixerState
    private let displays: [DisplayInfo]
    /// 最近一行 Stats 的 display[]（没有 Stats 时空）。
    private let displayStats: [Stats.DisplayEntry]

    init(state: MixerState, displays: [DisplayInfo] = ExternalDisplays.all(), displayStats: [Stats.DisplayEntry] = []) {
        self.state = state
        self.displays = displays
        self.displayStats = displayStats
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
        return OutputState(number: number, kind: .externalDisplay, name: L("externalMenu.outputName", displayName, source.title(in: state)),
                           enabled: true, settings: spec.outputSettings)
    }

    /// 可选的源：PGM / PVW / 多画面 / 各输入。
    static func sources(in state: MixerState) -> [OutputSource] {
        [.program, .preview, .multiview] + state.inputs.map { .input(number: $0.number) }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: L("bottom.external"))
        if displays.isEmpty {
            menu.addItem(withTitle: L("externalMenu.noDisplays"), action: nil, keyEquivalent: "").isEnabled = false
        }
        for display in displays {
            let sub = NSMenu(title: display.name)
            var auxNoted = false
            for source in Self.sources(in: state) {
                // 输入那一组（Aux）前面一行说明：外部显示的"输入 n"画的是该路原始画面，抠像 / 裁切 / 变换不生效（G4 裁定、W3-C2 本包自己画输入帧）
                if source.inputNumber != nil, !auxNoted {
                    sub.addItem(.separator())
                    sub.addItem(.sectionHeader(title: L("aux.rawPictureNote")))
                    auxNoted = true
                }
                let item = NSMenuItem(title: source.title(in: state), action: #selector(sourcePicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Pick(displayID: display.id, displayName: display.name, source: source)
                item.state = Self.existingOutput(in: state, displayID: display.id, source: source) == nil ? .off : .on
                if source.inputNumber != nil { item.toolTip = L("aux.rawPictureNote") }
                sub.addItem(item)
            }
            let size = (Int(display.frame.width), Int(display.frame.height), display.maximumFramesPerSecond)
            let head = NSMenuItem(title: display.isMain ? L("externalMenu.displayMain", display.name, size.0, size.1, size.2)
                                                        : L("externalMenu.display", display.name, size.0, size.1, size.2), action: nil, keyEquivalent: "")
            head.submenu = sub
            menu.addItem(head)
        }
        let existing = state.outputs.filter { $0.kind == .externalDisplay }
        if !existing.isEmpty {
            menu.addItem(.separator())
            for o in existing {
                let status = displayStats.first { $0.kind == "externalDisplay" && $0.output == o.number }.map(OutputStatusText.display)
                let title = status.map { L("externalMenu.closeWithStatus", o.number, o.name, $0) } ?? L("externalMenu.close", o.number, o.name)
                let item = NSMenuItem(title: title, action: #selector(closeOutput(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = o.number as NSNumber
                menu.addItem(item)
            }
            let all = NSMenuItem(title: L("externalMenu.closeAll"), action: #selector(closeAll), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
        return menu
    }

    final class Pick: NSObject {
        let displayID: UInt32
        let displayName: String
        let source: OutputSource
        init(displayID: UInt32, displayName: String, source: OutputSource) {
            self.displayID = displayID
            self.displayName = displayName
            self.source = source
        }
    }

    @objc private func sourcePicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        if let existing = Self.existingOutput(in: state, displayID: pick.displayID, source: pick.source) {
            send?(.removeOutput(output: existing.number))
        } else {
            send?(.addOutput(config: Self.makeOutput(in: state, displayID: pick.displayID, displayName: pick.displayName, source: pick.source)))
        }
    }

    @objc private func closeOutput(_ sender: NSMenuItem) {
        guard let n = (sender.representedObject as? NSNumber)?.intValue else { return }
        send?(.removeOutput(output: n))
    }

    @objc private func closeAll() {
        for o in state.outputs where o.kind == .externalDisplay { send?(.removeOutput(output: o.number)) }
    }
}
