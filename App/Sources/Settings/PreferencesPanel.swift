// 设置窗里除输出各页、快捷键、MIDI 以外的页（W3-E 的偏好设置一张长表单，W5-J 起拆成页，01a F1 / F4 / F5 / F7，04 Q04 (a) / Q64）：
// 本节目 = 节目格式、节目音频（存在节目文件里，改了要换引擎）；本机 = 常规（操作确认、语言、外部显示层级、PVW 预览全部叠加）、音频设备、
// 远程控制（本地 API / 第三方 API 兼容层的开关与令牌）、Tally、性能与电源、更新与诊断、高级（录制磁盘下限、备用录制目录、两个监听地址）。
// 提交方式统一即时生效（F4）：本机的项改了就写 UserDefaults（AppSettings 同一组键）、换给 AppController，运行时能改的（外部显示层级、
// 磁盘下限、备用目录）同时落到跑着的 session；要换引擎才用得上的（节目格式、节目音频、音频设备、API / 兼容层、PVW 预览全部叠加）
// 记成"待应用"（pendingRestart = 想要的 ≠ 跑着的 session 用的），集中到页底"应用并重起引擎"，录制 / 推流在跑先确认（87 的 confirmEngineRestart）。
// 换完引擎窗不关，格式 / 节目音频按新 session 重读（rebind）。旧的 apply / applyProgramFormat / applyShowAudio / applyAndRestart 还在（用例与内部调用）。
// API 的监听地址"仅本机 / 允许局域网"是 98 的远程控制页；这里的"高级"页先能填 host:port。
// W5-K（97）："音频设备"页 = AudioOutputSettingsSection（设备 + 每条总线选声道对，AudioOutputSettingsModel），G7 合并时从偏好设置长表单搬进本机 › 音频设备；
// 模型改了（选设备 / 声道 / 借 Master）按即时生效提交（bindAudioOutput）。
// W5-L（98）：远程控制页 = RemoteControlSection（API / 兼容层"仅本机 / 允许局域网" + 可访问地址）、Tally / 性能与电源 / 提醒三节各自即时生效、只写自己的键（AppController.updateSettings(_:saving:)），G7 合并时挂进 96 的对应页。
// W5-O（112）：常规 / 音频设备 / 远程控制 / 高级 页的提交也只写这次真变了的键（AppController.commitSettings → AppSettings.save(to:changedFrom:)）——
// 原来整份写回，带 --no-api 之类启动参数起、改一项设置，就把启动参数存成了本机设置（问题单 W4C2-w5-app-settings-gaps 第 2 条）。
import AppKit
import Combine   // bindAudioOutput：订阅 W5-K 音频设备模型的改动（G7 合并时加）
import SwiftUI
import SwitcherContracts
import SwitcherControl
import SwitcherAudio
import VMixCompat

@MainActor
final class PreferencesModel: ObservableObject {
    struct LanguageChoice: Identifiable, Hashable {
        let id: String
        let title: String
    }

    /// 要重起引擎才生效、现在还没生效的项（页底"有 n 项待应用"）。
    enum PendingRestart: String, CaseIterable, Identifiable, Sendable {
        case format, showAudio, audioDevice, api, compat, overlaysInPreview
        var id: String { rawValue }
        var title: String { L("settings.pending.\(rawValue)") }
    }

    static let systemLanguage = "system"
    static let formatPresets: [ProgramFormat] = [.hd1080p60, .hd1080p5994, .hd1080p30, .hd720p60, .uhd2160p30]
    static let frameRates: [FrameRate] = [.fps24, .fps25, .fps2997, .fps30, .fps50, .fps5994, .fps60]
    /// 分辨率预设（W5-J 加 2560×1440；不在这里的是"自定义"，F5）。
    static let resolutions: [(Int, Int)] = [(1920, 1080), (1280, 720), (2560, 1440), (3840, 2160)]
    /// 自定义分辨率的范围（偶数，编码器要求）。
    static let customWidthRange = 320...7680
    static let customHeightRange = 240...4320
    /// 分辨率的写法"1920×1080"（Text 里直接插数字会按本地数字格式加千分位，成了"1,920×1,080"，V-12）。
    static func resolutionTitle(width: Int, height: Int) -> String { "\(width)×\(height)" }
    /// 端口这类整数输入框的格式：不加千分位（"8098"，不是"8,098"，V-12）。
    static let plainInteger = IntegerFormatStyle<Int>.number.grouping(.never)
    /// 高级页磁盘下限框的格式：同 plainInteger，解析时钳进 0…AppSettings.maxRecordMinimumFreeMB（N04）。
    static let minimumFreeFormat = ClampedIntegerFormat(range: 0...AppSettings.maxRecordMinimumFreeMB)

