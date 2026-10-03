// 设置窗（W5-J 第二步：合窗，01a F1 / F4–F7，04 Q04 (a)，02 X29）：偏好设置、输出设置、快捷键、MIDI 映射合成一个带侧栏的窗。
// 侧栏两组（SettingsPage）：本节目（随节目文件保存）/ 本机（存在这台 Mac 上）；页头写明存在哪。
// - 提交方式统一即时生效；要换引擎的项集中到页底"应用并重起引擎"（"有 n 项待应用：…"），录制 / 推流在跑先确认（PreferencesModel）。
// - 快捷键 / MIDI 的表要整张校验才能存：有未存的改动时关窗或切页先问 保存 / 放弃 / 取消（存不了 = 不关、不切，错误写在表下面）。
// - 换引擎（新建 / 打开 / 换格式 / 重起）时窗不关，只重绑：输出页换成新 session 的模型、节目格式 / 节目音频重读、MIDI 的 learn 换到新的控制器。
// - 底部：导出设置… / 导入设置… / 恢复默认（只动本机级，SettingsTransfer）。
// 老入口（showPreferences() / showOutputSettings(tab:) / showHotkeyEditor() / showMIDIMapping() 与它们的 xxxWindow 属性）返回这扇窗里那一页的句柄
// （SettingsPageHandle：model + 同一个 window），调用方与用例照用。
import AppKit
import Combine
import SwiftUI
import SwitcherContracts
import SwitcherControl

extension SettingsPage {
    /// 侧栏 / 菜单里的名字。
    var title: String {
        switch self {
        case .output(let tab): tab.title
        default: L("settings.page.\(id)")
        }
    }
}

extension SettingsPage.Group {
    var title: String { L("settings.group.\(rawValue)") }
    /// 页头写的"存在哪"。
    var storageNote: String { L("settings.storage.\(rawValue)") }
}

/// 要先存才能离开的那两张表。
enum SettingsTable: Sendable {
    case hotkeys, midi
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var page: SettingsPage
    let preferences: PreferencesModel
    @Published private(set) var outputs: OutputSettingsModel
    let hotkeys: HotkeyEditorModel
    let midi: MIDIMappingModel
    /// 导出 / 导入出的错（给人看）。
    @Published private(set) var transferError: String?
    /// 确认 sheet 挂在哪（设置窗）。
    weak var window: NSWindow? {
        didSet { preferences.presentingWindow = window }
    }
    private unowned let controller: AppController
    /// 输出页的模型怎么建（PanelCoordinator 给：接当前 session 的命令、运行表、Stats）。
    private let makeOutputs: (OutputSettingsModel.Tab) -> OutputSettingsModel
    /// 当前 session 的 MIDI 控制器（learn、来源列表）。
    private let currentMIDI: () -> MIDIController
    private var forwarding: Set<AnyCancellable> = []

