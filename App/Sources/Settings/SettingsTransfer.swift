// 设置的导出 / 导入 / 恢复默认（W5-J，01a F6）：一个包 = 本 App 的本机级 UserDefaults 键 + 快捷键表 + MIDI 映射表（一个 JSON 文件）。
// 只动本机级：节目里的东西（格式、输入、输出……）不在包里，恢复默认也不碰节目、不换引擎（要换引擎的项照样记成"待应用"）。
// API 的访问令牌不导出（是密码，不该跟着文件走）；恢复默认时一并清掉。导入时包里没有的已知键 = 那台机器上是默认值，这里也回到默认。
import Foundation
import SwitcherControl

@MainActor
enum SettingsTransfer {
    /// 包里一个键的值（UserDefaults 里本 App 只存这几种）。
    enum Value: Hashable, Codable, Sendable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case strings([String])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Int.self) { self = .int(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else { self = .strings(try c.decode([String].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let b): try c.encode(b)
            case .int(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            case .strings(let a): try c.encode(a)
            }
        }

        /// UserDefaults 里读出来的对象 → 值（认不出的类型为 nil）。
        init?(object: Any) {
            if let n = object as? NSNumber {
                self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .int(n.intValue)
            } else if let s = object as? String {
                self = .string(s)
            } else if let a = object as? [String] {
                self = .strings(a)
            } else {
                return nil
            }
        }

        var object: Any {
            switch self {
            case .bool(let b): b
            case .int(let n): n
            case .string(let s): s
            case .strings(let a): a
            }
        }
    }

    struct Package: Codable, Equatable, Sendable {
        /// 文件类型标记（认错文件时报错用）。
        var format = Package.formatName
        var version = 1
        var defaults: [String: Value]
        var hotkeys: HotkeyTable
        var midi: MIDIMapTable

        static let formatName = "plusmix-settings"

        static func load(from url: URL) throws -> Package {
            let package = try JSONDecoder().decode(Package.self, from: Data(contentsOf: url))
            guard package.format == formatName else { throw TransferError.notASettingsFile }
            guard package.version == 1 else { throw TransferError.unsupportedVersion(package.version) }
            // 表照读进来时的规矩查一遍（冲突 / 触发范围），坏表不进
            _ = try HotkeyTable.load(from: try package.hotkeys.jsonData())
            _ = try MIDIMapTable.load(from: try package.midi.jsonData())
            return package
        }
    }

    enum TransferError: Error, CustomStringConvertible {
        case notASettingsFile
        case unsupportedVersion(Int)
        var description: String {
            switch self {
            case .notASettingsFile: L("settings.transfer.notASettingsFile")
            case .unsupportedVersion(let v): L("settings.transfer.unsupportedVersion", v)
            }
        }
    }

    /// 包里带的 UserDefaults 键（本机级；访问令牌不在里面）。
    static let keys: [String] = [
        AppSettings.Keys.audioDevice, AppSettings.Keys.apiEnabled, AppSettings.Keys.apiListen, AppSettings.Keys.recordFallbackDirectory,
        AppSettings.Keys.recordMinimumFreeMB, AppSettings.Keys.compatLayerEnabled, AppSettings.Keys.compatLayerPort, AppSettings.Keys.compatLayerHost,
        AppSettings.Keys.overlaysInPreview, AppSettings.Keys.externalBehindInterface, AppSettings.Keys.confirmBeforeStop, "AppleLanguages",
        AppSettings.Keys.busOutputMap, AppSettings.Keys.borrowMasterForMonitor,   // W5-K：每条总线的声道 / 借 Master（G7 合并时加进导出 / 导入 / 恢复默认）
    ]

    /// 恢复默认时清掉的键（包里的 + 访问令牌）。
    static var resetKeys: [String] { keys + [AppSettings.Keys.apiToken] }

    static func makePackage(controller: AppController) -> Package {
        var values: [String: Value] = [:]
        for key in keys {
            // AppleLanguages 只看本 App 自己的设置（全局域里总有系统语言）
            let object: Any? = key == "AppleLanguages" ? controller.defaults.persistentDomain(forName: domainName(controller))?[key] : controller.defaults.object(forKey: key)
            if let object, let v = Value(object: object) { values[key] = v }
        }
        return Package(defaults: values, hotkeys: controller.hotkeyTable, midi: controller.midiTable)
    }

    private static func domainName(_ controller: AppController) -> String {
        controller.isTestHost ? AppController.testDefaultsSuite : (Bundle.main.bundleIdentifier ?? "")
    }

    static func export(controller: AppController, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(makePackage(controller: controller)).write(to: url, options: .atomic)
    }

    /// 导入前给人看的"要覆盖什么"："本机设置 5 项、快捷键表（32 条）、MIDI 映射（1 条）"。
    static func summary(of package: Package) -> String {
        L("settings.transfer.summary", package.defaults.count, package.hotkeys.bindings.count, package.midi.mappings.count)
    }

    /// 写回：已知键按包设（包里没有的回到默认）、表写文件并换给派发器 / MIDI 控制器、AppController.settings 重读（运行时能改的落到跑着的 session）。
    static func apply(_ package: Package, controller: AppController) throws {
        for key in keys {
            if let v = package.defaults[key] { controller.defaults.set(v.object, forKey: key) } else { controller.defaults.removeObject(forKey: key) }
        }
        try reloadSettings(controller: controller)
        try package.hotkeys.save(to: controller.hotkeyFileURL)
        try controller.applyHotkeyTable(package.hotkeys)
        try package.midi.save(to: controller.midiFileURL)
        try controller.applyMIDITable(package.midi)
    }

    /// 恢复默认（本机级）：清键、快捷键回默认表、MIDI 回空表；不动节目。
    static func restoreDefaults(controller: AppController) throws {
        for key in resetKeys { controller.defaults.removeObject(forKey: key) }
        try reloadSettings(controller: controller)
        try HotkeyTable.default.save(to: controller.hotkeyFileURL)
        try controller.applyHotkeyTable(.default)
        try MIDIMapTable.default.save(to: controller.midiFileURL)
        try controller.applyMIDITable(.default)
    }

    /// 按 UserDefaults 重读设置（不看启动参数：导入 / 恢复的值优先），启动参数里的节目 / 统计文件路径照留。
    private static func reloadSettings(controller: AppController) throws {
        var s = AppSettings.load(arguments: [], defaults: controller.defaults)
        s.showURL = controller.settings.showURL
        s.statsURL = controller.settings.statsURL
        controller.updateSettings(s)
    }
}
