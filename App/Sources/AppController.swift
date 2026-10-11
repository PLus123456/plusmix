// App 的总管：一个 session（节目跑起来）+ 主窗口 + 节目文件 + 面板（W3-E）。新建 / 打开总是换一个新 session（节目格式可能变，引擎的格式在 init 定死）。
// W5-B（02 X03 / X04 / X30，01a A3 / F5，04 Q67 (a)）：新建 / 打开 / 退出 / 偏好设置里换引擎之前，录制 / 推流在跑先确认"会停止 n 路录制、m 路推流"；
// 节目有未保存的改动（documentContent 口径）时问 保存 / 不保存 / 取消，窗口用 isDocumentEdited 标出来；退出不再静默写回已打开的文件，LastSession 照存。
// 这些问只在界面入口（菜单 / 偏好设置 / 关主窗口）上；newShow / openShow / changeProgramFormat 等直接调用的路径（测试、内部）不问。
import AppKit
import SwitcherContracts
import SwitcherControl

@MainActor
final class AppController {
    let windowController = MainWindowController()
    let documents: ShowDocuments
    private(set) var session: SwitcherSession?
    /// 上一次 replaceSession 抛的错（测试看）。
    private(set) var lastError: (any Error)?
    /// 进程里第一次起好的会话的起步记录（启动时那个：第一次连 MIDIServer 这类冷启动只在它身上发生；诊断 / 测试看，W3-E6）。
    private(set) var firstStartReport: SwitcherSession.StartReport?
    /// 是否在测试宿主里跑（不恢复上次、不写"上次文件"、录到临时目录、API 端口由系统分配、快捷键 / MIDI 表在临时目录、固定 zh-Hans）。
    let isTestHost: Bool
    /// UserDefaults（测试宿主用独立 suite）。
    let defaults: UserDefaults
    /// 起 session 用的设置（AppDelegate 启动时按参数 / UserDefaults 填；偏好设置面板改后写回同一组键；测试宿主固定：API 端口 0（系统分配）、
    /// 音频空设备（SWITCHER_TEST_AUDIO=default 可改成真设备，跑 xcodebuild test 时会出声）。
    var settings = AppSettings() {
        didSet {
            if isTestHost { applyTestHostOverrides() }
            applyRuntimeSettings(previous: oldValue)
        }
    }
    /// 快捷键表：用户表 ~/Library/Application Support/PlusMix/hotkeys.json，没有就默认表；测试宿主固定默认表（文件在临时目录）。
    private(set) var hotkeyTable: HotkeyTable
    /// MIDI 映射表：用户表 midi.json，没有就空表。
    private(set) var midiTable: MIDIMapTable
    /// 两张表的文件位置（编辑器保存到这里）。
    let hotkeyFileURL: URL
    let midiFileURL: URL
    /// 用户表存在但读不出来（JSON 错 / 冲突）的原因：退回默认表并在状态行提示。
    private(set) var hotkeyTableError: String?
    /// 面板与窗口（W3-E）。
    lazy var panels = PanelCoordinator(controller: self)
    /// 添加输入的本机记忆：上次的类型、最近添加的来源（W5-F，底栏"添加输入 ▴"与菜单栏"按类型添加"）。
    let addInputHistory: AddInputHistory
    /// 输入条的本机偏好（W5-H）。
    let stripPreferences: InputStripPreferences
    /// 自动更新（W4-B，Sparkle）：Info.plist 里没有更新源 / 公钥（开发、ad-hoc、测试宿主）就不起。
    let updateController: UpdateController
    /// 引擎运行时拿着的"别睡"（W5-L，P1）：系统睡眠 + App Nap 一条、显示器休眠一条，按设置"性能与电源"的两个开关。
    let engineActivity = EngineActivity()
    private var replacing = false
    /// 未保存判定的基准：上次新建 / 打开 / 保存时的"节目内容"（documentContent）；与当前的不同 = 有未保存的改动（W5-B）。
    private var documentBaseline: Show?
    private var documentToken: ObserverToken?
    /// 节目有没有未保存的改动：窗口用 isDocumentEdited 标出来（关闭按钮上的点），新建 / 打开 / 退出前问保存。口径见 documentContent。
    private(set) var isDocumentEdited = false {
        didSet { if oldValue != isDocumentEdited { windowController.window?.isDocumentEdited = isDocumentEdited } }
    }

