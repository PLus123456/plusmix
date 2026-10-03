// 面板与窗口的总管（W3-E）：输入设置窗（每路一个）、输出设置窗、偏好设置、快捷键编辑器、MIDI 映射；W5-K 加叠加设置窗（一个）与音频设置窗（每条总线 / 每路输入一个）。
// 输入设置 / 叠加设置 / 音频设置窗在前时，没被文本框吃掉的按键照样走快捷键表（X12，forwardHotkeys）。
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
    /// 叠加设置窗（W5-K）。
    private(set) var overlaySettingsWindow: OverlaySettingsWindowController?
    /// 音频设置窗（每条一个，W5-K）。
    private(set) var audioSettingsWindows: [AudioStrip: AudioSettingsWindowController] = [:]
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
        overlaySettingsWindow?.close()   // 叠加 / 音频设置窗的模型绑的是旧 session（W5-K）
        overlaySettingsWindow = nil
        for (_, w) in audioSettingsWindows { w.close() }
        audioSettingsWindows.removeAll()
        self.session = session
        guard let session else { state = MixerState(); return }
        preferencesWindow?.model.rebind()
        stateToken = session.observeState { [weak self] state in self?.apply(state: state) }
        // 输出设置页的显示类输出状态读 Stats.display[]（提案 013），1 Hz
        statsToken = session.observeStats { [weak self] stats in self?.outputSettingsWindow?.model.apply(stats: stats) }
    }

    private func apply(state: MixerState) {
        self.state = state
        for (number, w) in inputSettingsWindows {
            if state.input(number) == nil { w.close(); inputSettingsWindows.removeValue(forKey: number) } else { w.apply(state: state) }
        }
        outputSettingsWindow?.apply(state: state)
        overlaySettingsWindow?.apply(state: state)
        for (strip, w) in audioSettingsWindows {
            if case .input(let n) = strip, state.input(n) == nil { w.close(); audioSettingsWindows.removeValue(forKey: strip) } else { w.apply(state: state) }
        }
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

    /// 叠加设置窗上次停在哪一路（关了再从底栏开，还是那一路）。
    private var lastOverlayChannel = 1

    /// 音频设置窗（J2 / J3）：每条总线 / 每路输入一个，同一条再点 = 置前（page 给了就切到那一页）。表读调音台同一份 50 ms 读数。
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
        overlaySettingsWindow?.close()
        overlaySettingsWindow = nil
        for (_, w) in audioSettingsWindows { w.close() }
        audioSettingsWindows.removeAll()
        if controller.windowController.isMultiviewWindowVisible { controller.windowController.toggleMultiviewWindow() }
    }
}
