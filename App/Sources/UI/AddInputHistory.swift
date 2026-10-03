// 添加输入的本机记忆（W5-F，01a G1 / 04 Q59；W5-K，G2 / G4 / G11）：
// - 上次用的类型（底栏主体 / ⌘I 打开添加面板就停在这一页；第一次停在"摄像头 / 采集卡"，Q58：合成测试源不作默认）；
// - 每一类上次加的来源（面板按它预填这一类的设备 / 路径 / 源名，切到哪一页都带着）；
// - 最近添加的来源（▴ 里一键再加一路：编号取空号、名字自动取；最多 5 个、新的在前、同一来源只留最新一次；文件 / 图片已经不在的不列）；
// - 视频 / 图片最近用过的文件（各最多 10 个，新的在前；不在了的照列、灰着，由面板决定）；
// - 添加面板的尺寸（sheet 可以缩放，下次照这个尺寸开）。
// 存 UserDefaults（本机偏好，和节目文件无关；测试宿主是自己的 suite，AppTest.freshSession 每条用例开头清掉）。键用契约的 InputKind 名（"file" / "ndi"…），
// 不用 Kind 的序号——左栏改了顺序也不串。名字只是给人看的："类型 · 摘要"。
import AppKit
import AVFoundation
import SwitcherContracts

@MainActor
final class AddInputHistory {
    static let maxRecent = 5
    static let maxRecentFiles = 10
    /// 第一次打开添加面板停在哪一类（G2 / Q58）。
    static let defaultKind: AddInputModel.Kind = .camera
    enum Keys {
        static let lastKind = "addInputLastKind"
        static let recentSources = "addInputRecentSources"
        static let lastSources = "addInputLastSources"
        static let recentMovieFiles = "addInputRecentMovieFiles"
        static let recentImageFiles = "addInputRecentImageFiles"
        static let sheetSize = "addInputSheetSize"
    }

    private let defaults: UserDefaults
    /// 最近添加的来源（新的在前）。
    private(set) var recentSources: [InputSource] = []
    /// 每一类上次加的来源（键 = InputKind 的名字）。
    private var lastSources: [String: InputSource] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.recentSources), let list = try? JSONDecoder().decode([InputSource].self, from: data) {
            recentSources = Array(list.prefix(Self.maxRecent))
        }
        if let data = defaults.data(forKey: Keys.lastSources), let map = try? JSONDecoder().decode([String: InputSource].self, from: data) {
            lastSources = map
        }
    }

    /// 上次添加用的类型（没有就是摄像头 / 采集卡）。
    var lastKind: AddInputModel.Kind {
        guard defaults.object(forKey: Keys.lastKind) != nil, let kind = AddInputModel.Kind(rawValue: defaults.integer(forKey: Keys.lastKind)) else { return Self.defaultKind }
        return kind
    }

    /// 某一类上次加的来源。
    func lastSource(for kind: AddInputModel.Kind) -> InputSource? { lastSources[kind.inputKind.rawValue] }

    /// 加了一路（添加面板确定、▴ 里一键再加）：记下类型、这一类的来源、最近添加；文件 / 图片再进最近文件。
    func noteAdded(_ config: InputConfig) {
        let kind = AddInputModel.Kind(config.kind)
        defaults.set(kind.rawValue, forKey: Keys.lastKind)
        recentSources.removeAll { $0 == config.source }
        recentSources.insert(config.source, at: 0)
        if recentSources.count > Self.maxRecent { recentSources.removeLast(recentSources.count - Self.maxRecent) }
        if let data = try? JSONEncoder().encode(recentSources) { defaults.set(data, forKey: Keys.recentSources) }
        lastSources[kind.inputKind.rawValue] = config.source
        if let data = try? JSONEncoder().encode(lastSources) { defaults.set(data, forKey: Keys.lastSources) }
        switch config.source {
        case .file(let path, _, _): noteRecentFile(path, for: .file)
        case .image(let path): noteRecentFile(path, for: .image)
        default: break
        }
    }

    // MARK: 最近文件（G11）

    private static func recentFilesKey(_ kind: AddInputModel.Kind) -> String? {
        switch kind {
        case .file: Keys.recentMovieFiles
        case .image: Keys.recentImageFiles
        default: nil
        }
    }

    /// 视频 / 图片最近用过的文件（新的在前，最多 10 个）；别的类型为空。
    func recentFiles(for kind: AddInputModel.Kind) -> [String] {
        guard let key = Self.recentFilesKey(kind) else { return [] }
        return Array((defaults.stringArray(forKey: key) ?? []).prefix(Self.maxRecentFiles))
    }

    func noteRecentFile(_ path: String, for kind: AddInputModel.Kind) {
        guard let key = Self.recentFilesKey(kind), !path.isEmpty else { return }
        var list = recentFiles(for: kind).filter { $0 != path }
        list.insert(path, at: 0)
        defaults.set(Array(list.prefix(Self.maxRecentFiles)), forKey: key)
    }

    /// "清空"。
    func clearRecentFiles(for kind: AddInputModel.Kind) {
        guard let key = Self.recentFilesKey(kind) else { return }
        defaults.removeObject(forKey: key)
    }

    // MARK: 面板尺寸（G4）

    var sheetSize: NSSize? {
        get { defaults.string(forKey: Keys.sheetSize).map(NSSizeFromString).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } }
        set {
            if let newValue { defaults.set(NSStringFromSize(newValue), forKey: Keys.sheetSize) } else { defaults.removeObject(forKey: Keys.sheetSize) }
        }
    }

    /// 清掉（测试）。
    func reset() {
        recentSources = []
        lastSources = [:]
        for key in [Keys.lastKind, Keys.recentSources, Keys.lastSources, Keys.recentMovieFiles, Keys.recentImageFiles, Keys.sheetSize] {
            defaults.removeObject(forKey: key)
        }
    }

    /// 菜单里列的那几个：文件 / 图片不在了的不列。
    var availableRecents: [InputSource] {
        recentSources.filter { source in
            switch source {
            case .file(let path, _, _), .image(let path): FileManager.default.fileExists(atPath: path)
            default: true
            }
        }
    }

    /// 菜单里一项的标题："类型 · 摘要"（合成源写尺寸帧率、文件 / 图片写文件名、NDI 写源名、设备写设备名）。
    static func title(of source: InputSource) -> String {
        let kind = AddInputModel.Kind(source.kind).title
        return L("addInputMenu.recentItem", kind, detail(of: source))
    }

    private static func detail(of source: InputSource) -> String {
        switch source {
        case .synthetic(let s): return "\(s.width)×\(s.height) \(s.frameRate)"
        case .camera(let id): return AVCaptureDevice(uniqueID: id)?.localizedName ?? id
        case .decklink(let id, _, _): return id.isEmpty ? L("addInput.decklink.firstCard") : id
        case .screen(let target, _, _):
            switch target {
            case .display(let id): return NSScreen.screen(number: id)?.localizedName ?? L("addInputMenu.display", id)
            case .window(let id): return L("addInputMenu.window", id)
            case .application(let bundleID): return bundleID
            }
        case .file(let path, _, _), .image(let path): return (path as NSString).lastPathComponent
        case .ndi(let name, _, _): return name
        case .audio(let uid, _): return uid.isEmpty ? L("addInput.audio.systemDefault") : uid
        }
    }
}
