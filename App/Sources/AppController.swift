// App 的总管：一个 session（节目跑起来）+ 主窗口 + 节目文件 + 面板（W3-E）。新建 / 打开总是换一个新 session（节目格式可能变，引擎的格式在 init 定死）。
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
        didSet { if isTestHost { applyTestHostOverrides() } }
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
    /// 自动更新（W4-B，Sparkle）：Info.plist 里没有更新源 / 公钥（开发、ad-hoc、测试宿主）就不起。
    let updateController: UpdateController
    private var replacing = false

    /// 测试宿主的 UserDefaults suite。
    static let testDefaultsSuite = "com.plusmix.switcher.tests"

    init(isTestHost: Bool) {
        self.isTestHost = isTestHost
        // CoreMIDI 的热插拔通知：W2-C2 起由 SwitcherControl 的进程级 MIDIHost（常驻线程 + 永不销毁的锚客户端）接住，换节目后新插的设备照常连上；
        // App 自己在主线程建的锚客户端（W3-E2 加的绕法）删了（W3-E5），守门用例 testMIDI_hotplugAfterShowReplaced_newSourceConnects
        defaults = isTestHost ? UserDefaults(suiteName: Self.testDefaultsSuite) ?? .standard : .standard
        updateController = UpdateController(defaults: defaults, isTestHost: isTestHost)
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
            let recordDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/records", isDirectory: true).path
            documents = ShowDocuments(defaults: defaults, recordDirectory: recordDirectory)
            applyTestHostOverrides()
        } else {
            documents = ShowDocuments(defaults: defaults)
        }
        windowController.defaultRecordDirectory = documents.recordDirectory
        windowController.panels = panels
    }

    private func applyTestHostOverrides() {
        var s = settings
        s.apiPort = 0
        s.audioDevice = ProcessInfo.processInfo.environment["SWITCHER_TEST_AUDIO"].map { AppSettings.AudioDevice(spec: $0) } ?? .null
        if s != settings { settings = s }
    }

    // MARK: 启动 / 退出

    /// 启动：命令行指定的文件 → 恢复上次的文件 → 没有就恢复退出时自动存的 → 再没有就空节目。测试宿主永远空节目。
    func launch(showURL: URL? = nil) async {
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.window?.makeFirstResponder(nil)   // 快捷键直接到窗口；搜索框要点了才有焦点
        var show = documents.emptyShow()
        if let showURL {
            do { show = try documents.load(from: showURL) } catch { presentError(error, context: L("error.open", showURL.lastPathComponent)) }
        } else if !isTestHost {
            if let url = documents.lastURL, let loaded = try? documents.load(from: url) {
                show = loaded
            } else if let auto = documents.loadAutosave() {
                show = auto
                documents.startNew()
            }
        }
        await replaceSession(show: show)
    }

    /// 退出前：自动保存当前状态（未保存过的节目下次能恢复），停引擎。
    func shutdown() async {
        if let session, !isTestHost {
            documents.autosave(session.makeShow())
            if let url = documents.currentURL { try? documents.save(session.makeShow(), to: url) }
        }
        await stopSession()
    }

    // MARK: session

    func replaceSession(show: Show) async {
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
            panels.bind(session: s)
            try await s.start()
            if firstStartReport == nil { firstStartReport = s.startReport }
            if let hotkeyTableError { windowController.bottomBar.showNotice(hotkeyTableError) }
        } catch {
            lastError = error
            session = nil
            windowController.bind(session: nil)
            panels.bind(session: nil)
            presentError(error, context: L("error.startEngine"))
        }
    }

    private func stopSession() async {
        guard let old = session else { return }
        windowController.bind(session: nil)
        panels.bind(session: nil)
        session = nil
        await old.stop()
    }

    /// 改节目格式（偏好设置）：引擎的格式在 init 定死，所以换一个 session；输入 / 输出原样带过去，录制 / 推流的目标状态清掉（不自动续录）。
    func changeProgramFormat(_ format: ProgramFormat) async {
        guard let session else { return }
        var show = ShowDocuments.stoppingOutputs(session.makeShow())
        show.mixer.format = format
        show.layout = currentLayout()
        await replaceSession(show: show)
    }

    /// 改节目音频的对齐延迟 / 监听点（提案 007，存在 Show.audio 里）：运行期改要重建延迟线，AudioRuntime 建引擎时才读，所以换一个 session
    /// （同 changeProgramFormat：输入 / 输出原样带过去，录制 / 推流的目标状态清掉）。
    func changeShowAudio(alignmentFrames: Int, monitorPoint: MonitorPoint) async {
        guard let session else { return }
        var show = ShowDocuments.stoppingOutputs(session.makeShow())
        show.audio.alignmentFrames = max(0, alignmentFrames)
        show.audio.monitorPoint = monitorPoint
        show.layout = currentLayout()
        await replaceSession(show: show)
    }

    /// 用当前节目重起引擎（偏好设置里 API / 音频设备 / 兼容层改了要立刻生效）。
    func restartSession() async {
        guard let session else { return }
        var show = ShowDocuments.stoppingOutputs(session.makeShow())
        show.layout = currentLayout()
        await replaceSession(show: show)
    }

    /// 偏好设置：写 UserDefaults（同一组键）并记下，下次起 session 生效；运行时能改的包内选项（外部输出的主屏层级）同时落到跑着的 session。
    func updateSettings(_ s: AppSettings) {
        s.save(to: defaults)
        settings = s
        session?.aux.external.mainScreenLayering = settings.externalMainScreenLayering
    }

    /// 快捷键编辑器保存后：换给派发器，下次起 session 也用它。
    func applyHotkeyTable(_ table: HotkeyTable) throws {
        hotkeyTable = table
        hotkeyTableError = nil
        session?.control.hotkeys.table = table
    }

    /// MIDI 映射面板保存后：换给控制器。
    func applyMIDITable(_ table: MIDIMapTable) throws {
        midiTable = table
        session?.control.midi.table = table
    }

    // MARK: 换节目 / 退出前确认（W5-B 桩）

    var isDocumentEdited: Bool { false }
    func requestNewShow(completion: (() -> Void)? = nil) { Task { await newShow(); completion?() } }
    func requestOpenShow(url: URL, completion: (() -> Void)? = nil) { Task { await openShow(url: url); completion?() } }
    func prepareToQuit(_ completion: @escaping @MainActor (Bool) -> Void) { completion(true) }

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

    func openShowPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = L("show.openPanelMessage", ShowDocuments.fileExtension)
        guard let window = windowController.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                Task { await self.openShow(url: url) }
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

    func saveAs() {
        guard let session, let window = windowController.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(session.name).\(ShowDocuments.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.write(session.makeShow(), to: url)
            }
        }
    }

    /// 直接写到 url（测试 / 另存的落点）。节目名 = 文件名（去掉 .switcher.json）。
    func write(_ show: Show, to url: URL) {
        do {
            var s = show
            s.name = Self.showName(for: url)
            s.layout = currentLayout()
            try documents.save(s, to: url)
            session?.name = s.name
            session?.layout = s.layout
            session?.mediaBaseDirectory = documents.mediaBaseDirectory   // 另存到别处后，之后加的素材按新位置找（已在跑的路不重建）
            windowController.window?.title = "Switcher \(SwitcherVersion.current) — \(s.name)"
        } catch {
            presentError(error, context: L("error.save", url.lastPathComponent))
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
