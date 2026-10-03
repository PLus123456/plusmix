// 面板与窗口的总管（W3-E）：输入设置窗（每路一个）、输出设置窗、偏好设置、快捷键编辑器、MIDI 映射。
// 换 session 时设置类窗口关掉（模型绑的是旧 session 的状态）；偏好设置窗例外（W5-B，X04）：它的设置是本机的，节目格式 / 节目音频几项按新 session 重读一遍，
// 换格式之后窗口还在原处，不用再找。多画面窗口 / 外部显示窗口是 W3-C 的（G4 合并时以 W3-C 的运行表为准）：
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
    /// 统计窗（W5-L，底栏"统计"）。
    private(set) var statsWindow: StatsWindowController?
    private var stateToken: ObserverToken?
    private var statsToken: ObserverToken?
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
        statsToken?.invalidate()
        statsToken = nil
        for (_, w) in inputSettingsWindows { w.close() }
        inputSettingsWindows.removeAll()
        outputSettingsWindow?.close()
        outputSettingsWindow = nil
        hotkeyWindow?.close()
        hotkeyWindow = nil
        midiWindow?.close()
        midiWindow = nil
        self.session = session
        guard let session else { state = MixerState(); return }
        preferencesWindow?.model.rebind()
        stateToken = session.observeState { [weak self] state in self?.apply(state: state) }
        // 输出设置页的显示类输出状态读 Stats.display[]（提案 013），1 Hz；统计窗（W5-L）读同一行，换 session 不关、接着读新的
        statsToken = session.observeStats { [weak self] stats in
            guard let self else { return }
            self.outputSettingsWindow?.model.apply(stats: stats)
            self.statsWindow?.model.apply(stats: stats, state: self.state)
        }
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
        // 这一路没存过位置（居中摆的）、又已经开着别的输入设置窗：错开放在最近那个的右下，不叠在一起（X44）
        if !w.restoredSavedFrame, let last = inputSettingsWindows.values.compactMap(\.window).filter(\.isVisible).max(by: { $0.orderedIndex > $1.orderedIndex }) {
            w.window?.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
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
                                        reserveBytes: session?.outputs.minimumFreeBytes ?? 0, aux: session?.aux)
        if let stats = session?.stats { model.apply(stats: stats) }
        model.send = { [weak self] c in self?.session?.send(c) }
        // 起不来的原因 / 推流正在第几次连接 / 重试（W5-B：推流页那一段写明原因，起不来的路不锁、可以重试或停用）
        model.routeDetail = { [weak self] n in (self?.session?.outputs.failureReason(output: n), self?.session?.outputs.streamConnectAttempt(output: n)) }
        model.onRetry = { [weak self] numbers in self?.session?.retryFailedOutputs(numbers) }
        model.refreshRouteDetails()
        let w = OutputSettingsWindowController(model: model)
        w.onClose = { [weak self] in self?.outputSettingsWindow = nil }
        outputSettingsWindow = w
        w.present()
        return w
    }

    /// 推流页并把焦点放在"添加目的地"（W5-F，L1：没有目的地时点底栏推流主体）。
    @discardableResult
    func showStreamAddDestination() -> OutputSettingsWindowController {
        let w = showOutputSettings(tab: .stream)
        w.model.requestAddDestinationFocus()
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

    /// 统计窗（只读；已开就置前）。
    @discardableResult
    func showStats() -> StatsWindowController {
        if let w = statsWindow {
            w.present()
            return w
        }
        let model = StatsWindowModel()
        if let stats = session?.stats { model.apply(stats: stats, state: state) }
        let w = StatsWindowController(model: model)
        w.onClose = { [weak self] in self?.statsWindow = nil }
        statsWindow = w
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
        statsWindow?.close()
        statsWindow = nil
        if controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
    }
}