    // MARK: 本节目（改了要换引擎：待应用）

    @Published var formatWidth: Int { didSet { refreshPending() } }
    @Published var formatHeight: Int { didSet { refreshPending() } }
    @Published var frameRate: FrameRate { didSet { refreshPending() } }
    /// 节目音频的对齐延迟（48 kHz 帧）与监听点（提案 007）：存在节目文件里，不是全局偏好；改了要重建音频引擎（换 session）。
    @Published var alignmentFrames: Int { didSet { refreshPending() } }
    @Published var monitorPoint: SwitcherContracts.MonitorPoint { didSet { refreshPending() } }

    // MARK: 本机（即时生效）

    @Published var apiEnabled: Bool { didSet { commit() } }
    @Published var apiHost: String { didSet { syncAPIListenText(); commit() } }
    @Published var apiPort: Int { didSet { syncAPIListenText(); commit() } }
    @Published var apiToken: String { didSet { commit() } }
    @Published var compatLayerEnabled: Bool { didSet { commit() } }
    @Published var compatLayerPort: Int { didSet { syncCompatListenText(); commit() } }
    /// 兼容层的监听地址（HTTP 与 TCP 共用，W5-J 起可填；默认只听本机）。
    @Published var compatLayerHost: String { didSet { syncCompatListenText(); commit() } }
    /// 兼容层的 HTTP 端口（W5-L 远程控制页；原来写死 8088）。
    @Published var compatLayerHTTPPort: Int { didSet { commit() } }
    /// 设置"性能与电源" / "Tally" / "提醒"三节（W5-L）：各自即时生效、只写自己的键，不经这里的 commit。
    let power: PowerSettingsModel
    let tally: TallySettingsModel
    let reminders: ReminderSettingsModel
    /// PVW 预览全部叠加（渲染器总开关，换 session 生效）。
    @Published var overlaysInPreview: Bool { didSet { commit() } }
    /// 外部输出在主屏上不盖住主界面（ExternalDisplayManager.mainScreenLayering，即时生效）。
    @Published var externalBehindInterface: Bool { didSet { commit() } }
    @Published var language: String { didSet { commitLanguage() } }
    /// 底栏停录制 / 停推流前先确认（W5-B，默认开）。
    @Published var confirmBeforeStop: Bool { didSet { commit() } }
    /// 录制目录剩余空间下限（MB）：低于就停那一路（或切到备用目录）。即时生效，跑着的引擎从下一次开录起用（在录的路照旧）。
    @Published var recordMinimumFreeMB: Int { didSet { commit() } }   // 钳到 0…AppSettings.maxRecordMinimumFreeMB 再存、页上换成钳后的值（commit；N04）；页上的框解析时也钳
    /// 磁盘满 / 低于下限时自动切过去继续录的目录；空 = 只停录制并提示。即时生效。
    @Published var recordFallbackDirectory: String { didSet { commit() } }
    /// 高级页的两个监听地址框（host:port）：写对了才存，写错了 listenError 说明、不存。
    @Published var apiListenText: String { didSet { applyAPIListenText() } }
    @Published var compatListenText: String { didSet { applyCompatListenText() } }
    @Published private(set) var listenError: String?

    /// 要重起引擎才生效、还没生效的项（按 PendingRestart 的顺序）。
    @Published private(set) var pendingRestart: [PendingRestart] = []
    @Published private(set) var status = ""
    let languageChoices: [LanguageChoice]
    /// 更新一节（W4-B，Sparkle）：是否配置了更新源、上次检查时间、自动检查开关（即时写回 Sparkle）。
    let updatesConfigured: Bool
    let updateStatus: String
    @Published var automaticUpdates: Bool {
        didSet { if !loading, updatesConfigured { controller.updateController.automaticallyChecksForUpdates = automaticUpdates } }
    }
    private unowned let controller: AppController
    /// 音频设备与每条总线的声道（W5-K，J8）；导入设置 / 恢复默认后按 AppController.settings 重建（reloadMachineSettings）。
    @Published private(set) var audioOutput: AudioOutputSettingsModel
    /// 确认 sheet 挂在哪个窗口上（设置窗设）。
    weak var presentingWindow: NSWindow?
    /// 读初值 / 重读时不提交。
    private var loading = true
    /// 监听地址框与 host / port 互相同步时不再回写。
    private var syncingListen = false
    /// 音频设备模型（W5-K）改了（选设备 / 声道 / 借 Master）就按即时生效提交；重建模型（reloadMachineSettings）时再绑一次。
    private var audioOutputToken: AnyCancellable?

