// 节目文件（§1.1 Show）的新建 / 打开 / 保存 / 另存 / 最近 / 上次（W2-B prompt 第 6 条）。
// 文件格式和迁移都在 SwitcherEngine.ShowStore；这里只管路径、最近列表和"上次打开的"记忆（UserDefaults）。
// 不用 NSDocument：导播台一次只跑一个节目，多文档模型对不上。
import Foundation
import SwitcherContracts
import SwitcherEngine

@MainActor
final class ShowDocuments {
    static let fileExtension = "switcher.json"
    static let recentLimit = 10
    private static let recentKey = "recentShows"
    private static let lastKey = "lastShow"

    private let store = ShowStore()
    private let defaults: UserDefaults
    /// 新建节目的默认录制目录（测试宿主用临时目录）。
    let recordDirectory: String
    /// 当前节目对应的文件；未保存过为 nil。
    private(set) var currentURL: URL?

    init(defaults: UserDefaults = .standard, recordDirectory: String = ShowDocuments.defaultRecordDirectory) {
        self.defaults = defaults
        self.recordDirectory = recordDirectory
    }

    /// 默认录制目录：~/Movies/PlusMix（目录名是产品名，W4-D；0.1.0 之前叫 ~/Movies/Switcher，没发布过所以不迁移）。
    static var defaultRecordDirectory: String {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PlusMix").path ?? NSHomeDirectory()
    }

    /// 空节目：没有输入，带一个默认录制输出（录到 recordDirectory，默认 ~/Movies/PlusMix），PGM / PVW 都是黑场。
    static func emptyShow(name: String = L("show.untitled"), recordDirectory: String = ShowDocuments.defaultRecordDirectory) -> Show {
        let record = OutputState(number: 1, kind: .record, name: L("show.defaultRecordName"), enabled: false,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: recordDirectory)))
        let state = MixerState(outputs: [record])
        return Show(name: name, state: state)
    }

    /// 空节目，录制目录用本对象的。
    func emptyShow(name: String = L("show.untitled")) -> Show { Self.emptyShow(name: name, recordDirectory: recordDirectory) }

    /// 文件里来的节目：录制 / 推流的 enabled 一律清掉。文档里的"应该在跑"只对 headless 的场景文件有意义；App 里输出只由用户动作（按钮 / 快捷键 / API）起，
    /// 打开一个保存时正在录制 / 推流的节目（含退出时自动存的 LastSession）不能自己开录（G3 2026-09-19 定，W2-B2 报告 §4 第 2 条，契约提案 007 B-1）。
    static func stoppingOutputs(_ show: Show) -> Show {
        var show = show
        for i in show.outputs.indices where show.outputs[i].kind == .record || show.outputs[i].kind == .stream { show.outputs[i].enabled = false }
        return show
    }

    // MARK: 文件

    func load(from url: URL) throws -> Show {
        let show = Self.stoppingOutputs(try store.load(from: url))
        currentURL = url
        noteRecent(url)
        return show
    }

    func save(_ show: Show, to url: URL) throws {
        try store.save(show, to: url)
        currentURL = url
        noteRecent(url)
    }

    /// 新建：忘掉当前文件。
    func startNew() { currentURL = nil }

    /// 素材（图片 / 视频文件）相对路径的基准目录（W3-E5）：节目文件所在目录（与 headless 同一条规则）；节目没保存过 = 默认录制目录 ~/Movies/PlusMix
    /// （录制目录的相对路径也挂在那里，OutputRuntime.startRecordings）。
    var mediaBaseDirectory: URL {
        currentURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: Self.defaultRecordDirectory, isDirectory: true)
    }

    // MARK: 最近 / 上次

    var recentURLs: [URL] {
        (defaults.stringArray(forKey: Self.recentKey) ?? []).compactMap { URL(fileURLWithPath: $0) }
    }

    private func noteRecent(_ url: URL) {
        var list = recentURLs.map(\.path).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        if list.count > Self.recentLimit { list.removeLast(list.count - Self.recentLimit) }
        defaults.set(list, forKey: Self.recentKey)
        defaults.set(url.path, forKey: Self.lastKey)
    }

    func clearRecents() { defaults.removeObject(forKey: Self.recentKey) }

    /// 上次打开 / 保存的文件（文件已不存在则 nil）。
    var lastURL: URL? {
        guard let path = defaults.string(forKey: Self.lastKey), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 退出时未保存的节目自动存到这里，下次启动没有"上次文件"时从这里恢复。
    /// 目录名 "Switcher" 故意没跟 W4-D 改成产品名：hotkeys.json / midi.json / Diagnostics/ 都在 SwitcherControl 的 `UserConfig.directory`
    /// （~/Library/Application Support/Switcher，包内定义、不归 App 改）下，配置目录要一个整体，等包那边改了一起换（reports/w4-rename.md §3）。
    static var autosaveURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Switcher", isDirectory: true).appendingPathComponent("LastSession.\(fileExtension)")
    }

    func autosave(_ show: Show) {
        try? store.save(show, to: Self.autosaveURL)
    }

    func loadAutosave() -> Show? {
        (try? store.load(from: Self.autosaveURL)).map(Self.stoppingOutputs)
    }
}
