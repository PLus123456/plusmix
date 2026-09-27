// W4-B 发布工程的 App 侧用例（prompt 71 交付 2 / 3）：诊断包、节目文件去密钥、MetricKit 崩溃诊断落盘、更新检查入口。
// 测试 ID R7–R10（脚本侧 R1–R6、R11–R14 在 scripts/release/tests/）。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class ReleaseTests: XCTestCase {
    /// R7：一键导出的诊断包里有日志、stats、去掉密钥的节目、系统信息、崩溃诊断目录；推流密钥和 API token 一个字都不出现。
    func testR7_diagnosticBundleContainsRequiredFilesWithoutSecrets() async throws {
        let session = try AppTest.freshSession()
        let secretKey = "SECRET-STREAM-KEY-7f3a"
        let secretToken = "SECRET-API-TOKEN-91c2"
        let number = (session.state.outputs.map(\.number).max() ?? 0) + 1
        session.send(.addOutput(config: OutputState(number: number, kind: .stream, name: "推流", enabled: false,
                                                    settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                                             stream: StreamSettings(url: "srt://127.0.0.1:9000?streamid=publish:x:user:\(secretKey)&passphrase=\(secretKey)",
                                                                                                    streamKey: secretKey)))))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.outputs.contains { $0.number == number } }, "推流输出没加上")
        var settings = AppTest.controller.settings
        settings.apiToken = secretToken
        AppTest.controller.settings = settings
        AppTest.waitUntil(3) { session.stats != nil }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var options = DiagnosticBundle.Options()
        options.includeCrashLogs = true
        options.systemLogWindowMinutes = 1      // log show 要跑一会儿，测试只取 1 分钟
        let zip = try await DiagnosticBundle.build(controller: AppTest.controller, options: options, destination: dir.appendingPathComponent("diag.zip"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path), "没有产出 zip")

        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = try AppTest.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        XCTAssertEqual(ditto.code, 0, "ditto 解包失败：\(ditto.stderr)")
        let root = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first { $0.hasDirectoryPath })
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        for required in ["README.txt", "system.txt", "settings.txt", "stats-latest.jsonl", "show.switcher.json", "log.txt", "crashes", "config"] {
            XCTAssertTrue(names.contains(required), "诊断包缺 \(required)：\(names.sorted())")
        }
        // 密钥一个字都不出现（递归读所有文本文件）
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var scanned = 0
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            scanned += 1
            XCTAssertFalse(text.contains(secretKey), "\(file.lastPathComponent) 里泄露了推流密钥")
            XCTAssertFalse(text.contains(secretToken), "\(file.lastPathComponent) 里泄露了 API token")
        }
        XCTAssertGreaterThanOrEqual(scanned, 5, "至少扫了 5 个文本文件")
        // 节目文件仍是合法的 Show，推流输出还在、密钥被换成标记
        let show = try Show.load(from: try Data(contentsOf: root.appendingPathComponent("show.switcher.json")))
        let stream = try XCTUnwrap(show.outputs.first { $0.kind == .stream })
        XCTAssertEqual(stream.settings.stream?.streamKey, ShowRedaction.redactedMarker)
        XCTAssertTrue(stream.settings.stream?.url.contains("127.0.0.1:9000") == true, "主机端口要保留，方便排障：\(stream.settings.stream?.url ?? "")")
        // 系统信息里有版本、机型、系统版本
        let system = try String(contentsOf: root.appendingPathComponent("system.txt"), encoding: .utf8)
        for key in ["app_version", "bundle_id", "macos", "model", "chip_or_cpu", "memory_gb", "gpu"] { XCTAssertTrue(system.contains(key), "system.txt 缺 \(key)") }
        // stats-latest 是一行合法 JSON，字段与 stats.jsonl 同一套（铁律 4）
        let statsLine = try String(contentsOf: root.appendingPathComponent("stats-latest.jsonl"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(statsLine.utf8)), "stats-latest.jsonl 不是 JSON：\(statsLine.prefix(80))")
        try? FileManager.default.removeItem(at: dir)
    }

    /// R8：节目 JSON 去密钥：streamKey 换成标记；url 里 passphrase / key / token / password / streamid 的值换成标记，主机端口路径保留；
    ///     其他字段原样；不是 JSON 对象的输入原样返回（不抛）。
    func testR8_showRedactionStripsStreamKeyAndURLSecrets() throws {
        let m = ShowRedaction.redactedMarker
        XCTAssertEqual(ShowRedaction.redactURL("srt://host:9000?passphrase=abc&latency=120"), "srt://host:9000?passphrase=\(m)&latency=120")
        XCTAssertEqual(ShowRedaction.redactURL("rtmp://a.example/live"), "rtmp://a.example/live")
        XCTAssertEqual(ShowRedaction.redactURL("srt://h:1?streamid=publish:path:user:pw"), "srt://h:1?streamid=\(m)")
        XCTAssertEqual(ShowRedaction.redactURL("rtmps://h/app?token=t&KEY=k"), "rtmps://h/app?token=\(m)&KEY=\(m)")
        XCTAssertEqual(ShowRedaction.redactURL("not a url"), "not a url")

        let show = Show(name: "n", state: MixerState(outputs: [
            OutputState(number: 1, kind: .stream, name: "s", enabled: false,
                        settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                 stream: StreamSettings(url: "srt://h:1?passphrase=p", streamKey: "k1", reconnectMaxSeconds: 12))),
        ]))
        let data = try show.save()
        let redacted = try ShowRedaction.redact(showData: data)
        let back = try Show.load(from: redacted)
        XCTAssertEqual(back.outputs[0].settings.stream?.streamKey, m)
        XCTAssertEqual(back.outputs[0].settings.stream?.url, "srt://h:1?passphrase=\(m)")
        XCTAssertEqual(back.outputs[0].settings.stream?.reconnectMaxSeconds, 12, "其他字段原样")
        XCTAssertEqual(back.name, "n")
        // 去过密钥的字符串里没有原文
        let text = String(decoding: redacted, as: UTF8.self)
        XCTAssertFalse(text.contains("\"k1\""))
        XCTAssertFalse(text.contains("passphrase=p"))
        // 空 streamKey 不动（避免把"没设"变成"有值"）
        let plain = Show(name: "p", state: MixerState(outputs: [
            OutputState(number: 1, kind: .stream, name: "s", enabled: false,
                        settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(), stream: StreamSettings(url: "rtmp://h/x"))),
        ]))
        let plainBack = try Show.load(from: try ShowRedaction.redact(showData: try plain.save()))
        XCTAssertEqual(plainBack.outputs[0].settings.stream?.streamKey, "")
    }

    /// R9：MetricKit 崩溃诊断落盘：store 按时间命名写 JSON、列表按时间排序、prune 只留最近 N 份；订阅者起得来（测试宿主里 MXMetricManager 也能 add）。
    func testR9_crashDiagnosticsStoreWritesListsAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/crash-\(UUID().uuidString)", isDirectory: true)
        let store = CrashDiagnosticsStore(directory: dir)
        XCTAssertEqual(store.entries().count, 0)
        var urls: [URL] = []
        for i in 0..<5 {
            let json = Data(#"{"crashDiagnostics":[{"i":\#(i)}]}"#.utf8)
            urls.append(try store.store(json: json, kind: "crash", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)))
        }
        XCTAssertEqual(Set(urls.map(\.pathExtension)), ["json"])
        XCTAssertEqual(store.entries().map(\.lastPathComponent), urls.map(\.lastPathComponent), "列表按时间升序")
        XCTAssertTrue(urls[0].lastPathComponent.hasPrefix("crash-"), "文件名带类别：\(urls[0].lastPathComponent)")
        XCTAssertEqual(try Data(contentsOf: urls[2]), Data(#"{"crashDiagnostics":[{"i":2}]}"#.utf8))
        store.prune(keepLast: 3)
        XCTAssertEqual(store.entries().map(\.lastPathComponent), urls.suffix(3).map(\.lastPathComponent), "prune 留最近 3 份")
        XCTAssertEqual(store.summaryLines().count, 3)
        // 订阅者
        let diagnostics = CrashDiagnostics(store: store)
        diagnostics.start()
        XCTAssertTrue(diagnostics.isSubscribed)
        diagnostics.stop()
        XCTAssertFalse(diagnostics.isSubscribed)
        try? FileManager.default.removeItem(at: dir)
    }

    /// R10：更新检查入口：测试宿主里 Info.plist 没有公钥 → 不起 Sparkle、状态文案说明"未配置"；App 菜单有"检查更新…"，帮助菜单有"导出诊断包…"；
    ///      偏好设置的更新一节不再是占位文案。
    func testR10_updateEntryPointsPresentAndUnconfiguredWithoutKey() throws {
        let delegate = AppTest.delegate
        let updater = delegate.updateController
        XCTAssertFalse(updater.isConfigured, "测试宿主 / ad-hoc 构建没有 SUPublicEDKey，不该算已配置")
        XCTAssertEqual(updater.statusText, L("update.status.unconfigured"))
        XCTAssertNil(updater.lastCheckDate)
        let main = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(main.items.first?.submenu)
        let check = appMenu.items.first { $0.title == L("menu.checkForUpdates") }
        XCTAssertNotNil(check, "App 菜单缺“检查更新…”")
        XCTAssertEqual(check?.action, #selector(AppDelegate.checkForUpdates(_:)))
        let help = try XCTUnwrap(main.items.first { $0.title == L("menu.help") }?.submenu, "缺帮助菜单")
        XCTAssertNotNil(help.items.first { $0.title == L("menu.help.exportDiagnostics") }, "帮助菜单缺“导出诊断包…”")
        XCTAssertNotNil(help.items.first { $0.title == L("menu.help.showDiagnosticsFolder") }, "帮助菜单缺“打开诊断文件夹”")
        XCTAssertNotEqual(L("prefs.update.pending"), "自动更新由 W4-B 接 Sparkle；这里先留位置。", "占位文案该换掉了")
    }
}