    /// 兼容层的法律提示（设计方案 §0、§9.3：独立模块、默认关、发布前问律师）。
    static var compatLegalNotice: String { L("prefs.compat.legal") }

    init(controller: AppController) {
        self.controller = controller
        audioOutput = AudioOutputSettingsModel(device: controller.settings.audioDevice, map: controller.settings.busOutputMap,
                                               borrowMasterForMonitor: controller.settings.borrowMasterForMonitor)
        updatesConfigured = controller.updateController.isConfigured
        updateStatus = controller.updateController.statusText
        automaticUpdates = controller.updateController.automaticallyChecksForUpdates
        let s = controller.settings
        let format = controller.session?.format ?? .hd1080p60
        formatWidth = format.width
        formatHeight = format.height
        frameRate = format.frameRate
        apiEnabled = s.apiEnabled
        apiHost = s.apiHost
        apiPort = s.apiPort
        apiToken = s.apiToken ?? ""
        compatLayerEnabled = s.compatLayerEnabled
        compatLayerPort = s.compatLayerPort
        compatLayerHost = s.compatLayerHost
        compatLayerHTTPPort = s.compatLayerHTTPPort
        power = PowerSettingsModel(controller: controller)
        tally = TallySettingsModel(controller: controller)
        reminders = ReminderSettingsModel(controller: controller)
        overlaysInPreview = s.overlaysInPreview
        externalBehindInterface = s.externalBehindInterface
        confirmBeforeStop = s.confirmBeforeStop
        recordMinimumFreeMB = s.recordMinimumFreeMB
        recordFallbackDirectory = s.recordFallbackDirectory ?? ""
        apiListenText = "\(s.apiHost):\(s.apiPort)"
        compatListenText = "\(s.compatLayerHost):\(s.compatLayerPort)"
        let audio = controller.session?.state.audio ?? AudioState()
        alignmentFrames = audio.alignmentFrames
        monitorPoint = audio.monitorPoint
        let languages = controller.defaults.stringArray(forKey: "AppleLanguages")
        language = languages?.first.flatMap { code in L10n.supportedLanguages.contains(code) ? code : nil } ?? Self.systemLanguage
        languageChoices = [LanguageChoice(id: Self.systemLanguage, title: L("prefs.language.system"))] + L10n.supportedLanguages.map { LanguageChoice(id: $0, title: L("prefs.language.\($0)")) }
        loading = false
        bindAudioOutput()
        refreshPending()
    }

    /// 音频输出设备（W5-K 起由"音频设备"一节的模型管：设备 + 每条总线的声道）。
    var audioDevice: AppSettings.AudioDevice {
        get { audioOutput.device }
        set { audioOutput.selectDevice(newValue) }
    }
    var audioDeviceChoices: [AudioOutputSettingsModel.DeviceChoice] { audioOutput.devices }
    var audioDeviceID: String {
        get { audioOutput.selectedID }
        set { audioOutput.selectDevice(id: newValue) }
    }

    var programFormat: ProgramFormat { ProgramFormat(width: formatWidth, height: formatHeight, frameRate: frameRate) }

    /// 分辨率不在预设里（页上"自定义"选中、两个框可改）。
    var isCustomResolution: Bool { !Self.resolutions.contains { $0 == (formatWidth, formatHeight) } }

    // MARK: 远程控制（W5-L，P3 / X33）

    /// 本地 API：仅本机 / 允许局域网（写进 apiHost）。
    var apiScope: ListenScope {
        get { ListenScope(host: apiHost) }
        set { apiHost = newValue.host(replacing: apiHost) }
    }

    /// 兼容层：仅本机 / 允许局域网（写进 compatLayerHost）。
    var compatScope: ListenScope {
        get { ListenScope(host: compatLayerHost) }
        set { compatLayerHost = newValue.host(replacing: compatLayerHost) }
    }

