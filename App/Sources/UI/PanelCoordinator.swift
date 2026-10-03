// 面板与窗口的总管（W3-E）：输入设置窗（每路一个）与设置窗（W5-J 合窗：偏好设置、输出设置、快捷键、MIDI 映射合成一个带侧栏的窗，SettingsWindow）。
// ⌘, / 工具条"设置▾" / 各 ⚙ / 菜单里的设置页一律走 showSettings(page:)（SettingsPage）：打开同一个设置窗的对应页，⌘, 回到上次那一页（本机记忆）。
// 换 session 时输入设置窗关掉（模型绑的是旧 session 的那一路）；设置窗不关，只重绑（输出页换成新 session 的模型、格式 / 节目音频重读，W5-B X04 / W5-J F1）。
// 老入口 showPreferences() / showOutputSettings(tab:) / showHotkeyEditor() / showMIDIMapping() 与 xxxWindow 属性照用：返回设置窗里那一页的句柄。
// 多画面窗口 / 外部显示窗口是 W3-C 的（G4 合并时以 W3-C 的运行表为准）：
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
    /// 设置窗（没开为 nil）。
    private(set) var settingsWindow: SettingsWindowController?
    private var stateToken: ObserverToken?
    private var statsToken: ObserverToken?
    private var session: SwitcherSession?
    private var state = MixerState()

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    /// 换 session：关掉输入设置窗，设置窗重绑（不关），跟新快照。
    func bind(session: SwitcherSession?) {
        stateToken?.invalidate()
        stateToken = nil
        statsToken?.invalidate()
        statsToken = nil
        for (_, w) in inputSettingsWindows { w.close() }
        inputSettingsWindows.removeAll()
        self.session = session
        guard let session else { state = MixerState(); return }
        state = session.state
        settingsWindow?.model.rebind()
        stateToken = session.observeState { [weak self] state in self?.apply(state: state) }
        // 输出设置页的显示类输出状态读 Stats.display[]（提案 013），1 Hz
        statsToken = session.observeStats { [weak self] stats in self?.settingsWindow?.model.outputs.apply(stats: stats) }
    }

    private func apply(state: MixerState) {
        self.state = state
        for (number, w) in inputSettingsWindows {
            if state.input(number) == nil { w.close(); inputSettingsWindows.removeValue(forKey: number) } else { w.apply(state: state) }
        }
        settingsWindow?.model.outputs.apply(state: state)
    }

    // MARK: 设置（W5-J）

    /// 上次打开的设置页存在这个键下（本机记忆；⌘, 与工具条"设置"主体回到它）。
    static let lastSettingsPageKey = "SettingsLastPage"

    /// 设置窗现在停在哪一页（没开为 nil）。
    var currentSettingsPage: SettingsPage? { settingsWindow?.model.page }

    /// 上次那一页（没开过为 nil）。
    var lastSettingsPage: SettingsPage? {
        controller.defaults.string(forKey: Self.lastSettingsPageKey).flatMap(SettingsPage.init(id:))
    }

    /// 忘掉上次那一页（测试从"没开过"开始）。
    func forgetLastSettingsPage() {
        controller.defaults.removeObject(forKey: Self.lastSettingsPageKey)
    }

    /// 打开设置窗的某一页；nil = 回到上次那一页（没开过 = 常规）。离开的那页（快捷键 / MIDI）有没存的改动时先问，取消就留在原页。
    /// 返回打开的页（问着的时候是原来那页）。
    @discardableResult
    func showSettings(page: SettingsPage? = nil) -> SettingsPage {
        let target = page ?? lastSettingsPage ?? .general
        let window = settingsWindow ?? makeSettingsWindow(page: target)
        window.model.select(target) { [weak self] ok in
            if ok { self?.controller.defaults.set(target.id, forKey: Self.lastSettingsPageKey) }
        }
        window.present()
        return window.model.page
    }

    /// 某一页所在的窗：设置窗停在这一页时就是它。
    func settingsWindow(showing page: SettingsPage) -> NSWindow? {
        settingsWindow?.model.page == page ? settingsWindow?.window : nil
    }

    private func makeSettingsWindow(page: SettingsPage) -> SettingsWindowController {
        let prefs = PreferencesModel(controller: controller)
        let hotkeys = HotkeyEditorModel(table: controller.hotkeyTable, fileURL: controller.hotkeyFileURL)
        hotkeys.apply = { [weak self] t in try self?.controller.applyHotkeyTable(t) }
        hotkeys.state = { [weak self] in self?.session?.state }
        hotkeys.defaults = controller.defaults
        let midi = MIDIMappingModel(table: controller.midiTable, controller: currentMIDIController(), fileURL: controller.midiFileURL)
        midi.apply = { [weak self] t in try self?.controller.applyMIDITable(t) }
        midi.state = { [weak self] in self?.session?.state }
        midi.defaults = controller.defaults
        let model = SettingsModel(controller: controller, page: page, preferences: prefs, hotkeys: hotkeys, midi: midi,
                                  makeOutputs: { [weak self] tab in self?.makeOutputModel(tab: tab) ?? OutputSettingsModel(state: MixerState(), tab: tab, defaultRecordDirectory: "", showName: "", queriesSystemExtensions: false) },
                                  currentMIDI: { [weak self] in self?.currentMIDIController() ?? MIDIController(bus: CommandBus(stateMachine: SwitcherSession.detachedStateMachine())) })
        let w = SettingsWindowController(model: model)
        w.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = w
        return w
    }

    /// 当前 session 的 MIDI 控制器；没有 session 时给一个不连总线的（只能编辑表，learn 收不到）。
    private func currentMIDIController() -> MIDIController {
        session?.control.midi ?? MIDIController(bus: CommandBus(stateMachine: SwitcherSession.detachedStateMachine()), table: controller.midiTable)
    }

    /// 输出各页的模型（接当前 session：发命令、起不来的原因 / 连接次数、重试、Stats）。
    private func makeOutputModel(tab: OutputSettingsModel.Tab) -> OutputSettingsModel {
        let model = OutputSettingsModel(state: session?.state ?? state, tab: tab, defaultRecordDirectory: controller.documents.recordDirectory,
                                        showName: session?.name ?? "", queriesSystemExtensions: !controller.isTestHost,
                                        reserveBytes: session?.outputs.minimumFreeBytes ?? 0, aux: session?.aux)
        if let stats = session?.stats { model.apply(stats: stats) }
        model.send = { [weak self] c in self?.session?.send(c) }
        // 起不来的原因 / 推流正在第几次连接 / 重试（W5-B：推流页那一段写明原因，起不来的路不锁、可以重试或停用）
        model.routeDetail = { [weak self] n in (self?.session?.outputs.failureReason(output: n), self?.session?.outputs.streamConnectAttempt(output: n)) }
        model.onRetry = { [weak self] numbers in self?.session?.retryFailedOutputs(numbers) }
        model.refreshRouteDetails()
        return model
    }

    /// 设置窗里输出各页的句柄（设置窗开着时）。
    var outputSettingsWindow: SettingsPageHandle<OutputSettingsModel>? { settingsWindow?.outputsPage }
    /// 设置窗里本机 / 节目格式 / 节目音频各页的句柄。
    var preferencesWindow: SettingsPageHandle<PreferencesModel>? { settingsWindow?.preferencesPage }
    /// 设置窗里快捷键页的句柄。
    var hotkeyWindow: SettingsPageHandle<HotkeyEditorModel>? { settingsWindow?.hotkeysPage }
    /// 设置窗里 MIDI 页的句柄。
    var midiWindow: SettingsPageHandle<MIDIMappingModel>? { settingsWindow?.midiPage }

    /// 输出设置的某一页（= showSettings(page: .output(tab))）。
    @discardableResult
    func showOutputSettings(tab: OutputSettingsModel.Tab = .record) -> SettingsPageHandle<OutputSettingsModel> {
        showSettings(page: .output(tab))
        return settingsWindow!.outputsPage
    }

    /// 推流页并把焦点放在"添加目的地"（W5-F，L1：没有目的地时点底栏推流主体）。
    @discardableResult
    func showStreamAddDestination() -> SettingsPageHandle<OutputSettingsModel> {
        let w = showOutputSettings(tab: .stream)
        w.model.requestAddDestinationFocus()
        return w
    }

    /// 常规页（老入口"偏好设置"；节目格式 / 节目音频 / 本机各页共用这一个模型）。
    @discardableResult
    func showPreferences() -> SettingsPageHandle<PreferencesModel> {
        showSettings(page: .general)
        return settingsWindow!.preferencesPage
    }

    /// 快捷键页（= showSettings(page: .hotkeys)）。
    @discardableResult
    func showHotkeyEditor() -> SettingsPageHandle<HotkeyEditorModel> {
        showSettings(page: .hotkeys)
        return settingsWindow!.hotkeysPage
    }

    /// MIDI 页（= showSettings(page: .midi)）。
    @discardableResult
    func showMIDIMapping() -> SettingsPageHandle<MIDIMappingModel> {
        showSettings(page: .midi)
        return settingsWindow!.midiPage
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

    // MARK: 多画面（W3-C 的窗口；窗口菜单 / 底栏走 MainWindowController.toggleMultiviewWindow）

    /// 显示多画面窗口（已显示就不动）。
    func showMultiview() {
        if !controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
    }

    /// 关掉所有面板窗口（退出 / 测试收尾）。外部显示输出留在快照里，窗口（W3-C）跟着快照会再开。
    func closeAll() {
        for (_, w) in inputSettingsWindows { w.close() }
        inputSettingsWindows.removeAll()
        settingsWindow?.close()   // 程序收尾：不问（没存的快捷键 / MIDI 改动丢掉）
        settingsWindow = nil
        if controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
    }
}
