// 面板与窗口的总管（W3-E）：输入设置窗（每路一个）、输出设置窗、偏好设置、快捷键编辑器、MIDI 映射、多画面窗口、外部显示窗口。
// 换 session 时设置类窗口关掉（模型绑的是旧 session 的状态），多画面 / 外部显示窗口换显示来源；外部显示窗口跟着快照里的
// externalDisplay 输出开关（菜单 / 设置面板加输出 → 开窗口；用户关窗口 → removeOutput）。
import AppKit
import SwitcherContracts
import SwitcherControl
import SwitcherRender

@MainActor
final class PanelCoordinator: NSObject {
    private unowned let controller: AppController
    private(set) var inputSettingsWindows: [Int: InputSettingsWindowController] = [:]
    private(set) var outputSettingsWindow: OutputSettingsWindowController?
    private(set) var preferencesWindow: PreferencesWindowController?
    private(set) var hotkeyWindow: HotkeyEditorWindowController?
    private(set) var midiWindow: MIDIMappingWindowController?
    private(set) var multiviewWindow: MultiviewWindowController?
    private(set) var externalDisplayWindows: [Int: ExternalDisplayWindowController] = [:]
    private var stateToken: ObserverToken?
    private var session: SwitcherSession?
    private var state = MixerState()

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    /// 换 session：关掉设置类窗口，重绑显示窗口，跟新快照。
    func bind(session: SwitcherSession?) {
        stateToken?.invalidate()
        stateToken = nil
        for (_, w) in inputSettingsWindows { w.close() }
        inputSettingsWindows.removeAll()
        outputSettingsWindow?.close()
        outputSettingsWindow = nil
        preferencesWindow?.close()
        preferencesWindow = nil
        hotkeyWindow?.close()
        hotkeyWindow = nil
        midiWindow?.close()
        midiWindow = nil
        for (_, w) in externalDisplayWindows { w.closeFromState() }
        externalDisplayWindows.removeAll()
        self.session = session
        multiviewWindow?.bind(source: session?.displaySource)
        guard let session else { state = MixerState(); return }
        stateToken = session.observeState { [weak self] state in self?.apply(state: state) }
    }

    private func apply(state: MixerState) {
        self.state = state
        for (number, w) in inputSettingsWindows {
            if state.input(number) == nil { w.close(); inputSettingsWindows.removeValue(forKey: number) } else { w.apply(state: state) }
        }
        outputSettingsWindow?.apply(state: state)
        syncExternalDisplays(state: state)
    }

    // MARK: 设置窗

    @discardableResult
    func showInputSettings(input number: Int) -> InputSettingsWindowController? {
        guard let session, let config = state.input(number) ?? session.state.input(number) else { return nil }
        if let w = inputSettingsWindows[number] {
            w.present()
            return w
        }
        let model = InputSettingsModel(config: config)
        model.send = { [weak session] c in session?.send(c) }
        let w = InputSettingsWindowController(model: model)
        w.onClose = { [weak self] in self?.inputSettingsWindows.removeValue(forKey: number) }
        inputSettingsWindows[number] = w
        w.present()
        return w
    }

    @discardableResult
    func showOutputSettings(tab: OutputSettingsModel.Tab = .record) -> OutputSettingsWindowController {
        if let w = outputSettingsWindow {
            w.model.tab = tab
            w.present()
            return w
        }
        let model = OutputSettingsModel(state: session?.state ?? state, tab: tab, defaultRecordDirectory: controller.documents.recordDirectory,
                                        showName: session?.name ?? "", queriesSystemExtensions: !controller.isTestHost)
        model.send = { [weak self] c in self?.session?.send(c) }
        let w = OutputSettingsWindowController(model: model)
        w.onClose = { [weak self] in self?.outputSettingsWindow = nil }
        outputSettingsWindow = w
        w.present()
        return w
    }

    @discardableResult
    func showPreferences() -> PreferencesWindowController {
        if let w = preferencesWindow {
            w.present()
            return w
        }
        let w = PreferencesWindowController(model: PreferencesModel(controller: controller))
        w.onClose = { [weak self] in self?.preferencesWindow = nil }
        preferencesWindow = w
        w.present()
        return w
    }

    @discardableResult
    func showHotkeyEditor() -> HotkeyEditorWindowController {
        if let w = hotkeyWindow {
            w.present()
            return w
        }
        let model = HotkeyEditorModel(table: session?.control.hotkeyTable ?? controller.hotkeyTable, fileURL: controller.hotkeyFileURL)
        model.apply = { [weak self] t in try self?.controller.applyHotkeyTable(t) }
        let w = HotkeyEditorWindowController(model: model)
        w.onClose = { [weak self] in self?.hotkeyWindow = nil }
        hotkeyWindow = w
        w.present()
        return w
    }

    @discardableResult
    func showMIDIMapping() -> MIDIMappingWindowController {
        if let w = midiWindow {
            w.present()
            return w
        }
        let midi = session?.control.midi ?? MIDIController(bus: CommandBus(stateMachine: SwitcherSession.detachedStateMachine()), table: controller.midiTable)
        let model = MIDIMappingModel(table: midi.table, controller: midi, fileURL: controller.midiFileURL)
        model.apply = { [weak self] t in try self?.controller.applyMIDITable(t) }
        let w = MIDIMappingWindowController(model: model)
        w.onClose = { [weak self] in self?.midiWindow = nil }
        midiWindow = w
        w.present()
        return w
    }