    /// 测试宿主的 UserDefaults suite：按这份构建所在的位置分开（每个 worktree 有自己的 DerivedData）。原来所有 worktree 共用一个 suite，
    /// 几个会话同时跑 App 测试时，别的进程 freshSession 清"添加输入的本机记忆"会把这边正在用的键清掉（W5-K 实测：上次的类型 / 最近文件读回来是空的）。
    static let testDefaultsSuite: String = {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a：同一个位置每次一样
        for byte in Bundle.main.bundlePath.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return "com.plusmix.switcher.tests." + String(hash, radix: 36)
    }()

    init(isTestHost: Bool) {
        self.isTestHost = isTestHost
        // CoreMIDI 的热插拔通知：W2-C2 起由 SwitcherControl 的进程级 MIDIHost（常驻线程 + 永不销毁的锚客户端）接住，换节目后新插的设备照常连上；
        // App 自己在主线程建的锚客户端（W3-E2 加的绕法）删了（W3-E5），守门用例 testMIDI_hotplugAfterShowReplaced_newSourceConnects
        defaults = isTestHost ? UserDefaults(suiteName: Self.testDefaultsSuite) ?? .standard : .standard
        updateController = UpdateController(defaults: defaults, isTestHost: isTestHost)
        addInputHistory = AddInputHistory(defaults: defaults)
        stripPreferences = InputStripPreferences(defaults: defaults)
        if isTestHost {
            L10n.languageOverride = "zh-Hans"
            let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/config", isDirectory: true)
            try? FileManager.default.removeItem(at: configDir)
            hotkeyFileURL = configDir.appendingPathComponent("hotkeys.json")
            midiFileURL = configDir.appendingPathComponent("midi.json")
            hotkeyTable = .default
            midiTable = .default
        } else {
            hotkeyFileURL = HotkeyTable.defaultFileURL
            midiFileURL = MIDIMapTable.defaultFileURL
            if FileManager.default.fileExists(atPath: HotkeyTable.defaultFileURL.path) {
                do {
                    hotkeyTable = try HotkeyTable.load(from: HotkeyTable.defaultFileURL)
                } catch {
                    hotkeyTable = .default
                    hotkeyTableError = L("notice.hotkeyTableUnreadable", HotkeyTable.defaultFileURL.path, "\(error)")
                }
            } else {
                hotkeyTable = .default
            }
            midiTable = MIDIMapTable.loadUserTableOrDefault()
        }
        if isTestHost {
            let tests = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests", isDirectory: true)
            // LastSession 也放临时目录：测试宿主走退出的整条路（W5-B），不碰用户的 ~/Library/Application Support/PlusMix/LastSession
            documents = ShowDocuments(defaults: defaults, recordDirectory: tests.appendingPathComponent("records", isDirectory: true).path,
                                      autosaveURL: tests.appendingPathComponent("LastSession.\(ShowDocuments.fileExtension)"))
            applyTestHostOverrides()
        } else {
            documents = ShowDocuments(defaults: defaults)
        }
        windowController.defaultRecordDirectory = documents.recordDirectory
        windowController.panels = panels
        windowController.addInputHistory = addInputHistory
        windowController.stripPreferences = stripPreferences   // 缩略图大小（W5-H）
        windowController.onDocumentContentChanged = { [weak self] in self?.refreshDocumentEdited() }   // 分类存在 Show.layout 里（W5-H）
        windowController.bottomBar.shouldConfirmStop = { [weak self] in self?.settings.confirmBeforeStop ?? true }
        // 工具条"打开▾"：与"节目 › 打开最近"同一份最近列表（W5-G，A2）
        windowController.mainToolbar.openMenuProvider = { [weak self] in ShowMenu.openMenu(urls: self?.documents.recentURLs ?? []) }
    }

