// 面板与窗口的总管（W3-E）：输入设置窗（每路一个）、输出设置窗、偏好设置、快捷键编辑器、MIDI 映射。
// 换 session 时设置类窗口关掉（模型绑的是旧 session 的状态）。多画面窗口 / 外部显示窗口是 W3-C 的（G4 合并时以 W3-C 的运行表为准）：
// 多画面 = MainWindowController.multiviewWindow，外部显示窗口 = AuxOutputRuntime.external 跟着快照里的 externalDisplay 输出开关
// （设置面板 / 菜单加输出 → 开窗口；用户关窗口 → removeOutput）；这里只留 showMultiview 转调。
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
        self.session = session
        guard let session else { state = MixerState(); return }
        stateToken = session.observeState { [weak self] state in self?.apply(state: state) }
    }

    private func apply(state: MixerState) {
        self.state = state
        for (number, w) in inputSettingsWindows {
            if state.input(number) == nil { w.close(); inputSettingsWindows.removeValue(forKey: number) } else { w.apply(state: state) }
        }
        outputSettingsWindow?.apply(state: state)
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
                                        showName: session?.name ?? "", queriesSystemExtensions: !controller.isTestHost,
                                        reserveBytes: session?.outputs.minimumFreeBytes ?? 0)
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

    // MARK: 多画面（W3-C 的窗口；窗口菜单 / 底栏走 MainWindowController.toggleMultiviewWindow）

    /// 显示多画面窗口（已显示就不动）。
    func showMultiview() {
        if !controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
    }

    /// 关掉所有面板窗口（退出 / 测试收尾）。外部显示输出留在快照里，窗口（W3-C）跟着快照会再开。
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
        if controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
    }
}
