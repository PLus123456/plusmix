// 自动更新（W4-B，Sparkle 2）：只有 Info.plist 里有 SUFeedURL 与 SUPublicEDKey（发布构建由 archive.sh 注入）才起 SPUStandardUpdaterController；
// 开发 / ad-hoc / 测试宿主里两个键为空，不起，菜单与偏好设置里说明"未配置"。更新的下载、校验（EdDSA + 代码签名）、安装都是 Sparkle 自己的界面。
// 本地验证（docs/release/sparkle.md §5）：UserDefaults 的 updateFeedURLOverride 或环境变量 SWITCHER_APPCAST_URL 可以临时指到本地 appcast。
import AppKit
import Sparkle

@MainActor
final class UpdateController: NSObject {
    static let feedOverrideKey = "updateFeedURLOverride"

    /// 两个键都有、且不在测试宿主里。
    let isConfigured: Bool
    let feedURL: String
    private var standard: SPUStandardUpdaterController?
    private let delegateBox: UpdaterDelegate

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard, isTestHost: Bool) {
        let info = bundle.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        feedURL = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isConfigured = !key.isEmpty && !feedURL.isEmpty && !isTestHost
        let override = ProcessInfo.processInfo.environment["SWITCHER_APPCAST_URL"] ?? defaults.string(forKey: Self.feedOverrideKey)
        delegateBox = UpdaterDelegate(feedOverride: override?.isEmpty == false ? override : nil)
        super.init()
        if isConfigured {
            standard = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegateBox, userDriverDelegate: nil)
        }
    }

    var updater: SPUUpdater? { standard?.updater }
    var lastCheckDate: Date? { updater?.lastUpdateCheckDate }
    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// 偏好设置 / 关于里的一句话状态。
    var statusText: String {
        guard isConfigured else { return L("update.status.unconfigured") }
        if let last = lastCheckDate {
            return L("update.status.lastCheck", DateFormatter.localizedString(from: last, dateStyle: .medium, timeStyle: .short))
        }
        return L("update.status.never")
    }

    func checkForUpdates() { standard?.checkForUpdates(nil) }
}

/// SPUUpdaterDelegate 的方法在主线程回调但协议本身 nonisolated，单独放一个不隔离的对象。
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, Sendable {
    let feedOverride: String?
    init(feedOverride: String?) { self.feedOverride = feedOverride }

    /// 本地 appcast 验证时覆盖更新源；平时 nil = 用 Info.plist 的 SUFeedURL。
    func feedURLString(for updater: SPUUpdater) -> String? { feedOverride }
}