    private func applyTestHostOverrides() {
        var s = settings
        s.apiPort = 0
        s.audioDevice = ProcessInfo.processInfo.environment["SWITCHER_TEST_AUDIO"].map { AppSettings.AudioDevice(spec: $0) } ?? .null
        // 测试宿主不在局域网上监听（W5-L）：本机防火墙开着时，听 0.0.0.0 会弹"允许传入连接"框，无人值守的测试会卡在那里；
        // 设置里存的照存（远程控制页 / Tally 页的用例核对的是存下来的值），只是跑起来一律听本机、tally 端口由系统分配
        s.apiHost = "127.0.0.1"
        s.compatLayerHost = "127.0.0.1"
        s.tallyHost = "127.0.0.1"
        s.tallyPort = 0
        if s != settings { settings = s }
    }

    /// 运行时就能生效的几项（W5-L）：两条"别睡"、主窗口提醒的设置、tally 流（开关 / 端口变了就让跑着的 session 起 / 停 / 换端口）。
    /// API / 兼容层 / 音频设备照旧下次起引擎生效（"应用并重起引擎"）。
    private func applyRuntimeSettings(previous: AppSettings) {
        refreshEngineActivity()
        windowController.reminderSettings = settings.reminders
        if settings.tallyConfiguration != previous.tallyConfiguration { applyTallySettings() }
    }

    /// 引擎在跑 + 设置"性能与电源"的两个开关 → 拿 / 放两条"别睡"（起好引擎、停了引擎、改了开关都调）。
    private func refreshEngineActivity() {
        engineActivity.update(engineRunning: session?.isRunning == true, preventSleep: settings.preventSleepWhileRunning,
                              preventDisplaySleep: settings.preventDisplaySleepWhileRunning)
    }

    /// 跑着的 session 按当前设置起 / 停 / 换 tally 流（设置 › Tally 即时生效）；起不来在状态行提示。
    private func applyTallySettings() {
        guard let session else { return }
        let configuration = settings.tallyConfiguration
        Task { @MainActor [weak self] in
            await session.control.setTally(configuration)
            if configuration != nil, let error = session.control.tallyError { self?.windowController.bottomBar.showNotice(error) }
        }
    }

    // MARK: 启动 / 退出

    /// 启动：命令行指定的文件 → 恢复上次的文件 → 没有就恢复退出时自动存的 → 再没有就空节目。测试宿主永远空节目。
    func launch(showURL: URL? = nil) async {
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.window?.makeFirstResponder(nil)   // 快捷键直接到窗口；搜索框要点了才有焦点
        var show = documents.emptyShow()
        var baseline = DocumentBaseline.current
        if let showURL {
            do { show = try documents.load(from: showURL) } catch { presentError(error, context: L("error.open", showURL.lastPathComponent)) }
        } else if !isTestHost {
            if let url = documents.lastURL, let loaded = try? documents.load(from: url) {
                show = loaded
            } else if let auto = documents.loadAutosave() {
                show = auto
                documents.startNew()
                baseline = .empty   // 从 LastSession 恢复的没存成文件：有内容就算未保存
            }
        }
        await replaceSession(show: show, baseline: baseline)
    }

    /// 退出（退出前那一问已经过了）：LastSession 照存——崩溃恢复、下次启动没有上次的文件时从它恢复；不再静默写回已打开的节目文件，
    /// 要不要存由退出前那一问定（W5-B，Q67 (a)，X30）。然后停引擎。
    func shutdown() async {
        if let session { documents.autosave(session.makeShow()) }
        await stopSession()
    }

    // MARK: session