    // MARK: 多画面 / 外部显示

    @discardableResult
    func showMultiview() -> MultiviewWindowController {
        let w = multiviewWindow ?? MultiviewWindowController()
        multiviewWindow = w
        w.bind(source: session?.displaySource)
        w.present()
        return w
    }

    /// 窗口菜单里的"外部显示"子菜单：每块屏 × （PGM / PVW / 多画面 / 每路输入）。
    func makeExternalDisplayMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.externalDisplay"))
        for screen in NSScreen.screens {
            guard let number = screen.displayNumber else { continue }
            let sub = NSMenu(title: screen.displayTitle)
            let sources: [OutputSource] = [.program, .preview, .multiview] + state.inputs.map { .input(number: $0.number) }
            for source in sources {
                let item = NSMenuItem(title: source.title(in: state), action: #selector(externalMenuItemPressed(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ExternalMenuChoice(screenNumber: number, source: source)
                if state.outputs.contains(where: { $0.kind == .externalDisplay && $0.settings.source == source && OutputExtras.displayNumber(of: $0) == number }) {
                    item.state = .on
                }
                sub.addItem(item)
            }
            let screenItem = NSMenuItem(title: screen.displayTitle, action: nil, keyEquivalent: "")
            screenItem.submenu = sub
            menu.addItem(screenItem)
        }
        if !externalDisplayWindows.isEmpty {
            menu.addItem(.separator())
            let close = NSMenuItem(title: L("menu.externalDisplay.closeAll"), action: #selector(closeAllExternalDisplays), keyEquivalent: "")
            close.target = self
            menu.addItem(close)
        }
        return menu
    }

    final class ExternalMenuChoice: NSObject {
        let screenNumber: UInt32
        let source: OutputSource
        init(screenNumber: UInt32, source: OutputSource) {
            self.screenNumber = screenNumber
            self.source = source
        }
    }

    @objc private func externalMenuItemPressed(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ExternalMenuChoice else { return }
        if let existing = state.outputs.first(where: { $0.kind == .externalDisplay && $0.settings.source == choice.source && OutputExtras.displayNumber(of: $0) == choice.screenNumber }) {
            session?.send(.removeOutput(output: existing.number))
        } else {
            openExternalDisplay(screenNumber: choice.screenNumber, source: choice.source)
        }
    }

    @objc private func closeAllExternalDisplays() {
        for o in state.outputs where o.kind == .externalDisplay { session?.send(.removeOutput(output: o.number)) }
    }

    /// 加一路外部显示输出（窗口跟着快照开）。
    func openExternalDisplay(screenNumber: UInt32, source: OutputSource) {
        guard let session else { return }
        let number = (state.outputs.map(\.number).max() ?? 0) + 1
        let screenName = NSScreen.screen(number: screenNumber)?.localizedName ?? "\(screenNumber)"
        session.send(.addOutput(config: OutputState(number: number, kind: .externalDisplay, name: L("outputSettings.external.name", screenName), enabled: true,
                                                     settings: OutputSettings(source: source, extra: [OutputExtras.displayNumber: .number(Double(screenNumber))]))))
    }

    private func syncExternalDisplays(state: MixerState) {
        let wanted = state.outputs.filter { $0.kind == .externalDisplay && $0.enabled }
        for (number, w) in externalDisplayWindows where !wanted.contains(where: { $0.number == number }) {
            w.closeFromState()
            externalDisplayWindows.removeValue(forKey: number)
        }
        guard let session else { return }
        for output in wanted {
            let w: ExternalDisplayWindowController
            if let existing = externalDisplayWindows[output.number] {
                w = existing
            } else {
                w = ExternalDisplayWindowController(outputNumber: output.number, fullScreen: !controller.isTestHost)
                w.onUserClose = { [weak self, number = output.number] in
                    self?.externalDisplayWindows.removeValue(forKey: number)
                    self?.session?.send(.removeOutput(output: number))
                }
                w.bind(source: session.displaySource)
                externalDisplayWindows[output.number] = w
                w.present()
            }
            w.apply(output: output, state: state, textureWidth: session.format.width, textureHeight: session.format.height)
        }
    }

    /// 关掉所有面板窗口（退出 / 测试收尾）。外部显示输出留在快照里，窗口跟着快照会再开。
    func closeAll() {
        for (_, w) in inputSettingsWindows { w.close() }
        inputSettingsWindows.removeAll()
        outputSettingsWindow?.close()
        outputSettingsWindow = nil
        preferencesWindow?.close()
        preferencesWindow = nil
        hotkeyWindow?.close()
        hotkeyWindow = nil
        midiWindow?.close()
        midiWindow = nil
        multiviewWindow?.close()
        for (_, w) in externalDisplayWindows { w.closeFromState() }
        externalDisplayWindows.removeAll()
    }

    /// 布局键（多画面窗口位置）进 Show.layout。
    func layoutValues() -> [String: JSONValue] {
        var v: [String: JSONValue] = [:]
        if let w = multiviewWindow?.window, w.isVisible { v["multiviewWindowFrame"] = .string(NSStringFromRect(w.frame)) }
        return v
    }
}
