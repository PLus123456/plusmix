// 启动参数与用户设置（W2-B2；W3-E 的偏好设置面板读写同一组键）。
//   --show <路径>            启动时打开这个节目文件（不走"上次"）
//   --stats <路径>           把每秒的 Stats 也写进 stats.jsonl
//   --audio-device <spec>    音频输出设备：default（系统默认，跟随变更）/ null（空设备，不出声，CI 用）/ <设备名>（精确或包含）
//   --api-listen <host:port> 本地 API 监听地址（默认 127.0.0.1:8765；端口 0 = 系统分配，测试用）
//   --api-token <token>      API 的简单 token 鉴权（默认关）
//   --no-api                 不起 API
//   --record-fallback <目录>  录制目标盘满 / 低于下限时自动切到这个目录继续录（W3-C，S7 目标档）；不设 = 只停录制并提示
//   --record-min-free-mb <N> 录制目录剩余空间低于 N MB 就停该路录制（默认 200）
//   --tally-port <N>         起只读 tally 流（WS /tally、GET /tally），听这个端口（与 headless 同名；不给 = 看设置 › Tally）
// 同名 UserDefaults 键：audioOutputDevice / apiEnabled / apiListen / apiToken / recordFallbackDirectory / recordMinimumFreeMB；
// W3-E 加 compatLayerEnabled / compatLayerPort（第三方 API 兼容层 VMixCompat，默认关；G4 合并后由 ControlRuntime 按这两个键起）；
// W3-E2 加 overlaysInPreview（PVW 预览全部叠加 = MetalRendererOptions.overlaysInPreview，渲染器选项在 init 定死，换 session 生效）；
// W3-E3 加 externalOutputBehindInterface（外部输出在主屏上不盖住主界面 = ExternalDisplayManager.mainScreenLayering，包内选项、运行时可改，
// 不进 OutputSettings.display——那是节目文件里的输出设置，这个是本机偏好）；W5-B 加 confirmBeforeStop（底栏停录制 / 推流前先确认，默认开）；
// W5-K 加 audioBusOutputMap（每条总线送到设备哪一对声道，JSON；没有 = 跟设备默认）与 audioBorrowMasterForMonitor。命令行参数优先于 UserDefaults。
// W5-L（98）加：preventSleepWhileRunning / preventDisplaySleepWhileRunning（引擎运行时阻止系统睡眠与 App Nap / 显示器休眠，默认都开，Q47）；
// tallyEnabled / tallyPort（只读 tally 流，默认关，端口没设 = API 端口 + 1，Q46；--tally-port <N> 与 headless 同名，给了就开）；
// compatLayerHost / compatLayerHTTPPort（兼容层"仅本机 / 允许局域网"与 HTTP 端口，原来写死 127.0.0.1 / 8088，X33）；reminder* 四个键（主窗口提醒条，N02 / Q50）。
import Foundation
import SwitcherControl
import SwitcherEngine
import SwitcherExternal
import SwitcherRender
import SwitcherTally
import VMixCompat

struct AppSettings: Equatable, Sendable {
    /// 音频输出设备的选择（与 headless 的 --audio-device 同一套写法）。
    enum AudioDevice: Equatable, Sendable, Hashable {
        case systemDefault
        case null
        case named(String)

        /// "default" / "" → 系统默认；"null" / "none" → 空设备；其他 = 设备名。
        init(spec: String) {
            switch spec.trimmingCharacters(in: .whitespaces).lowercased() {
            case "", "default", "system": self = .systemDefault
            case "null", "none": self = .null
            default: self = .named(spec.trimmingCharacters(in: .whitespaces))
            }
        }

        var spec: String {
            switch self {
            case .systemDefault: "default"
            case .null: "null"
            case .named(let n): n
            }
        }
    }