    /// 换 session 时未保存判定的基准怎么定（W5-B）。
    enum DocumentBaseline {
        /// 以新 session 起好时的内容为准（新建、打开文件、启动时打开上次的文件）。
        case current
        /// 和空节目比（启动时从 LastSession 恢复的、没存成文件的节目：有内容就算未保存）。
        case empty
        /// 沿用原来的（同一个节目换引擎：换格式 / 节目音频 / 重起；换了的格式本身就是一处改动）。
        case keep
    }

    func replaceSession(show: Show, baseline: DocumentBaseline = .current) async {
        guard !replacing else { return }
        replacing = true
        defer { replacing = false }
        await stopSession()
        do {
            // 素材相对路径按节目文件所在目录找（W3-E5）；新建 / 从 LastSession 恢复的没有文件，退到默认录制目录
            let s = try SwitcherSession(show: show, settings: settings, hotkeyTable: hotkeyTable, midiTable: midiTable,
                                        mediaBaseDirectory: documents.mediaBaseDirectory)
            session = s
            windowController.bind(session: s)
            windowController.applyLayout(show.layout)   // 节目里记的界面布局（调音台 / 多画面窗口 / 主窗口位置，W5-A / X47）
            panels.bind(session: s)
            try await s.start()
            refreshEngineActivity()   // 引擎起来了：拿上两条"别睡"（W5-L）
            if firstStartReport == nil { firstStartReport = s.startReport }
            switch baseline {
            case .current: documentBaseline = Self.documentContent(s.makeShow())
            case .empty: documentBaseline = Self.documentContent(Show(name: "", state: documents.emptyShow().makeState()))
            case .keep: break
            }
            documentToken = s.observeState { [weak self] _ in self?.refreshDocumentEdited() }
            if let hotkeyTableError { windowController.bottomBar.showNotice(hotkeyTableError) }
        } catch {
            lastError = error
            session = nil
            windowController.bind(session: nil)
            panels.bind(session: nil)
            refreshDocumentEdited()
            refreshEngineActivity()
            presentError(error, context: L("error.startEngine"))
        }
    }

    private func stopSession() async {
        guard let old = session else { return }
        documentToken = nil
        windowController.bind(session: nil)
        panels.bind(session: nil)
        session = nil
        refreshDocumentEdited()
        await old.stop()
        refreshEngineActivity()   // 引擎停了：两条"别睡"都放掉（W5-L）
    }

    // MARK: 未保存判定（W5-B）

    /// 未保存判定的口径：比"节目内容"——Show 去掉现场操作与界面摆放之后剩下的部分（报告 §1 有这张表）。
    /// 不算改动：界面布局（窗口位置 / 面板开关；W5-H 起 layout 里的输入分类两个键除外——它们是节目内容，023 后进 InputConfig）、节目名（跟文件名走）、录制 / 推流的开关（运行目标，打开文件时本来就清掉）、PGM / PVW 选哪路、
    /// 转场进度 / T-bar / 起始拍、FTB 开没开与进度、叠加通道开没开 / 放哪路 / 动画进度、文件输入的暂停与定位请求（提案 021 的 paused / seek*，W5-N：
    /// 播放 / 暂停 / 回到开头是现场操作；"切上 PGM 时从头播"是设置，算改动）。
    /// 算改动：输入表与每路设置（含推子、静音、路由、延迟、效果、抠像）、输出表与设置（含 NDI / 外部显示 / 虚拟摄像头 / 多画面的开关）、
    /// 转场类型 / 时长 / Wipe / Stinger 参数、FTB 时长、叠加的位置 / 动画 / 边框 / 锚点 / PVW 预览、四总线的增益 / 静音 / 效果、AFV、监听、节目格式、对齐延迟 / 监听点。
    static func documentContent(_ show: Show) -> Show {
        var s = ShowDocuments.stoppingOutputs(show)
        s.name = ""
        s.layout = ShowLayout(values: show.layout.values.filter { InputCategories.Keys.all.contains($0.key) })
        s.mixer.program = MixerState.noInput
        s.mixer.preview = MixerState.noInput
        s.mixer.transition.progress = 0
        s.mixer.transition.source = .auto
        s.mixer.transition.startTick = nil
        s.mixer.ftb.on = false
        s.mixer.ftb.level = 0
        s.mixer.ftb.startTick = nil
        for i in s.mixer.overlays.indices {
            s.mixer.overlays[i].on = false
            s.mixer.overlays[i].input = nil
            s.mixer.overlays[i].animProgress = 0
            s.mixer.overlays[i].startTick = nil
        }
        for i in s.inputs.indices {
            s.inputs[i].settings.playback.paused = false
            s.inputs[i].settings.playback.seekSeconds = nil
            s.inputs[i].settings.playback.seekTick = nil
        }
        return s
    }

