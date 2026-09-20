// 启动参数与用户设置（W2-B2）。设置面板是 W3-E 的；本期只有命令行参数 + UserDefaults 键，面板做好后改的还是这几个键。
//   --show <路径>            启动时打开这个节目文件（不走"上次"）
//   --stats <路径>           把每秒的 Stats 也写进 stats.jsonl
//   --audio-device <spec>    音频输出设备：default（系统默认，跟随变更）/ null（空设备，不出声，CI 用）/ <设备名>（精确或包含）
//   --api-listen <host:port> 本地 API 监听地址（默认 127.0.0.1:8765；端口 0 = 系统分配，测试用）
//   --api-token <token>      API 的简单 token 鉴权（默认关）
//   --no-api                 不起 API
//   --record-fallback <目录>  录制目标盘满 / 低于下限时自动切到这个目录继续录（W3-C，S7 目标档）；不设 = 只停录制并提示
//   --record-min-free-mb <N> 录制目录剩余空间低于 N MB 就停该路录制（默认 200）
// 同名 UserDefaults 键：audioOutputDevice / apiEnabled / apiListen / apiToken / recordFallbackDirectory / recordMinimumFreeMB。命令行参数优先于 UserDefaults。
import Foundation
import SwitcherControl

struct AppSettings: Equatable, Sendable {
    /// 音频输出设备的选择（与 headless 的 --audio-device 同一套写法）。
    enum AudioDevice: Equatable, Sendable {
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
    }

    var audioDevice: AudioDevice = .systemDefault
    var apiEnabled = true
    var apiHost = "127.0.0.1"
    var apiPort = APIServerConfiguration.defaultPort
    var apiToken: String?
    var showURL: URL?
    var statsURL: URL?
    /// 磁盘满时的备用录制目录（nil = 只停录制）。
    var recordFallbackDirectory: String?
    /// 录制目录剩余空间下限（MB），低于就停该路。
    var recordMinimumFreeMB = 200

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
}