    enum Keys {
        static let audioDevice = "audioOutputDevice"
        static let apiEnabled = "apiEnabled"
        static let apiListen = "apiListen"
        static let apiToken = "apiToken"
        static let recordFallbackDirectory = "recordFallbackDirectory"
        static let recordMinimumFreeMB = "recordMinimumFreeMB"
        static let compatLayerEnabled = "compatLayerEnabled"
        static let compatLayerPort = "compatLayerPort"
        static let overlaysInPreview = "overlaysInPreview"
        static let externalBehindInterface = "externalOutputBehindInterface"
        static let confirmBeforeStop = "confirmBeforeStop"
        /// 兼容层的监听地址（W5-J 设置 › 高级；HTTP 与 TCP 共用）。
        static let compatLayerHost = "compatLayerHost"
        static let busOutputMap = "audioBusOutputMap"
        static let borrowMasterForMonitor = "audioBorrowMasterForMonitor"
        static let preventSleep = "preventSleepWhileRunning"
        static let preventDisplaySleep = "preventDisplaySleepWhileRunning"
        static let tallyEnabled = "tallyEnabled"
        static let tallyPort = "tallyPort"
        static let compatLayerHTTPPort = "compatLayerHTTPPort"
        static let reminderNotLive = "reminderNotLive"
        static let reminderNotLiveMinutes = "reminderNotLiveMinutes"
        static let reminderFTB = "reminderFTB"
        static let reminderLowAudio = "reminderLowAudio"
    }

    var audioDevice: AudioDevice = .systemDefault
    var apiEnabled = true
    var apiHost = "127.0.0.1"
    var apiPort = APIServerConfiguration.defaultPort
    var apiToken: String?
    /// 第三方 API 兼容层（VMixCompat）开关与 TCP 端口；默认关（设计方案 §9.3、落地方案 §2 第 7 条）。
    var compatLayerEnabled = false
    var compatLayerPort = AppSettings.defaultCompatLayerPort
    /// 兼容层的监听地址（HTTP 与 TCP 共用）：127.0.0.1 = 仅本机，0.0.0.0 = 允许局域网（W5-L 远程控制页二选一，X33；W5-J 的高级页也能填）。
    var compatLayerHost = "127.0.0.1"
    var showURL: URL?
    var statsURL: URL?
    /// 磁盘满时的备用录制目录（nil = 只停录制）。
    var recordFallbackDirectory: String?
    /// 录制目录剩余空间下限（MB），低于就停该路。
    var recordMinimumFreeMB = 200
    /// PVW 预览全部叠加（渲染器总开关，与每通道 OverlayState.previewOn 取或；默认关）。
    var overlaysInPreview = false
    /// 外部输出开在主屏（带菜单栏的那块）上时垫在主界面下面（默认关 = 盖住，W3-C 起的行为）。
    var externalBehindInterface = false
    /// 底栏停录制 / 停推流之前先确认（W5-B，默认开；快捷键 / MIDI / API 一律不问）。
    var confirmBeforeStop = true
    /// 每条总线送到输出设备的哪一对声道（W5-K，J8）；nil = 跟设备默认（Master 1/2，设备 ≥ 4 声道时耳机 3/4）。
    var busOutputMap: BusOutputMap?
    /// 设备没有耳机声道时，监听（独听 / PFL）临时占用 Master 声道（W5-K，X09）。
    var borrowMasterForMonitor = false
    /// 引擎运行时阻止系统睡眠与 App Nap（W5-L，EngineActivity；默认开，Q47）。
    var preventSleepWhileRunning = true
    /// 引擎运行时阻止显示器休眠（单独一个开关，默认也阻止，Q47）。
    var preventDisplaySleepWhileRunning = true
    /// 只读 tally 流（W5-L，SwitcherTally；默认关，Q46）。
    var tallyEnabled = false
    /// tally 流端口；nil = API 端口 + 1（docs/integrations/tally.md 的默认 8766）。
    var tallyPort: Int?
    /// tally 流听哪个地址：打开即听局域网（Q46）。不存：测试宿主改成只听本机（防火墙会为监听局域网弹框）。
    var tallyHost = "0.0.0.0"
    /// 兼容层的 HTTP 端口（原来写死 8088）。
    var compatLayerHTTPPort = VMixCompatConfiguration.defaultHTTPPort
    /// 主窗口提醒条的四个设置（N02 / Q50）。
    var reminders = ReminderSettings()