    private func refreshDocumentEdited() {
        guard let session, let documentBaseline else {
            isDocumentEdited = false
            return
        }
        isDocumentEdited = Self.documentContent(session.makeShow()) != documentBaseline
    }

    // MARK: 换节目 / 换引擎 / 退出前的问（W5-B）

    /// 正在跑的录制 / 推流路数（目标开着的；起不来的也算——换节目 / 换引擎照样会把它们清掉）。
    var liveOutputCounts: (records: Int, streams: Int) {
        let outputs = session?.state.outputs.filter(\.enabled) ?? []
        return (outputs.filter { $0.kind == .record }.count, outputs.filter { $0.kind == .stream }.count)
    }

    /// "1 路录制、2 路推流"（只列不为零的）。
    static func liveSummary(records: Int, streams: Int) -> String {
        var parts: [String] = []
        if records > 0 { parts.append(L("confirm.part.records", records)) }
        if streams > 0 { parts.append(L("confirm.part.streams", streams)) }
        return parts.joined(separator: L("confirm.part.separator"))
    }

    enum LeaveReason: Equatable {
        case newShow
        /// 打开的文件名。
        case openShow(String)
        case quit
    }

    /// 换节目 / 退出之前：录制 / 推流在跑 → 先问"会停止 n 路录制、m 路推流"；节目有未保存的改动 → 问 保存 / 不保存 / 取消。
    /// 都过了才 proceed；任何一步取消就什么都不做（cancelled）。
    func confirmLeavingShow(_ reason: LeaveReason, proceed: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void = {}) {
        let live = liveOutputCounts
        guard live.records + live.streams > 0 else {
            confirmSavingChanges(reason, proceed: proceed, cancelled: cancelled)
            return
        }
        let summary = Self.liveSummary(records: live.records, streams: live.streams)
        let title: String, button: String, message: String
        switch reason {
        case .newShow: (title, button, message) = (L("confirm.newShow.title", summary), L("confirm.newShow.button"), L("confirm.replace.message"))
        case .openShow(let name): (title, button, message) = (L("confirm.openShow.title", name, summary), L("confirm.openShow.button"), L("confirm.replace.message"))
        case .quit: (title, button, message) = (L("confirm.quit.title", summary), L("confirm.quit.button"), L("confirm.quitLive.message"))
        }
        let request = ConfirmationCenter.Request(kind: .replaceShow, title: title, message: message,
                                                 buttons: [.init(title: button, choice: .confirm, destructive: true), .init(title: L("common.cancel"), choice: .cancel)],
                                                 defaultChoice: nil)
        ConfirmationCenter.shared.ask(request, in: windowController.window) { [weak self] choice in
            guard choice == .confirm, let self else { cancelled(); return }
            // 下一问等这一个 sheet 收起来再弹
            DispatchQueue.main.async { MainActor.assumeIsolated { self.confirmSavingChanges(reason, proceed: proceed, cancelled: cancelled) } }
        }
    }

