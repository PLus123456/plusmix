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
    /// 当前节目对应的文件；未保存过为 nil。
    private(set) var currentURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 空节目：没有输入，带一个默认录制输出（录到 ~/Movies/Switcher），PGM / PVW 都是黑场。
    static func emptyShow(name: String = "未命名") -> Show {
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Switcher").path ?? NSHomeDirectory()
        let record = OutputState(number: 1, kind: .record, name: "录制", enabled: false,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          record: RecordSettings(directory: directory)))
        let state = MixerState(outputs: [record])
        return Show(name: name, state: state)
    }

    // MARK: 文件

    func load(from url: URL) throws -> Show {
        let show = try store.load(from: url)
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
    static var autosaveURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Switcher", isDirectory: true).appendingPathComponent("LastSession.\(fileExtension)")
    }

    func autosave(_ show: Show) {
        try? store.save(show, to: Self.autosaveURL)
    }

    func loadAutosave() -> Show? {
        try? store.load(from: Self.autosaveURL)
    }
}