    /// tally 流实际用的端口：设了用设的，没设 = API 端口 + 1（API 端口 0 = 系统分配时也给 0）。
    var effectiveTallyPort: Int { tallyPort ?? (apiPort == 0 ? 0 : min(65535, apiPort + 1)) }

    /// tally 服务配置；开关关着 = nil（不监听）。
    var tallyConfiguration: TallyServerConfiguration? {
        guard tallyEnabled else { return nil }
        return TallyServerConfiguration(host: tallyHost, port: effectiveTallyPort)
    }

    /// 外部显示管理器的主屏层级（ExternalDisplayManager.mainScreenLayering）。
    var externalMainScreenLayering: ExternalDisplayWindow.MainScreenLayering { externalBehindInterface ? .behindInterface : .front }

    /// 起 session 用的渲染器选项。
    var rendererOptions: MetalRendererOptions {
        var o = MetalRendererOptions()
        o.overlaysInPreview = overlaysInPreview
        o.videoDelayHeadroom = EngineOptions().videoDelay.maxDelay   // W1-B4（G8b 接）：引擎最多把帧压 35 ms 再派发，NV12 输出环加深 4 个（不加深会被延迟队列扣满、退回池子分配）
        o.displayDelayHistory = true                                 // 监视器 / 外部显示 / 多画面跟着延后：多留 3 格合成目标（1080p ≈ 75 MB）；三样要和 displayDelayProvider / audio.engine.videoDelay 一起接
        return o
    }

    static let defaultCompatLayerPort = 8099

    /// 第三方 API 兼容层（W3-D VMixCompat）的配置；开关关着 = nil（不监听任何端口）。地址 / TCP 端口 / HTTP 端口都来自设置（W5-L 起地址与 HTTP 端口可改）。
    var compatConfiguration: VMixCompatConfiguration? {
        guard compatLayerEnabled else { return nil }
        var c = VMixCompatConfiguration()
        c.enabled = true
        c.host = compatLayerHost
        c.tcpPort = compatLayerPort
        c.httpPort = compatLayerHTTPPort
        return c
    }

    /// API 配置；关掉时 nil。

    var apiConfiguration: APIServerConfiguration? {
        guard apiEnabled else { return nil }
        return APIServerConfiguration(host: apiHost, port: apiPort, token: apiToken)
    }