    private func confirmSavingChanges(_ reason: LeaveReason, proceed: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void) {
        guard isDocumentEdited, let session else {
            proceed()
            return
        }
        let hasFile = documents.currentURL != nil
        let request = ConfirmationCenter.Request(
            kind: .saveChanges, title: L("confirm.save.title", session.name),
            message: reason == .quit ? L("confirm.save.messageQuit") : L("confirm.save.message"),
            buttons: [.init(title: hasFile ? L("confirm.save.save") : L("confirm.save.saveAs"), choice: .confirm),
                      .init(title: L("common.cancel"), choice: .cancel),
                      .init(title: L("confirm.save.dontSave"), choice: .alternate)],
            defaultChoice: .confirm)
        ConfirmationCenter.shared.ask(request, in: windowController.window) { [weak self] choice in
            switch choice {
            case .alternate: proceed()
            case .cancel: cancelled()
            case .confirm:
                guard let self else { cancelled(); return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.saveBeforeLeaving { saved in saved ? proceed() : cancelled() } } }
            }
        }
    }

    /// 离开前那一问点了"保存"：有文件就写回，没有就弹存储面板；存成了 completion(true)，取消 / 写不进去 completion(false)（什么都不做）。
    private func saveBeforeLeaving(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let session else {
            completion(false)
            return
        }
        if let url = documents.currentURL {
            completion(write(session.makeShow(), to: url))
        } else {
            saveAs(completion: completion)
        }
    }

    /// 节目 › 新建（菜单 / ⌘N）：先过换节目的问。
    func requestNewShow(completion: (@MainActor () -> Void)? = nil) {
        confirmLeavingShow(.newShow, proceed: { [weak self] in
            Task { @MainActor in
                await self?.newShow()
                completion?()
            }
        })
    }

    /// 打开一个节目文件（打开… 选完 / 打开最近 / Finder 双击）：先过换节目的问。
    func requestOpenShow(url: URL, completion: (@MainActor () -> Void)? = nil) {
        confirmLeavingShow(.openShow(url.lastPathComponent), proceed: { [weak self] in
            Task { @MainActor in
                await self?.openShow(url: url)
                completion?()
            }
        })
    }

    /// 节目 › 打开上次退出时的节目（工具条"打开▾"同一项，W5-G / A2）：打开退出时自动存的那份（LastSession），先过换节目的问。
    /// 和启动时从 LastSession 恢复同一口径：它不是一个文件（保存时要另存），有内容就算未保存。没有这份就什么都不做（菜单项那时是灰的）。
    func requestOpenLastSession(completion: (@MainActor () -> Void)? = nil) {
        guard documents.hasAutosave else { return }
        confirmLeavingShow(.openShow(L("menu.show.lastSessionName")), proceed: { [weak self] in
            Task { @MainActor in
                guard let self, let show = self.documents.loadAutosave() else { return }
                self.documents.startNew()
                await self.replaceSession(show: show, baseline: .empty)
                completion?()
            }
        })
    }

    /// 退出之前（菜单退出 / ⌘Q / 关主窗口）：录制 / 推流在跑先确认，有未保存的改动问保存。completion(true) = 可以退了（AppDelegate 接着 shutdown）。
    func prepareToQuit(_ completion: @escaping @MainActor (Bool) -> Void) {
        confirmLeavingShow(.quit, proceed: { completion(true) }, cancelled: { completion(false) })
    }

    enum EngineRestartReason { case format, showAudio, restart }

    /// 偏好设置里会换引擎的三个按钮（节目格式"应用"、节目音频"应用"、"应用并重起引擎"）：录制 / 推流在跑时先确认（F5 / X04），没在跑直接做。
    /// sheet 挂在偏好设置窗上（window），没有就挂主窗口。
    func confirmEngineRestart(_ reason: EngineRestartReason, in window: NSWindow?, proceed: @escaping @MainActor () -> Void) {
        let live = liveOutputCounts
        guard live.records + live.streams > 0 else {
            proceed()
            return
        }
        let summary = Self.liveSummary(records: live.records, streams: live.streams)
        let title = switch reason {
        case .format: L("confirm.applyFormat.title", summary)
        case .showAudio: L("confirm.applyShowAudio.title", summary)
        case .restart: L("confirm.restartEngine.title", summary)
        }
        let request = ConfirmationCenter.Request(kind: .restartEngine, title: title, message: L("confirm.restartEngine.message"),
                                                 buttons: [.init(title: L("confirm.restartEngine.button"), choice: .confirm, destructive: true),
                                                           .init(title: L("common.cancel"), choice: .cancel)],
                                                 defaultChoice: nil)
        ConfirmationCenter.shared.ask(request, in: window ?? windowController.window) { choice in
            if choice == .confirm { proceed() }
        }
    }

    /// 改节目格式（偏好设置）：引擎的格式在 init 定死，所以换一个 session；输入 / 输出原样带过去，录制 / 推流的目标状态清掉（不自动续录）。
    func changeProgramFormat(_ format: ProgramFormat) async {
        guard let session else { return }
        var show = ShowDocuments.stoppingOutputs(session.makeShow())
        show.mixer.format = format
        show.layout = currentLayout()
        await replaceSession(show: show, baseline: .keep)
    }

    /// 改节目音频的对齐延迟 / 监听点（提案 007，存在 Show.audio 里）：运行期改要重建延迟线，AudioRuntime 建引擎时才读，所以换一个 session
    /// （同 changeProgramFormat：输入 / 输出原样带过去，录制 / 推流的目标状态清掉）。
    func changeShowAudio(alignmentFrames: Int, monitorPoint: MonitorPoint) async {
        guard let session else { return }
        var show = ShowDocuments.stoppingOutputs(session.makeShow())
        show.audio.alignmentFrames = max(0, alignmentFrames)
        show.audio.monitorPoint = monitorPoint
        show.layout = currentLayout()
        await replaceSession(show: show, baseline: .keep)
    }

    /// 用当前节目重起引擎（偏好设置里 API / 音频设备 / 兼容层改了要立刻生效）。
    func restartSession() async {
        guard let session else { return }
        var show = ShowDocuments.stoppingOutputs(session.makeShow())
        show.layout = currentLayout()
        await replaceSession(show: show, baseline: .keep)
    }

    /// 设置窗"应用并重起引擎"（W5-J，F4）：节目格式、节目音频按给的，本机的项读 settings，一次换一个 session（输入 / 输出原样带过去，录制 / 推流的目标状态清掉）。
    func restartSession(format: ProgramFormat, alignmentFrames: Int, monitorPoint: MonitorPoint) async {
        guard let session else { return }
        var show = ShowDocuments.stoppingOutputs(session.makeShow())
        show.mixer.format = format
        show.audio.alignmentFrames = max(0, alignmentFrames)
        show.audio.monitorPoint = monitorPoint
        show.layout = currentLayout()
        await replaceSession(show: show, baseline: .keep)
    }

    /// 即时生效的几节（性能与电源 / Tally / 提醒，W5-L）：改内存里的设置、只写这一节自己的键（save），马上落到跑着的 session（settings 的 didSet）。
    /// 不像"应用"那样整份写回：那会把启动参数带进来的值（--api-token、--no-api……）顺手存成本机设置。
    func updateSettings(_ change: (inout AppSettings) -> Void, saving save: (AppSettings, UserDefaults) -> Void) {
        var s = settings
        change(&s)
        save(s, defaults)
        settings = s
    }

    /// 设置：写 UserDefaults（同一组键）并记下，下次起 session 生效；运行时能改的同时落到跑着的 session：外部输出的主屏层级、
    /// 录制磁盘下限（下一次开录起用，在录的路照旧）与备用目录（W5-J 高级页）。
    func updateSettings(_ s: AppSettings) {
        s.save(to: defaults)
        settings = s
        session?.aux.external.mainScreenLayering = settings.externalMainScreenLayering
        session?.outputs.minimumFreeBytes = UInt64(max(0, settings.recordMinimumFreeMB)) * 1024 * 1024
        session?.outputs.fallbackDirectory = settings.recordFallbackDirectory
    }

    /// 快捷键编辑器保存后：换给派发器，下次起 session 也用它。
    func applyHotkeyTable(_ table: HotkeyTable) throws {
        hotkeyTable = table
        hotkeyTableError = nil
        session?.control.hotkeys.table = table
        windowController.transitionPanel.hotkeyTable = table   // 转场列的按钮提示从当前表反查（W5-A）
    }

    /// MIDI 映射面板保存后：换给控制器。
    func applyMIDITable(_ table: MIDIMapTable) throws {
        midiTable = table
        session?.control.midi.table = table
    }

    // MARK: 节目文件

    func newShow() async {
        documents.startNew()
        await replaceSession(show: documents.emptyShow())
    }

    func openShow(url: URL) async {
        do {
            let show = try documents.load(from: url)
            await replaceSession(show: show)
        } catch {
            presentError(error, context: L("error.open", url.lastPathComponent))
        }
    }

    /// 节目 › 打开…：先选文件，选完再过换节目的问（W5-B），没选就什么都不问。
    func openShowPanel(completion: (@MainActor () -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = L("show.openPanelMessage", ShowDocuments.fileExtension)
        guard let window = windowController.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                // 打开面板的 sheet 收起来之后再弹确认
                DispatchQueue.main.async { MainActor.assumeIsolated { self.requestOpenShow(url: url, completion: completion) } }
            }
        }
    }

    /// 保存：有文件就写回，没有就另存。
    func save() {
        guard let session else { return }
        if let url = documents.currentURL {
            write(session.makeShow(), to: url)
        } else {
            saveAs()
        }
    }

    /// 另存：弹存储面板；completion(true) = 存成了（离开前那一问点"保存…"时用），取消 / 写不进去 = false。
    func saveAs(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let session, let window = windowController.window else {
            completion?(false)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(session.name).\(ShowDocuments.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else {
                    completion?(false)
                    return
                }
                let saved = self.write(session.makeShow(), to: url)
                completion?(saved)
            }
        }
    }

    /// 直接写到 url（保存 / 另存 / 测试的落点）。节目名 = 文件名（去掉 .switcher.json）。写成了返回 true：窗口标题换成新名字（产品名，W5-B 修 X42），
    /// 未保存判定的基准换成刚存的内容。
    @discardableResult
    func write(_ show: Show, to url: URL) -> Bool {
        do {
            var s = show
            s.name = Self.showName(for: url)
            s.layout = currentLayout()
            try documents.save(s, to: url)
            session?.name = s.name
            session?.layout = s.layout
            session?.mediaBaseDirectory = documents.mediaBaseDirectory   // 另存到别处后，之后加的素材按新位置找（已在跑的路不重建）
            windowController.window?.title = MainWindowController.windowTitle(showName: s.name)
            documentBaseline = Self.documentContent(s)
            refreshDocumentEdited()
            return true
        } catch {
            presentError(error, context: L("error.save", url.lastPathComponent))
            return false
        }
    }

    /// 文件名 → 节目名："a.switcher.json" → "a"。
    static func showName(for url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".\(ShowDocuments.fileExtension)") { name.removeLast(ShowDocuments.fileExtension.count + 1) }
        else { name = url.deletingPathExtension().lastPathComponent }
        return name.isEmpty ? L("show.untitled") : name
    }

    /// 界面布局进 Show.layout（契约不解释内容，App 自己定义键）。
    func currentLayout() -> ShowLayout {
        var values = session?.layout.values ?? [:]
        if let frame = windowController.window?.frame {
            values["mainWindowFrame"] = .string(NSStringFromRect(frame))
        }
        values["mixerPanelVisible"] = .bool(windowController.isMixerPanelVisible)
        windowController.multiviewWindow?.save(into: &values)
        values["multiviewWindowVisible"] = .bool(windowController.isMultiviewWindowVisible)
        return ShowLayout(values: values)
    }

    private func presentError(_ error: any Error, context: String) {
        NSLog("\(context)失败：\(error)")
        guard !isTestHost, let window = windowController.window else { return }
        let alert = NSAlert()
        alert.messageText = L("error.failed", context)
        alert.informativeText = "\(error)"
        alert.beginSheetModal(for: window)
    }
}
