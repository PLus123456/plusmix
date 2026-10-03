// 添加输入的本机记忆（W5-F，01a G1 / 04 Q59）：上次用的类型（底栏主体打开添加面板就停在这一页）、最近添加的来源（▴ 里一键再加一路：编号取空号、名字自动取）。
// 存 UserDefaults（本机偏好，和节目文件无关；测试宿主是自己的 suite，AppTest.freshSession 每条用例开头清掉）。最近添加最多 5 个、新的在前、同一来源只留最新一次；
// 文件 / 图片已经不在的不列（列出来也加不出画面）。名字只是给人看的："类型 · 摘要"。
import AppKit
import AVFoundation
import SwitcherContracts

@MainActor
final class AddInputHistory {
    static let maxRecent = 5
    enum Keys {
        static let lastKind = "addInputLastKind"
        static let recentSources = "addInputRecentSources"
    }

    private let defaults: UserDefaults
    /// 最近添加的来源（新的在前）。
    private(set) var recentSources: [InputSource] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.recentSources), let list = try? JSONDecoder().decode([InputSource].self, from: data) {
            recentSources = Array(list.prefix(Self.maxRecent))
        }
    }

    /// 上次添加用的类型（没有就是合成测试源，和添加面板的默认一样）。
    var lastKind: AddInputModel.Kind {
        guard defaults.object(forKey: Keys.lastKind) != nil, let kind = AddInputModel.Kind(rawValue: defaults.integer(forKey: Keys.lastKind)) else { return .synthetic }
        return kind
    }

    /// 加了一路（添加面板确定、▴ 里一键再加）：记下类型和来源。
    func noteAdded(_ config: InputConfig) {
        defaults.set(AddInputModel.Kind(config.kind).rawValue, forKey: Keys.lastKind)
        recentSources.removeAll { $0 == config.source }
        recentSources.insert(config.source, at: 0)
        if recentSources.count > Self.maxRecent { recentSources.removeLast(recentSources.count - Self.maxRecent) }
        if let data = try? JSONEncoder().encode(recentSources) { defaults.set(data, forKey: Keys.recentSources) }
    }

    /// 某一类上次加的来源（添加面板按它预填这一类的设备 / 路径，W5-K / G2）。
    func lastSource(for kind: AddInputModel.Kind) -> InputSource? { nil }

    /// 视频 / 图片最近用过的文件（新的在前，最多 10 个；W5-K / G11）。
    func recentFiles(for kind: AddInputModel.Kind) -> [String] { [] }

    /// 清掉（测试）。
    func reset() {
        recentSources = []
        defaults.removeObject(forKey: Keys.lastKind)
        defaults.removeObject(forKey: Keys.recentSources)
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