    /// 命令行参数 + UserDefaults → 设置。参数优先。
    static func load(arguments: [String], defaults: UserDefaults) -> AppSettings {
        var s = AppSettings()
        if let spec = defaults.string(forKey: Keys.audioDevice) { s.audioDevice = AudioDevice(spec: spec) }
        if defaults.object(forKey: Keys.apiEnabled) != nil { s.apiEnabled = defaults.bool(forKey: Keys.apiEnabled) }
        if let listen = defaults.string(forKey: Keys.apiListen), let parsed = APIServerConfiguration.parseListen(listen) {
            s.apiHost = parsed.host
            s.apiPort = parsed.port
        }
        if let token = defaults.string(forKey: Keys.apiToken), !token.isEmpty { s.apiToken = token }
        if let dir = defaults.string(forKey: Keys.recordFallbackDirectory), !dir.isEmpty { s.recordFallbackDirectory = dir }
        if defaults.object(forKey: Keys.recordMinimumFreeMB) != nil { s.recordMinimumFreeMB = max(0, defaults.integer(forKey: Keys.recordMinimumFreeMB)) }
        if defaults.object(forKey: Keys.compatLayerEnabled) != nil { s.compatLayerEnabled = defaults.bool(forKey: Keys.compatLayerEnabled) }
        if defaults.object(forKey: Keys.compatLayerPort) != nil, defaults.integer(forKey: Keys.compatLayerPort) > 0 {
            s.compatLayerPort = defaults.integer(forKey: Keys.compatLayerPort)
        }
        if let host = defaults.string(forKey: Keys.compatLayerHost), !host.isEmpty { s.compatLayerHost = host }
        if defaults.object(forKey: Keys.overlaysInPreview) != nil { s.overlaysInPreview = defaults.bool(forKey: Keys.overlaysInPreview) }
        if defaults.object(forKey: Keys.externalBehindInterface) != nil { s.externalBehindInterface = defaults.bool(forKey: Keys.externalBehindInterface) }
        if defaults.object(forKey: Keys.confirmBeforeStop) != nil { s.confirmBeforeStop = defaults.bool(forKey: Keys.confirmBeforeStop) }
        if let data = defaults.data(forKey: Keys.busOutputMap) { s.busOutputMap = try? JSONDecoder().decode(BusOutputMap.self, from: data) }
        if defaults.object(forKey: Keys.borrowMasterForMonitor) != nil { s.borrowMasterForMonitor = defaults.bool(forKey: Keys.borrowMasterForMonitor) }
        if defaults.object(forKey: Keys.preventSleep) != nil { s.preventSleepWhileRunning = defaults.bool(forKey: Keys.preventSleep) }
        if defaults.object(forKey: Keys.preventDisplaySleep) != nil { s.preventDisplaySleepWhileRunning = defaults.bool(forKey: Keys.preventDisplaySleep) }
        if defaults.object(forKey: Keys.tallyEnabled) != nil { s.tallyEnabled = defaults.bool(forKey: Keys.tallyEnabled) }
        if defaults.object(forKey: Keys.tallyPort) != nil, (0...65535).contains(defaults.integer(forKey: Keys.tallyPort)) {
            s.tallyPort = defaults.integer(forKey: Keys.tallyPort)
        }
        if defaults.object(forKey: Keys.compatLayerHTTPPort) != nil, (1...65535).contains(defaults.integer(forKey: Keys.compatLayerHTTPPort)) {
            s.compatLayerHTTPPort = defaults.integer(forKey: Keys.compatLayerHTTPPort)
        }
        if defaults.object(forKey: Keys.reminderNotLive) != nil { s.reminders.notLiveEnabled = defaults.bool(forKey: Keys.reminderNotLive) }
        if defaults.object(forKey: Keys.reminderNotLiveMinutes) != nil {
            s.reminders.notLiveMinutes = ReminderSettings.clampMinutes(defaults.integer(forKey: Keys.reminderNotLiveMinutes))
        }
        if defaults.object(forKey: Keys.reminderFTB) != nil { s.reminders.ftbEnabled = defaults.bool(forKey: Keys.reminderFTB) }
        if defaults.object(forKey: Keys.reminderLowAudio) != nil { s.reminders.lowAudioEnabled = defaults.bool(forKey: Keys.reminderLowAudio) }

        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        if let v = value(after: "--show") { s.showURL = URL(fileURLWithPath: v) }
        if let v = value(after: "--stats") { s.statsURL = URL(fileURLWithPath: v) }
        if let v = value(after: "--audio-device") { s.audioDevice = AudioDevice(spec: v) }
        if let v = value(after: "--api-listen"), let parsed = APIServerConfiguration.parseListen(v) {
            s.apiHost = parsed.host
            s.apiPort = parsed.port
            s.apiEnabled = true
        }
        if let v = value(after: "--api-token") { s.apiToken = v.isEmpty ? nil : v }
        if arguments.contains("--no-api") { s.apiEnabled = false }
        if let v = value(after: "--record-fallback") { s.recordFallbackDirectory = v.isEmpty ? nil : v }
        if let v = value(after: "--record-min-free-mb"), let n = Int(v) { s.recordMinimumFreeMB = max(0, n) }
        if let v = value(after: "--tally-port"), let n = Int(v), (0...65535).contains(n) {
            s.tallyEnabled = true
            s.tallyPort = n
        }
        return s
    }