    init(controller: AppController, page: SettingsPage, preferences: PreferencesModel, hotkeys: HotkeyEditorModel, midi: MIDIMappingModel,
         makeOutputs: @escaping (OutputSettingsModel.Tab) -> OutputSettingsModel, currentMIDI: @escaping () -> MIDIController) {
        self.controller = controller
        self.page = page
        self.preferences = preferences
        self.hotkeys = hotkeys
        self.midi = midi
        self.makeOutputs = makeOutputs
        self.currentMIDI = currentMIDI
        if case .output(let tab) = page { outputs = makeOutputs(tab) } else { outputs = makeOutputs(.record) }
        // 页底"有 n 项待应用"、表下面的错误跟着子模型变
        for publisher in [preferences.objectWillChange, hotkeys.objectWillChange, midi.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &forwarding)
        }
    }

    /// 侧栏：两组、各组的页。
    var sidebar: [(group: SettingsPage.Group, pages: [SettingsPage])] {
        SettingsPage.Group.allCases.map { ($0, SettingsPage.pages(in: $0)) }
    }

    /// 页头写的"存在哪"。
    var storageNote: String { page.group.storageNote }

    /// 页底那一行："有 2 项待应用：节目格式、音频设备"；没有为空串。
    var pendingSummary: String {
        let items = preferences.pendingRestart
        guard !items.isEmpty else { return "" }
        return L("settings.pending.summary", items.count, items.map(\.title).joined(separator: L("key.listSeparator")))
    }

    // MARK: 切页 / 关窗

    /// 没存的那张表（当前页的优先）。
    var dirtyTable: SettingsTable? {
        let current: SettingsTable? = page == .hotkeys ? .hotkeys : (page == .midi ? .midi : nil)
        for t in [current, .hotkeys, .midi].compactMap({ $0 }) where isDirty(t) { return t }
        return nil
    }

    private func isDirty(_ t: SettingsTable) -> Bool { t == .hotkeys ? hotkeys.isDirty : midi.isDirty }

    /// 切到另一页：离开的那页是快捷键 / MIDI 且有没存的改动 → 先问；取消 = 留在原页。completion(true) = 切过去了。
    func select(_ target: SettingsPage, completion: ((Bool) -> Void)? = nil) {
        guard target != page else {
            if case .output(let tab) = target, outputs.tab != tab { outputs.tab = tab }
            completion?(true)
            return
        }
        let leaving: SettingsTable? = page == .hotkeys ? .hotkeys : (page == .midi ? .midi : nil)
        guard let leaving, isDirty(leaving) else {
            go(target)
            completion?(true)
            return
        }
        askToLeave(leaving) { [weak self] ok in
            if ok { self?.go(target) }
            completion?(ok)
        }
    }

    private func go(_ target: SettingsPage) {
        if page == .midi, midi.learningRow != nil { midi.cancelLearn() }
        if page == .hotkeys { hotkeys.cancelRecording() }
        if case .output(let tab) = target { outputs.tab = tab }
        page = target
    }

    /// 关窗前：有没存的表就问（一张一张问），都过了 proceed(true)；任何一次取消 / 存不了 = proceed(false)。
    func confirmClosing(_ proceed: @escaping (Bool) -> Void) {
        guard let table = dirtyTable else {
            proceed(true)
            return
        }
        askToLeave(table) { [weak self] ok in
            guard ok, let self else { proceed(false); return }
            // 下一问（另一张表）等这一个 sheet 收起来再弹
            DispatchQueue.main.async { MainActor.assumeIsolated { self.confirmClosing(proceed) } }
        }
    }

    /// 问"保存 / 放弃 / 取消"：保存 = 存（存不了算没过，错误写在表下面）；放弃 = 回到上次存的表。
    private func askToLeave(_ table: SettingsTable, proceed: @escaping (Bool) -> Void) {
        let title = table == .hotkeys ? L("settings.unsaved.hotkeys") : L("settings.unsaved.midi")
        let request = ConfirmationCenter.Request(kind: .unsavedSettings, title: title, message: L("settings.unsaved.message"),
                                                 buttons: [.init(title: L("settings.unsaved.save"), choice: .confirm),
                                                           .init(title: L("common.cancel"), choice: .cancel),
                                                           .init(title: L("settings.unsaved.discard"), choice: .alternate, destructive: true)],
                                                 defaultChoice: .confirm)
        ConfirmationCenter.shared.ask(request, in: window) { [weak self] choice in
            guard let self else { proceed(false); return }
            switch choice {
            case .confirm: proceed(table == .hotkeys ? self.hotkeys.save() : self.midi.save())
            case .alternate:
                if table == .hotkeys { self.hotkeys.revert() } else { self.midi.revert() }
                proceed(true)
            case .cancel: proceed(false)
            }
        }
    }

    /// 窗关了：停掉 MIDI 来源刷新与 learn、录键。
    func willClose() {
        midi.stopRefreshing()
        if midi.learningRow != nil { midi.cancelLearn() }
        hotkeys.cancelRecording()
    }

    // MARK: 换引擎

    /// 换了 session：窗不关，只重绑（输出页换成新 session 的模型，页不变；格式 / 节目音频重读；MIDI 换控制器；快捷键表没改过就重读）。
    func rebind() {
        preferences.rebind()
        outputs = makeOutputs(outputs.tab)
        midi.rebind(controller: currentMIDI())
        if !hotkeys.isDirty, hotkeys.savedTable != controller.hotkeyTable { hotkeys.reload(from: controller.hotkeyTable) }
    }

    /// 快捷键 / MIDI 表按 AppController 现在的重读（在别处换了表之后）。
    func reloadTables() {
        hotkeys.reload(from: controller.hotkeyTable)
        midi.reload(from: controller.midiTable)
    }

    // MARK: 导出 / 导入 / 恢复默认（F6）

    func exportSettings(to url: URL) {
        do {
            try SettingsTransfer.export(controller: controller, to: url)
            transferError = nil
        } catch {
            transferError = L("settings.transfer.exportFailed", "\(error)")
        }
    }

    /// 导入：先读、校验，列出要覆盖什么问一声，确认了才写。读不出来写 transferError、什么都不改。
    func importSettings(from url: URL) {
        let package: SettingsTransfer.Package
        do {
            package = try SettingsTransfer.Package.load(from: url)
        } catch {
            transferError = L("settings.transfer.importFailed", url.lastPathComponent, "\(error)")
            return
        }
        transferError = nil
        let request = ConfirmationCenter.Request(kind: .resetSettings, title: L("settings.transfer.importTitle", url.lastPathComponent),
                                                 message: L("settings.transfer.importMessage", SettingsTransfer.summary(of: package)),
                                                 buttons: [.init(title: L("settings.transfer.importButton"), choice: .confirm, destructive: true),
                                                           .init(title: L("common.cancel"), choice: .cancel)],
                                                 defaultChoice: nil)
        ConfirmationCenter.shared.ask(request, in: window) { [weak self] choice in
            guard choice == .confirm, let self else { return }
            do {
                try SettingsTransfer.apply(package, controller: self.controller)
                self.reloadAfterTransfer()
            } catch {
                self.transferError = L("settings.transfer.importFailed", url.lastPathComponent, "\(error)")
            }
        }
    }

    /// 恢复默认：只动本机级（本机设置、快捷键表、MIDI 映射），不动节目；先问。
    func restoreDefaults() {
        let request = ConfirmationCenter.Request(kind: .resetSettings, title: L("settings.transfer.resetTitle"), message: L("settings.transfer.resetMessage"),
                                                 buttons: [.init(title: L("settings.transfer.resetButton"), choice: .confirm, destructive: true),
                                                           .init(title: L("common.cancel"), choice: .cancel)],
                                                 defaultChoice: nil)
        ConfirmationCenter.shared.ask(request, in: window) { [weak self] choice in
            guard choice == .confirm, let self else { return }
            do {
                try SettingsTransfer.restoreDefaults(controller: self.controller)
                self.reloadAfterTransfer()
            } catch {
                self.transferError = L("settings.transfer.resetFailed", "\(error)")
            }
        }
    }

    private func reloadAfterTransfer() {
        transferError = nil
        preferences.reloadMachineSettings()
        reloadTables()
    }
}