    /// 别的机器（或本机）该连的 API 地址：http://<地址>:<端口>；允许局域网又找不到局域网地址时为空串。
    /// 端口 0（系统分配，测试宿主）显示跑着的那个实际端口。
    var apiAddress: String {
        guard let host = NetworkAddresses.reachableHosts(listenHost: apiHost).first else { return "" }
        return "http://\(host):\(displayedAPIPort)"
    }
    /// 其余局域网地址（多块网卡时）。
    var apiOtherAddresses: [String] {
        NetworkAddresses.reachableHosts(listenHost: apiHost).dropFirst().map { "http://\($0):\(displayedAPIPort)" }
    }
    private var displayedAPIPort: Int { apiPort == 0 ? (controller.session?.control.apiServer?.boundPort ?? 0) : apiPort }
    /// 允许局域网又没设 token 时的黄字提醒。
    var apiWarning: String? {
        apiEnabled && apiScope == .lan && apiToken.trimmingCharacters(in: .whitespaces).isEmpty ? L("prefs.remote.noTokenWarning") : nil
    }
    /// 兼容层的 HTTP 地址（…/api）与 TCP 地址（地址:端口）。
    var compatHTTPAddress: String {
        NetworkAddresses.reachableHosts(listenHost: compatLayerHost).first.map { "http://\($0):\(compatLayerHTTPPort)/api" } ?? ""
    }
    var compatTCPAddress: String {
        NetworkAddresses.reachableHosts(listenHost: compatLayerHost).first.map { "\($0):\(compatLayerPort)" } ?? ""
    }
    /// 兼容层允许局域网时的提醒（它没有鉴权）。
    var compatWarning: String? { compatLayerEnabled && compatScope == .lan ? L("prefs.remote.compatLANWarning") : nil }

    func selectFormatPreset(_ f: ProgramFormat) {
        formatWidth = f.width
        formatHeight = f.height
        frameRate = f.frameRate
    }

    /// 自定义宽 × 高（钳到范围、取偶数）。
    func setCustomResolution(width: Int, height: Int) {
        formatWidth = Self.even(min(max(width, Self.customWidthRange.lowerBound), Self.customWidthRange.upperBound))
        formatHeight = Self.even(min(max(height, Self.customHeightRange.lowerBound), Self.customHeightRange.upperBound))
    }

    private static func even(_ n: Int) -> Int { n - n % 2 }

    /// 检查更新（Sparkle 自己的窗口）。
    func checkForUpdates() { controller.updateController.checkForUpdates() }
    /// 导出诊断包（与帮助菜单同一个流程）。
    func exportDiagnostics() { DiagnosticsExport.present(controller: controller) }

