// MetricKit 崩溃诊断落盘（W4-B，后续方案 §8.1 最小版）：订阅 MXMetricManager，收到的诊断负载（崩溃 / 卡死 / CPU / 磁盘）按 JSON 原样写到
// ~/Library/Application Support/Switcher/Diagnostics/<类别>-<时间>.json；启动时把系统攒着的历史负载（pastDiagnosticPayloads）也收进来。
// 只落本地、不上传；导出走诊断包（DiagnosticBundle），导出前用户在对话框里选是否包含——这就是"用户同意后导出"。
// 崩溃负载是下次启动时系统才交付的（MetricKit 的机制），所以 App 一起来就订阅。
import Foundation
import MetricKit
import SwitcherControl

/// 诊断文件的目录与读写。文件名 `<kind>-yyyyMMdd-HHmmss[-n].json`，按名字排序就是按时间。
final class CrashDiagnosticsStore: @unchecked Sendable {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// 默认目录：用户配置目录下的 Diagnostics/。
    static var defaultDirectory: URL { UserConfig.directory.appending(path: "Diagnostics") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 写一份负载；同一秒撞名就加 -2、-3。返回写到哪。
    @discardableResult
    func store(json: Data, kind: String, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "\(kind)-\(Self.stamp.string(from: date))"
        var url = directory.appending(path: "\(base).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(base)-\(n).json")
            n += 1
        }
        try json.write(to: url, options: .atomic)
        return url
    }

    /// 全部诊断文件，按名字（= 时间）升序。
    func entries() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 只留最近 keepLast 份。
    func prune(keepLast: Int) {
        let all = entries()
        guard all.count > keepLast else { return }
        for url in all.prefix(all.count - keepLast) { try? FileManager.default.removeItem(at: url) }
    }

    /// 给人看的一行一份："crash-20231114-221320.json  1.2 KB"。
    func summaryLines() -> [String] {
        entries().map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(url.lastPathComponent)  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
    }
}

/// MetricKit 订阅者。系统在后台线程回调，只做文件写。
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnostics(store: CrashDiagnosticsStore(directory: CrashDiagnosticsStore.defaultDirectory))
    static let keepLast = 100

    let store: CrashDiagnosticsStore
    private let lock = NSLock()
    private var subscribed = false
    private var received = 0

    init(store: CrashDiagnosticsStore) {
        self.store = store
        super.init()
    }

    var isSubscribed: Bool { lock.withLock { subscribed } }
    /// 本次进程收到的负载数（测试 / 诊断包里的说明）。
    var receivedPayloads: Int { lock.withLock { received } }

    /// 订阅，并把系统攒着的历史诊断收进来（去重靠文件名 = 负载结束时间）。
    func start() {
        let already = lock.withLock { () -> Bool in
            if subscribed { return true }
            subscribed = true
            return false
        }
        guard !already else { return }
        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { save(past) }
    }

    func stop() {
        let was = lock.withLock { () -> Bool in
            let w = subscribed
            subscribed = false
            return w
        }
        if was { MXMetricManager.shared.remove(self) }
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    /// 性能负载（MXMetricPayload）不存：最小版只要崩溃诊断。
    func didReceive(_ payloads: [MXMetricPayload]) {}

    private func save(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let kind: String
            if let c = payload.crashDiagnostics, !c.isEmpty { kind = "crash" }
            else if let h = payload.hangDiagnostics, !h.isEmpty { kind = "hang" }
            else if let c = payload.cpuExceptionDiagnostics, !c.isEmpty { kind = "cpu" }
            else if let d = payload.diskWriteExceptionDiagnostics, !d.isEmpty { kind = "disk" }
            else { kind = "diagnostic" }
            // 同一负载重复交付（历史 + 实时）时文件名相同：已存在就跳过
            let name = "\(kind)-\(CrashDiagnosticsStoreStamp.string(payload.timeStampEnd)).json"
            if FileManager.default.fileExists(atPath: store.directory.appending(path: name).path) { continue }
            do {
                try store.store(json: payload.jsonRepresentation(), kind: kind, date: payload.timeStampEnd)
                lock.withLock { received += 1 }
            } catch {
                NSLog("崩溃诊断写不进 \(store.directory.path)：\(error)")
            }
        }
        store.prune(keepLast: Self.keepLast)
    }
}

/// 与 CrashDiagnosticsStore 同一个时间戳格式（去重用）。
enum CrashDiagnosticsStoreStamp {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