// MARK: 视图

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: Binding(get: { model.page }, set: { if let p = $0 { model.select(p) } })) {
                    ForEach(model.sidebar, id: \.group) { section in
                        Section(section.group.title) {
                            ForEach(section.pages, id: \.self) { p in Text(p.title).tag(p) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 190)
                .accessibilityLabel(L("settings.sidebar"))
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.page.title).font(.title3.bold())
                        Text(model.storageNote).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .showFormat: ShowFormatPage(model: model.preferences)
        case .output: OutputSettingsView(model: model.outputs, showsTabList: false)
        case .showAudio: ShowAudioPage(model: model.preferences)
        case .general: GeneralPage(model: model.preferences)
        case .audioDevice: AudioDevicePage(model: model.preferences)
        case .remoteControl: RemoteControlPage(model: model.preferences, openAdvanced: { model.select(.advanced) })
        case .tally: TallyPage()
        case .hotkeys: HotkeyEditorView(model: model.hotkeys)
        case .midi: MIDIMappingView(model: model.midi)
        case .performance: PerformancePage()
        case .updates: UpdatesPage(model: model.preferences)
        case .advanced: AdvancedPage(model: model.preferences)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(L("settings.transfer.export")) { exportPanel() }
            Button(L("settings.transfer.import")) { importPanel() }
            Button(L("settings.transfer.reset")) { model.restoreDefaults() }
            if let error = model.transferError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
            Spacer()
            if !model.pendingSummary.isEmpty {
                Text(model.pendingSummary).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Button(L("prefs.applyRestart")) { model.preferences.applyPendingAndRestart() }
                .disabled(model.preferences.pendingRestart.isEmpty)
        }
        .padding(10)
    }

    private func exportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = L("settings.transfer.fileName")
        guard let window = model.window else { return }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                model.exportSettings(to: url)
            }
        }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard let window = model.window else { return }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                // 打开面板的 sheet 收起来之后再弹确认
                DispatchQueue.main.async { MainActor.assumeIsolated { model.importSettings(from: url) } }
            }
        }
    }
}