    private func bindAudioOutput() {
        audioOutputToken = audioOutput.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.commit() }
    }

    // MARK: 提交（即时生效）

    /// 本机的项写回 UserDefaults + AppController（下次起 session 用；运行时能改的同时落到跑着的 session），再重算待应用的项。
    /// 只写这次真变了的键（AppController.commitSettings，W5-O）：每页只存自己改的那几项，启动参数带进来的值不跟着存。
    private func commit() {
        guard !loading else { return }
        var s = controller.settings
        s.apiEnabled = apiEnabled
        let host = apiHost.trimmingCharacters(in: .whitespaces)
        s.apiHost = host.isEmpty ? "127.0.0.1" : host
        s.apiPort = max(0, min(65535, apiPort))
        s.apiToken = apiToken.isEmpty ? nil : apiToken
        s.audioDevice = audioOutput.device
        s.busOutputMap = audioOutput.storedMap
        s.borrowMasterForMonitor = audioOutput.borrowMasterForMonitor
        controller.session?.audio.engine.borrowMasterForMonitor = s.borrowMasterForMonitor   // 跑着的引擎当场生效（X09，W1-D3 的 AudioEngine.borrowMasterForMonitor 任意线程可设）
        s.compatLayerEnabled = compatLayerEnabled
        s.compatLayerPort = max(1, min(65535, compatLayerPort))
        let compatHost = compatLayerHost.trimmingCharacters(in: .whitespaces)
        s.compatLayerHost = compatHost.isEmpty ? "127.0.0.1" : compatHost
        s.compatLayerHTTPPort = max(1, min(65535, compatLayerHTTPPort))
        s.overlaysInPreview = overlaysInPreview
        s.externalBehindInterface = externalBehindInterface
        s.confirmBeforeStop = confirmBeforeStop
        let minimumFreeMB = AppSettings.clampMinimumFreeMB(recordMinimumFreeMB)   // N04：2^44 MB 起换成字节就溢出；先钳再存（commitSettings 先落盘）
        s.recordMinimumFreeMB = minimumFreeMB
        let fallback = recordFallbackDirectory.trimmingCharacters(in: .whitespaces)
        s.recordFallbackDirectory = fallback.isEmpty ? nil : fallback
        controller.commitSettings(s)   // 只写这次真变了的键：内存里带着启动参数（--no-api……），不顺手存成本机设置（W5-O）
        if recordMinimumFreeMB != minimumFreeMB {
            // 页上也换成钳后的值（存下的、跑着的引擎用的是它）；loading 挡住这次回写再提交一遍
            loading = true
            recordMinimumFreeMB = minimumFreeMB
            loading = false
        }
        status = L("prefs.status.saved")
        refreshPending()
    }

    private func commitLanguage() {
        guard !loading else { return }
        if language == Self.systemLanguage {
            controller.defaults.removeObject(forKey: "AppleLanguages")
        } else {
            controller.defaults.set([language], forKey: "AppleLanguages")
        }
    }

    /// 旧入口（W3-E 的"应用"按钮）：现在每项改了就已经存了，这里再整体写一遍（用例与内部调用）。
    func apply() {
        if updatesConfigured { controller.updateController.automaticallyChecksForUpdates = automaticUpdates }
        commit()
        commitLanguage()
        status = L("prefs.status.saved")
    }

    // MARK: 监听地址（高级页）

    private func syncAPIListenText() {
        guard !syncingListen else { return }
        syncingListen = true
        apiListenText = "\(apiHost):\(apiPort)"
        syncingListen = false
    }

    private func syncCompatListenText() {
        guard !syncingListen else { return }
        syncingListen = true
        compatListenText = "\(compatLayerHost):\(compatLayerPort)"
        syncingListen = false
    }

    private func applyAPIListenText() {
        guard !loading, !syncingListen else { return }
        guard let parsed = APIServerConfiguration.parseListen(apiListenText), !parsed.host.isEmpty else {
            listenError = L("settings.advanced.listenInvalid", apiListenText)
            return
        }
        listenError = nil
        syncingListen = true
        apiHost = parsed.host
        apiPort = parsed.port
        syncingListen = false
        commit()
    }

    private func applyCompatListenText() {
        guard !loading, !syncingListen else { return }
        guard let parsed = VMixCompatConfiguration.parseListen(compatListenText, defaultPort: AppSettings.defaultCompatLayerPort),
              !parsed.host.isEmpty, (1...65535).contains(parsed.port) else {
            listenError = L("settings.advanced.listenInvalid", compatListenText)
            return
        }
        listenError = nil
        syncingListen = true
        compatLayerHost = parsed.host
        compatLayerPort = parsed.port
        syncingListen = false
        commit()
    }

    // MARK: 待应用的项

    /// 想要的 ≠ 跑着的 session 用的 → 待应用。没有 session 时为空。
    func refreshPending() {
        guard !loading else { return }
        guard let session = controller.session else {
            if !pendingRestart.isEmpty { pendingRestart = [] }
            return
        }
        let running = session.settings
        var items: [PendingRestart] = []
        if programFormat != session.format { items.append(.format) }
        if alignmentFrames != session.state.audio.alignmentFrames || monitorPoint != session.state.audio.monitorPoint { items.append(.showAudio) }
        // 每条总线的声道对也是建音频引擎时用的（AudioRuntime）：只改声道对同样待应用（W5-O；原来只比设备，改完要等下次起引擎才生效）。
        // 借 Master 声道不算：G8b 起当场落到跑着的引擎（commit 里设 AudioEngine.borrowMasterForMonitor）
        if audioDevice != running.audioDevice || audioOutput.storedMap != running.busOutputMap { items.append(.audioDevice) }
        let host = apiHost.trimmingCharacters(in: .whitespaces)
        if apiEnabled != running.apiEnabled || (host.isEmpty ? "127.0.0.1" : host) != running.apiHost || apiPort != running.apiPort
            || (apiToken.isEmpty ? nil : apiToken) != running.apiToken {
            items.append(.api)
        }
        let compatHost = compatLayerHost.trimmingCharacters(in: .whitespaces)
        if compatLayerEnabled != running.compatLayerEnabled
            || (compatLayerEnabled && (compatLayerPort != running.compatLayerPort || compatLayerHTTPPort != running.compatLayerHTTPPort || (compatHost.isEmpty ? "127.0.0.1" : compatHost) != running.compatLayerHost)) {
            items.append(.compat)
        }
        if overlaysInPreview != running.overlaysInPreview { items.append(.overlaysInPreview) }
        if items != pendingRestart { pendingRestart = items }
    }

    /// "应用并重起引擎"：把待应用的项一次用上（换一个 session：格式、节目音频按页上的，本机的读 AppController.settings）。
    /// 录制 / 推流在跑先确认（取消 = 什么都不做）。没有待应用的项返回 false。
    @discardableResult
    func applyPendingAndRestart() -> Bool {
        guard controller.session != nil, !pendingRestart.isEmpty else { return false }
        let format = programFormat
        let frames = min(max(alignmentFrames, Self.alignmentRange.lowerBound), Self.alignmentRange.upperBound)
        let point = monitorPoint
        let reason: AppController.EngineRestartReason = pendingRestart.contains(.format) ? .format : (pendingRestart == [.showAudio] ? .showAudio : .restart)
        controller.confirmEngineRestart(reason, in: presentingWindow) { [weak self, controller = self.controller] in
            self?.commit()
            self?.status = L("prefs.status.restarting")
            Task { await controller.restartSession(format: format, alignmentFrames: frames, monitorPoint: point) }
        }
        return true
    }

    /// 节目格式变了就换 session（输入 / 输出原样带过去）；录制 / 推流在跑先确认（取消 = 不换）。没变返回 false。
    @discardableResult
    func applyProgramFormat() -> Bool {
        guard let session = controller.session, session.format != programFormat else { return false }
        let format = programFormat
        controller.confirmEngineRestart(.format, in: presentingWindow) { [weak self, controller = self.controller] in
            self?.status = L("prefs.status.restarting")
            Task { await controller.changeProgramFormat(format) }
        }
        return true
    }

    /// 换了 session（换格式 / 节目音频 / 重起、新建 / 打开）：窗口不关，格式与节目音频几项按新 session 重新读一遍（W5-B，X04）。没有 session 时不动。
    func rebind() {
        guard let session = controller.session else { return }
        let restarting = status == L("prefs.status.restarting")
        loading = true
        formatWidth = session.format.width
        formatHeight = session.format.height
        frameRate = session.format.frameRate
        alignmentFrames = session.state.audio.alignmentFrames
        monitorPoint = session.state.audio.monitorPoint
        loading = false
        if restarting { status = L("prefs.status.restarted") }
        refreshPending()
    }

    /// 本机的项按 AppController.settings 重读（导入设置 / 恢复默认之后）。
    func reloadMachineSettings() {
        let s = controller.settings
        loading = true
        apiEnabled = s.apiEnabled
        apiHost = s.apiHost
        apiPort = s.apiPort
        apiToken = s.apiToken ?? ""
        audioOutput = AudioOutputSettingsModel(device: s.audioDevice, map: s.busOutputMap, borrowMasterForMonitor: s.borrowMasterForMonitor)
        bindAudioOutput()
        compatLayerEnabled = s.compatLayerEnabled
        compatLayerPort = s.compatLayerPort
        compatLayerHost = s.compatLayerHost
        compatLayerHTTPPort = s.compatLayerHTTPPort
        overlaysInPreview = s.overlaysInPreview
        externalBehindInterface = s.externalBehindInterface
        confirmBeforeStop = s.confirmBeforeStop
        recordMinimumFreeMB = s.recordMinimumFreeMB
        recordFallbackDirectory = s.recordFallbackDirectory ?? ""
        apiListenText = "\(s.apiHost):\(s.apiPort)"
        compatListenText = "\(s.compatLayerHost):\(s.compatLayerPort)"
        listenError = nil
        let languages = controller.defaults.stringArray(forKey: "AppleLanguages")
        language = languages?.first.flatMap { code in L10n.supportedLanguages.contains(code) ? code : nil } ?? Self.systemLanguage
        loading = false
        refreshPending()
    }

    /// 对齐延迟的范围（帧，48 kHz）：0 … 0.5 s。
    static let alignmentRange = 0...24_000
    static let alignmentStep = 256

    /// 对齐延迟 / 监听点变了就换 session 重建音频引擎（录制 / 推流会停）；没变返回 false。
    @discardableResult
    func applyShowAudio() -> Bool {
        guard let session = controller.session else { return false }
        let frames = min(max(alignmentFrames, Self.alignmentRange.lowerBound), Self.alignmentRange.upperBound)
        guard frames != session.state.audio.alignmentFrames || monitorPoint != session.state.audio.monitorPoint else { return false }
        let point = monitorPoint
        controller.confirmEngineRestart(.showAudio, in: presentingWindow) { [weak self, controller = self.controller] in
            self?.status = L("prefs.status.restarting")
            Task { await controller.changeShowAudio(alignmentFrames: frames, monitorPoint: point) }
        }
        return true
    }

    /// 应用设置并立刻重起引擎（API / 音频设备 / 兼容层的改动才生效）；录制 / 推流在跑先确认，取消 = 既不应用也不重起。
    func applyAndRestart() {
        controller.confirmEngineRestart(.restart, in: presentingWindow) { [weak self, controller = self.controller] in
            self?.apply()
            self?.status = L("prefs.status.restarting")
            Task { await controller.restartSession() }
        }
    }

    /// 选备用录制目录（目录面板）。
    func chooseFallbackDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("settings.advanced.fallbackPanel")
        if !recordFallbackDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: recordFallbackDirectory) }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.recordFallbackDirectory = url.path
            }
        }
        if let window = presentingWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }
}