    /// 设置窗：把可持久化的项写回 UserDefaults（同一组键；showURL / statsURL 是启动参数，不存）。W5-J 起也写录制下限 / 备用目录 / 兼容层地址（高级页）。
    func save(to defaults: UserDefaults) {
        defaults.set(audioDevice.spec, forKey: Keys.audioDevice)
        defaults.set(apiEnabled, forKey: Keys.apiEnabled)
        defaults.set("\(apiHost):\(apiPort)", forKey: Keys.apiListen)
        if let apiToken, !apiToken.isEmpty { defaults.set(apiToken, forKey: Keys.apiToken) } else { defaults.removeObject(forKey: Keys.apiToken) }
        defaults.set(compatLayerEnabled, forKey: Keys.compatLayerEnabled)
        defaults.set(compatLayerPort, forKey: Keys.compatLayerPort)
        defaults.set(overlaysInPreview, forKey: Keys.overlaysInPreview)
        defaults.set(externalBehindInterface, forKey: Keys.externalBehindInterface)
        defaults.set(confirmBeforeStop, forKey: Keys.confirmBeforeStop)
        defaults.set(compatLayerHost, forKey: Keys.compatLayerHost)
        defaults.set(recordMinimumFreeMB, forKey: Keys.recordMinimumFreeMB)
        if let recordFallbackDirectory, !recordFallbackDirectory.isEmpty {
            defaults.set(recordFallbackDirectory, forKey: Keys.recordFallbackDirectory)
        } else {
            defaults.removeObject(forKey: Keys.recordFallbackDirectory)
        }
        if let busOutputMap, let data = try? JSONEncoder().encode(busOutputMap) { defaults.set(data, forKey: Keys.busOutputMap) } else { defaults.removeObject(forKey: Keys.busOutputMap) }
        defaults.set(borrowMasterForMonitor, forKey: Keys.borrowMasterForMonitor)
        defaults.set(compatLayerHTTPPort, forKey: Keys.compatLayerHTTPPort)
        savePower(to: defaults)
        saveTally(to: defaults)
        saveReminders(to: defaults)
    }

    // 即时生效的三节（W5-L）只写自己的键（AppController.updateSettings(_:saving:)）：整份写回会把启动参数带进来的值（--api-token、--no-api……）
    // 顺手存成本机设置。

    /// 性能与电源：两个防睡眠开关。
    func savePower(to defaults: UserDefaults) {
        defaults.set(preventSleepWhileRunning, forKey: Keys.preventSleep)
        defaults.set(preventDisplaySleepWhileRunning, forKey: Keys.preventDisplaySleep)
    }

    /// Tally：开关与端口（没单独设端口 = 删键，跟着 API 端口 + 1）。
    func saveTally(to defaults: UserDefaults) {
        defaults.set(tallyEnabled, forKey: Keys.tallyEnabled)
        if let tallyPort { defaults.set(tallyPort, forKey: Keys.tallyPort) } else { defaults.removeObject(forKey: Keys.tallyPort) }
    }

    /// 提醒：四个键。
    func saveReminders(to defaults: UserDefaults) {
        defaults.set(reminders.notLiveEnabled, forKey: Keys.reminderNotLive)
        defaults.set(reminders.notLiveMinutes, forKey: Keys.reminderNotLiveMinutes)
        defaults.set(reminders.ftbEnabled, forKey: Keys.reminderFTB)
        defaults.set(reminders.lowAudioEnabled, forKey: Keys.reminderLowAudio)
    }
}