// MARK: 窗

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    /// 窗关掉时（PanelCoordinator 清引用）。
    var onClose: (() -> Void)?
    static let autosaveName = "Settings"

    /// 老入口的句柄（同一个窗，各自的模型；对象固定，`===` 比得住）。
    private(set) lazy var outputsPage = SettingsPageHandle<OutputSettingsModel>(owner: self) { $0.model.outputs }
    private(set) lazy var preferencesPage = SettingsPageHandle<PreferencesModel>(owner: self) { $0.model.preferences }
    private(set) lazy var hotkeysPage = SettingsPageHandle<HotkeyEditorModel>(owner: self) { $0.model.hotkeys }
    private(set) lazy var midiPage = SettingsPageHandle<MIDIMappingModel>(owner: self) { $0.model.midi }

    init(model: SettingsModel) {
        self.model = model
        // 默认高 760：侧栏两组 20 页不用滚就看得全（macOS 27 的侧栏行高）
        let window = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
        window.title = L("settings.windowTitle")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 500)
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.sizingOptions = []
        window.contentView = host
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleRecordingKey(event) ?? false }
        model.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 显示并置前。
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 快捷键页录键中：把按键写进那一行并吃掉事件。
    @discardableResult
    func handleRecordingKey(_ event: NSEvent) -> Bool {
        guard model.hotkeys.recordingRow != nil, event.type == .keyDown, !event.isARepeat, let combo = KeyCombo(event: event) else { return false }
        model.hotkeys.recorded(combo)
        return true
    }

    /// 关窗前：快捷键 / MIDI 有没存的改动先问（X29）。问完再关（等 sheet 收起）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.dirtyTable != nil else { return true }
        model.confirmClosing { [weak self] ok in
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self?.window?.close() } }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.willClose()
        onClose?()
    }
}

/// 设置窗里某一页的句柄（老入口的返回值）：那一页的模型 + 同一个窗。
@MainActor
final class SettingsPageHandle<Model: AnyObject> {
    private unowned let owner: SettingsWindowController
    private let fetch: (SettingsWindowController) -> Model

    init(owner: SettingsWindowController, fetch: @escaping (SettingsWindowController) -> Model) {
        self.owner = owner
        self.fetch = fetch
    }

    var model: Model { fetch(owner) }
    var window: NSWindow? { owner.window }
    func present() { owner.present() }
    func close() { owner.close() }
}

extension SettingsPageHandle where Model == HotkeyEditorModel {
    /// 录键中：把按键写进那一行并吃掉事件（快捷键页）。
    @discardableResult
    func handleRecordingKey(_ event: NSEvent) -> Bool { owner.handleRecordingKey(event) }
}

extension SettingsPageHandle where Model == OutputSettingsModel {
    func apply(state: MixerState) { model.apply(state: state) }
}
