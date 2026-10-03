// 启动参数与用户设置（W2-B2；W3-E 的偏好设置面板读写同一组键）。
//   --show <路径>            启动时打开这个节目文件（不走"上次"）
//   --stats <路径>           把每秒的 Stats 也写进 stats.jsonl
//   --audio-device <spec>    音频输出设备：default（系统默认，跟随变更）/ null（空设备，不出声，CI 用）/ <设备名>（精确或包含）
//   --api-listen <host:port> 本地 API 监听地址（默认 127.0.0.1:8765；端口 0 = 系统分配，测试用）
//   --api-token <token>      API 的简单 token 鉴权（默认关）
//   --no-api                 不起 API
//   --record-fallback <目录>  录制目标盘满 / 低于下限时自动切到这个目录继续录（W3-C，S7 目标档）；不设 = 只停录制并提示
//   --record-min-free-mb <N> 录制目录剩余空间低于 N MB 就停该路录制（默认 200）
// 同名 UserDefaults 键：audioOutputDevice / apiEnabled / apiListen / apiToken / recordFallbackDirectory / recordMinimumFreeMB；
// W3-E 加 compatLayerEnabled / compatLayerPort（第三方 API 兼容层 VMixCompat，默认关；G4 合并后由 ControlRuntime 按这两个键起）；
// W3-E2 加 overlaysInPreview（PVW 预览全部叠加 = MetalRendererOptions.overlaysInPreview，渲染器选项在 init 定死，换 session 生效）；
// W3-E3 加 externalOutputBehindInterface（外部输出在主屏上不盖住主界面 = ExternalDisplayManager.mainScreenLayering，包内选项、运行时可改，
// 不进 OutputSettings.display——那是节目文件里的输出设置，这个是本机偏好）；W5-B 加 confirmBeforeStop（底栏停录制 / 推流前先确认，默认开）。命令行参数优先于 UserDefaults。
import Foundation
import SwitcherControl
import SwitcherExternal
import SwitcherRender
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
    }

    var audioDevice: AudioDevice = .systemDefault
    var apiEnabled = true
    var apiHost = "127.0.0.1"
    var apiPort = APIServerConfiguration.defaultPort
    var apiToken: String?
    /// 第三方 API 兼容层（VMixCompat）开关与 TCP 端口；默认关（设计方案 §9.3、落地方案 §2 第 7 条）。
    var compatLayerEnabled = false
    var compatLayerPort = AppSettings.defaultCompatLayerPort
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

    /// 外部显示管理器的主屏层级（ExternalDisplayManager.mainScreenLayering）。
    var externalMainScreenLayering: ExternalDisplayWindow.MainScreenLayering { externalBehindInterface ? .behindInterface : .front }

    /// 起 session 用的渲染器选项。
    var rendererOptions: MetalRendererOptions {
        var o = MetalRendererOptions()
        o.overlaysInPreview = overlaysInPreview
        return o
    }

    static let defaultCompatLayerPort = 8099

    /// API 配置；关掉时 nil。
    /// 第三方 API 兼容层（W3-D VMixCompat）的配置；开关关着 = nil（不监听任何端口）。TCP 端口来自偏好设置，HTTP 端口用默认（8088），只听本机。
    var compatConfiguration: VMixCompatConfiguration? {
        guard compatLayerEnabled else { return nil }
        var c = VMixCompatConfiguration()
        c.enabled = true
        c.tcpPort = compatLayerPort
        return c
    }

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
        if defaults.object(forKey: Keys.overlaysInPreview) != nil { s.overlaysInPreview = defaults.bool(forKey: Keys.overlaysInPreview) }
        if defaults.object(forKey: Keys.externalBehindInterface) != nil { s.externalBehindInterface = defaults.bool(forKey: Keys.externalBehindInterface) }
        if defaults.object(forKey: Keys.confirmBeforeStop) != nil { s.confirmBeforeStop = defaults.bool(forKey: Keys.confirmBeforeStop) }

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
        return s
    }

    /// 偏好设置面板：把可持久化的项写回 UserDefaults（同一组键；showURL / statsURL 是启动参数，不存）。
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
    }
}