// MARK: 页

/// 页里一项标"需重起引擎"。
struct RestartTag: View {
    var body: some View {
        Text(L("settings.restartTag"))
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(.orange)
            .accessibilityLabel(L("settings.restartTag"))
    }
}

/// 本节目 › 节目格式。
struct ShowFormatPage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker(L("prefs.format.resolution"), selection: Binding(get: { model.isCustomResolution ? "custom" : "\(model.formatWidth)x\(model.formatHeight)" }, set: { v in
                        if v == "custom" {
                            if !model.isCustomResolution { model.setCustomResolution(width: model.formatWidth + 2, height: model.formatHeight) }
                            return
                        }
                        let parts = v.split(separator: "x").compactMap { Int($0) }
                        if parts.count == 2 { model.formatWidth = parts[0]; model.formatHeight = parts[1] }
                    })) {
                        ForEach(PreferencesModel.resolutions, id: \.0) { r in Text(verbatim: PreferencesModel.resolutionTitle(width: r.0, height: r.1)).tag("\(r.0)x\(r.1)") }
                        Text(L("settings.format.custom")).tag("custom")
                    }
                    RestartTag()
                }
                if model.isCustomResolution {
                    HStack {
                        TextField(L("settings.format.width"), value: Binding(get: { model.formatWidth }, set: { model.setCustomResolution(width: $0, height: model.formatHeight) }),
                                  format: PreferencesModel.plainInteger)
                        Text(verbatim: "×")
                        TextField(L("settings.format.height"), value: Binding(get: { model.formatHeight }, set: { model.setCustomResolution(width: model.formatWidth, height: $0) }),
                                  format: PreferencesModel.plainInteger)
                    }
                    Text(L("settings.format.customHint")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker(L("prefs.format.frameRate"), selection: $model.frameRate) {
                        ForEach(PreferencesModel.frameRates, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                    }
                    RestartTag()
                }
                Text(L("prefs.format.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 本节目 › 节目音频。
struct ShowAudioPage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section {
                Stepper(value: $model.alignmentFrames, in: PreferencesModel.alignmentRange, step: PreferencesModel.alignmentStep) {
                    HStack { Text(L("prefs.showAudio.alignment", model.alignmentFrames, Double(model.alignmentFrames) / 48)); RestartTag() }
                }
                HStack {
                    Picker(L("prefs.showAudio.monitorPoint"), selection: $model.monitorPoint) {
                        ForEach(SwitcherContracts.MonitorPoint.allCases, id: \.self) { Text(L("prefs.showAudio.monitorPoint.\($0.rawValue)")).tag($0) }
                    }
                    RestartTag()
                }
                Text(L("prefs.showAudio.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 本机 › 常规。
struct GeneralPage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            ReminderSettingsSection(model: model.reminders)   // 主窗口提醒条（W5-L，N02 / Q50）
            Section(L("prefs.confirm.title")) {
                Toggle(L("prefs.confirm.stop"), isOn: $model.confirmBeforeStop)
                Text(L("prefs.confirm.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.language.title")) {
                Picker(L("prefs.language.picker"), selection: $model.language) {
                    ForEach(model.languageChoices) { Text($0.title).tag($0.id) }
                }
                Text(L("prefs.language.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.preview.title")) {
                HStack { Toggle(L("prefs.preview.overlaysAll"), isOn: $model.overlaysInPreview); RestartTag() }
                Text(L("prefs.preview.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("prefs.external.title")) {
                Toggle(L("prefs.external.behindInterface"), isOn: $model.externalBehindInterface)
                Text(L("prefs.external.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 本机 › 音频设备：97（W5-K）的整节（设备 + 每条总线选声道对 + 2 声道设备借 Master 监听），换设备要重起引擎（96 的待应用机制）。
struct AudioDevicePage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            AudioOutputSettingsSection(model: model.audioOutput)   // 设备 + 每条总线的声道（W5-K / J8）
            Section {
                HStack { Text(L("settings.pending.audioDevice")); Spacer(); RestartTag() }
            }
        }
        .formStyle(.grouped)
    }
}

/// 本机 › 远程控制：98（W5-L）的 RemoteControlSection（本地 API / 兼容层各"仅本机 / 允许局域网"、端口、令牌、可访问地址与提醒）；自由填 host:port 仍在"高级"页。
struct RemoteControlPage: View {
    @ObservedObject var model: PreferencesModel
    let openAdvanced: () -> Void

    var body: some View {
        Form {
            RemoteControlSection(model: model)
            Section {
                HStack { Text(L("settings.pending.api")); Spacer(); RestartTag() }
            }
            Section {
                Button(L("settings.remote.editListen")) { openAdvanced() }
            }
        }
        .formStyle(.grouped)
    }
}

/// 本机 › Tally：98（W5-L）的只读 tally 流一节（开关、端口、地址、连接数），即时生效。
struct TallyPage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            TallySettingsSection(model: model.tally)
        }
        .formStyle(.grouped)
    }
}

/// 本机 › 性能与电源：98（W5-L）的防睡眠 / App Nap 两个开关与现状行（即时生效）+ 这台机器的只读信息。
struct PerformancePage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            PowerSettingsSection(model: model.power)   // 98 的这一节自带机型 / 芯片 / 内存 / GPU / 系统几行，96 原来那一节不再重复列
        }
        .formStyle(.grouped)
    }
}

/// 本机 › 更新与诊断。
struct UpdatesPage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section(L("prefs.update.title")) {
                Text(model.updateStatus).font(.caption).foregroundStyle(.secondary)
                if model.updatesConfigured {
                    Toggle(L("prefs.update.automatic"), isOn: $model.automaticUpdates)
                    Button(L("prefs.update.check")) { model.checkForUpdates() }
                    Text(L("prefs.update.pending")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(L("prefs.update.check")) {}.disabled(true)
                    Text(L("prefs.update.unconfiguredHint")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(L("prefs.update.exportDiagnostics")) { model.exportDiagnostics() }
                Text(L("prefs.update.diagnosticsHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 本机 › 高级（F7 / Q64）：录制磁盘下限、备用录制目录、两个监听地址。
struct AdvancedPage: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section {
                Text(L("settings.advanced.intro")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("settings.advanced.recording")) {
                TextField(L("settings.advanced.minimumFree"), value: Binding(get: { model.recordMinimumFreeMB }, set: { model.recordMinimumFreeMB = AppSettings.clampMinimumFreeMB($0) }),
                          format: PreferencesModel.minimumFreeFormat)
                Text(L("settings.advanced.minimumFreeHint")).font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("settings.advanced.fallback")) {
                    HStack {
                        Text(model.recordFallbackDirectory.isEmpty ? L("settings.advanced.fallbackNone") : model.recordFallbackDirectory)
                            .lineLimit(1).truncationMode(.middle).help(model.recordFallbackDirectory)
                        Button(L("settings.advanced.choose")) { model.chooseFallbackDirectory() }
                        if !model.recordFallbackDirectory.isEmpty { Button(L("settings.advanced.clear")) { model.recordFallbackDirectory = "" } }
                    }
                }
                Text(L("settings.advanced.fallbackHint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("settings.advanced.listen")) {
                HStack { TextField(L("settings.advanced.apiListen"), text: $model.apiListenText); RestartTag() }
                HStack { TextField(L("settings.advanced.compatListen"), text: $model.compatListenText); RestartTag() }
                if let error = model.listenError { Text(error).font(.caption).foregroundStyle(.red) }
                Text(L("settings.advanced.listenHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 带范围的整数格式（不加千分位）：解析时钳进 range（N04：磁盘下限框填 17592186044416 MB，原来照样解析得出来、到换算成字节才溢出）。
/// 先按不分组的整数解析；解析不出来但整串是数字（比 Int 还大）按符号取 Int.max / Int.min，最后钳进 range。显示同不分组的整数。
struct ClampedIntegerFormat: ParseableFormatStyle {
    var range: ClosedRange<Int>

    var parseStrategy: Strategy { Strategy(range: range) }

    func format(_ value: Int) -> String { value.formatted(.number.grouping(.never)) }

    struct Strategy: ParseStrategy {
        var range: ClosedRange<Int>

        func parse(_ value: String) throws -> Int {
            let text = value.trimmingCharacters(in: .whitespaces)
            let n: Int
            do {
                n = try IntegerFormatStyle<Int>.number.grouping(.never).parseStrategy.parse(text)
            } catch {
                let digits = text.first == "-" || text.first == "+" ? text.dropFirst() : Substring(text)
                guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw error }
                n = text.first == "-" ? .min : .max
            }
            return min(max(n, range.lowerBound), range.upperBound)
        }
    }
}
