// 面板与窗口的总管（W3-E）：输入设置窗（每路一个）与设置窗（W5-J 合窗：偏好设置、输出设置、快捷键、MIDI 映射合成一个带侧栏的窗，SettingsWindow）。
// ⌘, / 工具条"设置▾" / 各 ⚙ / 菜单里的设置页一律走 showSettings(page:)（SettingsPage）：打开同一个设置窗的对应页，⌘, 回到上次那一页（本机记忆）。
// 换 session 时输入设置窗关掉（模型绑的是旧 session 的那一路）；设置窗不关，只重绑（输出页换成新 session 的模型、格式 / 节目音频重读，W5-B X04 / W5-J F1）。
// 老入口 showPreferences() / showOutputSettings(tab:) / showHotkeyEditor() / showMIDIMapping() 与 xxxWindow 属性照用：返回设置窗里那一页的句柄。
// 多画面窗口 / 外部显示窗口是 W3-C 的（G4 合并时以 W3-C 的运行表为准）：
// W5-K（97）加叠加设置窗（一个）与音频设置窗（每条总线 / 每路输入一个）；输入设置 / 叠加设置 / 音频设置窗在前时，没被文本框吃掉的按键照样走快捷键表（X12，forwardHotkeys）。
// W5-N（101）加推流 / 录制状态面板（一个窗两页）：模型每行 Stats 都喂（窗口关着也记事件），换 session 清空。
// 多画面 = MainWindowController.multiviewWindow，外部显示窗口 = AuxOutputRuntime.external 跟着快照里的 externalDisplay 输出开关
// （设置面板 / 菜单加输出 → 开窗口；用户在外部窗口按 Esc → setOutputEnabled off，W5-O 起只关不删）；这里只留 showMultiview 转调。
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
    /// 叠加设置窗（W5-K）。
    private(set) var overlaySettingsWindow: OverlaySettingsWindowController?
    /// 音频设置窗（每条一个，W5-K）。
    private(set) var audioSettingsWindows: [AudioStrip: AudioSettingsWindowController] = [:]
    /// 统计窗（W5-L，底栏"统计"）。
    private(set) var statsWindow: StatsWindowController?
    /// 推流 / 录制状态面板（W5-N）。
    let outputStatus = OutputStatusModel()
    private(set) var outputStatusWindow: OutputStatusWindowController?
    private var stateToken: ObserverToken?
    private var statsToken: ObserverToken?
    private var session: SwitcherSession?
    private var state = MixerState()
    /// 输出之间的跟随（W5-I：ISO 跟录制 1、推流跟推流 1；OutputLinkage）：每个快照算一次，窗口关着也跟。
    let linkage = OutputLinkageSync()

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
        overlaySettingsWindow?.close()   // 叠加 / 音频设置窗的模型绑的是旧 session（W5-K）
        overlaySettingsWindow = nil
        lastOverlayChannel = 1           // 换了节目从 Overlay 1 开始
        for (_, w) in audioSettingsWindows { w.close() }
        audioSettingsWindows.removeAll()
        self.session = session
        linkage.reset()
        outputStatus.reset()   // 事件记录只属于这一场（W5-N）
        outputStatus.routeFailure = { [weak self] n in self?.session?.outputs.routeFailure(output: n) }   // 状态列与底栏 / 推流页同字（W4-C4 第 5 条）
        guard let session else { state = MixerState(); return }
        state = session.state
        settingsWindow?.model.rebind()
        stateToken = session.observeState { [weak self] state in self?.apply(state: state) }
        // 输出设置页的显示类输出状态读 Stats.display[]（提案 013），1 Hz；统计窗（W5-L）读同一行，换 session 不关、接着读新的
        statsToken = session.observeStats { [weak self] stats in
            guard let self else { return }
            self.settingsWindow?.model.outputs.apply(stats: stats)
            self.statsWindow?.model.apply(stats: stats, state: self.state)
            self.outputStatus.apply(stats: stats, state: self.state)   // 状态面板关着也喂：事件记录要连着（W5-N）
            for (_, w) in self.inputSettingsWindows { w.model.refreshRuntime() }   // 文件播完不出快照：每秒看一次（W4C3 第 5 条）
            for (_, w) in self.audioSettingsWindows { w.model.apply(stats: stats) }   // 效果链延迟 / 延迟自测（提案 030，W5-Q）
        }
    }

    private func apply(state: MixerState) {
        self.state = state
        for c in linkage.commands(for: state) { session?.send(c) }
        for (number, w) in inputSettingsWindows {
            if state.input(number) == nil { w.close(); inputSettingsWindows.removeValue(forKey: number) } else { w.apply(state: state) }
        }
        settingsWindow?.model.outputs.apply(state: state)
        overlaySettingsWindow?.apply(state: state)
        for (strip, w) in audioSettingsWindows {
            if case .input(let n) = strip, state.input(n) == nil { w.close(); audioSettingsWindows.removeValue(forKey: strip) } else { w.apply(state: state) }
        }
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
        // 起不来的原因 / 重试（W5-B：推流页那一段写明原因，起不来的路不锁、可以重试或停用）；第几次连接 W5-N 起读 Stats 的 attempt
        model.routeFailure = { [weak self] n in self?.session?.outputs.routeFailure(output: n) }
        model.authParamMemory = StreamAuthParamMemory(defaults: controller.defaults)   // 查询串鉴权用过的参数名记在本机（W5-P，W4C3 第 9 条）
        model.showOutputStatus = { [weak self] page in self?.showOutputStatus(page) }
        model.onRetry = { [weak self] numbers in self?.session?.retryFailedOutputs(numbers) }
        model.refreshRouteDetails()
        // 推流页停一路 / 全部停止：与底栏同一问（W5-B），挂在设置窗上；偏好设置里关了就直接停（W5-I 写在旧的输出设置窗上，G7 合并时搬进 W5-J 的设置窗）
        model.confirmStop = { [weak self] kind, routes, perform in
            guard let self, self.controller.settings.confirmBeforeStop else { perform(); return }
            let names = routes.map(\.name).joined(separator: L("confirm.part.separator"))
            let title = kind == .stopRecord ? L("confirm.stopRecord.title", routes.count) : L("confirm.stopStream.title", routes.count)
            let button = kind == .stopRecord ? L("confirm.stopRecord.button") : L("confirm.stopStream.button")
            let request = ConfirmationCenter.Request(kind: kind, title: title, message: L("confirm.stop.message", names),
                                                     buttons: [.init(title: button, choice: .confirm, destructive: true), .init(title: L("common.cancel"), choice: .cancel)],
                                                     defaultChoice: nil)
            ConfirmationCenter.shared.ask(request, in: self.settingsWindow?.window) { choice in if choice == .confirm { perform() } }
        }
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
        model.runtimeState = { [weak session] in session?.inputs.runtimeState(of: number) }   // "播完"要看跑着的那个（W5-P，W4C3 第 5 条）
        model.runtimeNote = { [weak session] in   // "来源"一节写这一路自己报的那句（W4-C4 第 1 条）
            guard let session else { return nil }
            return session.inputs.runtimeState(of: number) == .noSignal ? session.inputs.lastError(of: number) : session.inputs.liveNote(of: number)
        }
        let w = InputSettingsWindowController(model: model)
        w.attach(source: session.displaySource, format: session.format)   // 本路画面：多画面纹理裁这一格（W5-K / H3）
        w.apply(state: state.input(number) != nil ? state : session.state)
        forwardHotkeys(w)
        w.onClose = { [weak self] in self?.inputSettingsWindows.removeValue(forKey: number) }
        // 这一路没存过位置（居中摆的）、又已经开着别的输入设置窗：错开放在最近那个的右下，不叠在一起（X44）
        if !w.restoredSavedFrame, let last = inputSettingsWindows.values.compactMap(\.window).filter(\.isVisible).max(by: { $0.orderedIndex > $1.orderedIndex }) {
            w.window?.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        inputSettingsWindows[number] = w
        w.present()
        return w
    }

    /// 设置类窗口在前时，没被文本框吃掉的按键照样走快捷键表（02 X12：原来只有主窗口是 key 时才派发，输入设置 / 叠加 / 音频设置窗在前按空格不切）。
    private func forwardHotkeys(_ w: PanelWindowController) {
        (w.window as? PanelWindow)?.keyHandler = { [weak self] event in self?.session?.control.handleKey(event) ?? false }
    }

    // MARK: 叠加设置窗 / 音频设置窗（W5-K）

    /// 叠加设置窗（I1）：只有一个；channel = 直达第 k 路（转场列 / 格子的右键），nil = 停在上次那一路（底栏"叠加…"）。已经开着就置前、切通道。
    @discardableResult
    func showOverlaySettings(channel: Int?) -> OverlaySettingsWindowController {
        if let w = overlaySettingsWindow {
            if let channel { w.model.channel = channel }
            w.present()
            return w
        }
        let model = OverlaySettingsModel(state: session?.state ?? state, channel: channel ?? lastOverlayChannel)
        model.send = { [weak self] c in self?.session?.send(c) }
        let w = OverlaySettingsWindowController(model: model)
        forwardHotkeys(w)
        w.onClose = { [weak self, weak w] in
            if let w { self?.lastOverlayChannel = w.model.channel }
            self?.overlaySettingsWindow = nil
        }
        overlaySettingsWindow = w
        w.present()
        return w
    }

    /// 叠加设置窗上次停在哪一路（关了再从底栏开，还是那一路；换节目回到 1）。
    private var lastOverlayChannel = 1

    /// 音频设置窗（J2 / J3）：每条总线 / 每路输入一个，同一条再点 = 置前（page 给了就切到那一页）。表读调音台同一份 50 ms 读数；
    /// 效果链延迟 / 延迟自测读 Stats（提案 030，1 Hz，bind 里每行喂；开窗时先给最近一行）。
    @discardableResult
    func showAudioSettings(_ strip: AudioStrip, page: AudioSettingsPage? = nil) -> AudioSettingsWindowController? {
        guard let session else { return nil }
        if case .input(let n) = strip, state.input(n) == nil, session.state.input(n) == nil { return nil }
        if let w = audioSettingsWindows[strip] {
            if let page, w.model.pages.contains(page) { w.model.page = page }
            w.present()
            return w
        }
        let model = AudioSettingsModel(strip: strip, state: session.state, page: page ?? .general)
        if let stats = session.stats { model.apply(stats: stats) }
        model.send = { [weak session] c in session?.send(c) }
        model.onOpenInputSettings = { [weak self] n in self?.showInputSettings(input: n) }
        let w = AudioSettingsWindowController(model: model, meters: controller.windowController.mixerPanel.meters)
        forwardHotkeys(w)
        w.onClose = { [weak self] in self?.audioSettingsWindows.removeValue(forKey: strip) }
        // 没存过位置、又已经开着别的音频设置窗：错开放（同输入设置窗，X44）
        if !w.restoredSavedFrame, let last = audioSettingsWindows.values.compactMap(\.window).filter(\.isVisible).max(by: { $0.orderedIndex > $1.orderedIndex }) {
            w.window?.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        audioSettingsWindows[strip] = w
        w.present()
        return w
    }

    /// 推流 / 录制状态面板（W5-N）：停在给的那一页；已开就置前。
    @discardableResult
    func showOutputStatus(_ page: OutputStatusModel.Page) -> OutputStatusWindowController? {
        outputStatus.page = page
        if let w = outputStatusWindow {
            w.present()
            return w
        }
        let w = OutputStatusWindowController(model: outputStatus)
        forwardHotkeys(w)   // 直播中盯着看的窗：开着它按空格照样切（W5-P，W4C3 第 2 条，X12 同一类）
        w.onClose = { [weak self] in self?.outputStatusWindow = nil }
        outputStatusWindow = w
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
        forwardHotkeys(w)   // 同上（W4C3 第 2 条）
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
        settingsWindow?.close()   // 程序收尾：不问（没存的快捷键 / MIDI 改动丢掉）
        settingsWindow = nil
        overlaySettingsWindow?.close()
        overlaySettingsWindow = nil
        for (_, w) in audioSettingsWindows { w.close() }
        audioSettingsWindows.removeAll()
        statsWindow?.close()
        statsWindow = nil
        outputStatusWindow?.close()
        outputStatusWindow = nil
        if controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
    }
}
