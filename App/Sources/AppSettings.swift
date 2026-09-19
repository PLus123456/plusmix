// 启动参数与用户设置（W2-B2；W3-E 的偏好设置面板读写同一组键）。
//   --show <路径>            启动时打开这个节目文件（不走"上次"）
//   --stats <路径>           把每秒的 Stats 也写进 stats.jsonl
//   --audio-device <spec>    音频输出设备：default（系统默认，跟随变更）/ null（空设备，不出声，CI 用）/ <设备名>（精确或包含）
//   --api-listen <host:port> 本地 API 监听地址（默认 127.0.0.1:8765；端口 0 = 系统分配，测试用）
//   --api-token <token>      API 的简单 token 鉴权（默认关）
//   --no-api                 不起 API
// 同名 UserDefaults 键：audioOutputDevice / apiEnabled / apiListen / apiToken；W3-E 加 compatLayerEnabled / compatLayerPort
// （第三方 API 兼容层 VMixCompat，默认关；W3-D 的 target 合进 App 后由 ControlRuntime 按这两个键起）。命令行参数优先于 UserDefaults。
import Foundation
import SwitcherControl

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
        static let compatLayerEnabled = "compatLayerEnabled"
        static let compatLayerPort = "compatLayerPort"
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

    static let defaultCompatLayerPort = 8099

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
        if defaults.object(forKey: Keys.compatLayerEnabled) != nil { s.compatLayerEnabled = defaults.bool(forKey: Keys.compatLayerEnabled) }
        if defaults.object(forKey: Keys.compatLayerPort) != nil, defaults.integer(forKey: Keys.compatLayerPort) > 0 {
            s.compatLayerPort = defaults.integer(forKey: Keys.compatLayerPort)
        }

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
    }
}
