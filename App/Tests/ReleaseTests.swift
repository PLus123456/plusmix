// W4-B 发布工程的 App 侧用例（prompt 71 交付 2 / 3）：诊断包、节目文件去密钥、MetricKit 崩溃诊断落盘、更新检查入口。
// 测试 ID R7–R10（脚本侧 R1–R6、R11–R14 在 scripts/release/tests/）。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class ReleaseTests: XCTestCase {
    /// R7：一键导出的诊断包里有日志、stats、去掉密钥的节目、系统信息、崩溃诊断目录；推流密钥和 API token 一个字都不出现。
    /// 注意：App 测试不能写成 async——async 测试体在主队列的 dispatch 块里跑，AppTest.pump 的嵌套 run loop 不会排空主队列（CF 的 libdispatchQSafe），
    /// 引擎启动的 main actor 续体永远回不来（W4-B 撞到，reports/w4-release.md §5）。异步的 build 用 Task + 轮询盒子。
    func testR7_diagnosticBundleContainsRequiredFilesWithoutSecrets() throws {
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
        final class Result { var zip: URL?; var error: (any Error)? }
        let result = Result()
        let controller = AppTest.controller
        Task { @MainActor in
            do { result.zip = try await DiagnosticBundle.build(controller: controller, options: options, destination: dir.appendingPathComponent("diag.zip")) }
            catch { result.error = error }
        }
        XCTAssertTrue(AppTest.waitUntil(120) { result.zip != nil || result.error != nil }, "诊断包 120 s 内没出来")
        if let error = result.error { throw error }
        let zip = try XCTUnwrap(result.zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path), "没有产出 zip")

        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = try AppTest.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        XCTAssertEqual(ditto.code, 0, "ditto 解包失败：\(ditto.stderr)")
        let root = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first { $0.hasDirectoryPath })
        XCTAssertTrue(root.lastPathComponent.hasPrefix("PlusMix-diagnostics-"), "诊断包顶层目录用产品名（W4-D）：\(root.lastPathComponent)")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        for required in ["README.txt", "system.txt", "settings.txt", "stats-latest.jsonl", "show.switcher.json", "log.txt", "crashes", "config"] {
            XCTAssertTrue(names.contains(required), "诊断包缺 \(required)：\(names.sorted())")
        }
        // 密钥一个字都不出现（递归读所有文本文件）
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var scanned = 0
        for file in enumerator.allObjects.compactMap({ $0 as? URL }) {
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

    /// W5-D：url 里的 user:pass@ 与密钥同样打码（整段换成标记，转义过的、没转义的 @ 都算），主机端口路径保留；
    ///     去过密钥的节目仍是合法 Show，账号密码一个字都不出现。
    func testRelease_redactionHidesURLUserinfo() throws {
        let m = ShowRedaction.redactedMarker
        XCTAssertEqual(ShowRedaction.redactURL("rtmp://u:p@live.example.com:1935/app"), "rtmp://\(m)@live.example.com:1935/app")
        XCTAssertEqual(ShowRedaction.redactURL("rtmps://me%40example.com:p%40ss%3Aw@h/app?token=t&x=1"), "rtmps://\(m)@h/app?token=\(m)&x=1")
        XCTAssertEqual(ShowRedaction.redactURL("rtmp://u:p@ss@h/app"), "rtmp://\(m)@h/app", "没转义的 @：按最后一个 @ 分")
        XCTAssertEqual(ShowRedaction.redactURL("rtmp://only-user@h/app"), "rtmp://\(m)@h/app")
        XCTAssertEqual(ShowRedaction.redactURL("rtmp://h/app"), "rtmp://h/app", "没有 userinfo 的不动")

        let user = "Pub-User-5d1e", password = "Pw-Secret-8c3a"
        let show = Show(name: "n", state: MixerState(outputs: [
            OutputState(number: 1, kind: .stream, name: "s", enabled: false,
                        settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                 stream: StreamSettings(url: "rtmp://\(user):\(password)@ingest.example.com:1936/live", streamKey: "k1"))),
        ]))
        let redacted = try ShowRedaction.redact(showData: try show.save())
        let text = String(decoding: redacted, as: UTF8.self)
        XCTAssertFalse(text.contains(user), "用户名泄露了")
        XCTAssertFalse(text.contains(password), "密码泄露了")
        let back = try Show.load(from: redacted)
        XCTAssertEqual(back.outputs[0].settings.stream?.url, "rtmp://\(m)@ingest.example.com:1936/live")
        XCTAssertEqual(back.outputs[0].settings.stream?.streamKey, m)
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

    /// W4-D（prompt 75，用户 2026-09-28 定：产品名 PlusMix，只改用户看得到的名字）：
    /// - 看得到的：Info.plist 的显示名 / 产品名 / 可执行名与用途说明、扩展的显示名（默认值 + 两种语言）、App 菜单标题、主窗口标题、默认录制目录 ~/Movies/PlusMix；
    /// - 不动的：bundle id 仍是 com.plusmix.switcher（发布后不能改）、`SwitcherVersion.current` 仍在且等于 CFBundleShortVersionString、
    ///   project.yml 的工程名 / target / scheme 仍叫 Switcher（Makefile 的 -scheme Switcher 不用改）。
    func testW4D_displayNameIsPlusMix_codeNameUntouched() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "PlusMix", "App/Info.plist 的 CFBundleDisplayName")
        XCTAssertEqual(info["CFBundleName"] as? String, "PlusMix", "PRODUCT_NAME → CFBundleName")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "PlusMix", "可执行名跟 PRODUCT_NAME 走")
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "PlusMix.app")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.plusmix.switcher", "bundle id 是代码名，发布后不能改")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, SwitcherVersion.current, "版本号仍只在 project.yml 与 Version.swift 两处")
        XCTAssertEqual(ProductName.display, "PlusMix")
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"] {
            let text = try XCTUnwrap(info[key] as? String, "缺 \(key)")
            XCTAssertTrue(text.contains("PlusMix"), "\(key) 该用产品名：\(text)")
            XCTAssertFalse(text.contains("Switcher"), "\(key) 不该出现代码名：\(text)")
        }

        // 源文件：project.yml 的 App target 是 PRODUCT_NAME: PlusMix；工程名 / target / scheme / bundle id 原样
        let root = try AppTest.repoRoot()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("PRODUCT_NAME: PlusMix"), "project.yml 的 App target 该是 PRODUCT_NAME: PlusMix")
        XCTAssertTrue(yml.contains("\nname: Switcher\n"), "工程名（代码名）不动")
        XCTAssertTrue(yml.contains("\n  Switcher:\n"), "App target / scheme 名不动")
        XCTAssertTrue(yml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.plusmix.switcher\n"), "bundle id 不动")

        // 扩展：Info.plist 默认值（ASCII）与两种语言的 InfoPlist.strings
        let extInfo = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("CameraExtension/Info.plist")) as? [String: Any])
        XCTAssertEqual(extInfo["CFBundleDisplayName"] as? String, "PlusMix Virtual Camera", "CameraExtension/Info.plist 的默认显示名")
        let en = try String(contentsOf: root.appendingPathComponent("CameraExtension/Resources/en.lproj/InfoPlist.strings"), encoding: .utf8)
        let zh = try String(contentsOf: root.appendingPathComponent("CameraExtension/Resources/zh-Hans.lproj/InfoPlist.strings"), encoding: .utf8)
        XCTAssertTrue(en.contains("\"CFBundleDisplayName\" = \"PlusMix Virtual Camera\";"), "en.lproj/InfoPlist.strings：\(en)")
        XCTAssertTrue(zh.contains("\"CFBundleDisplayName\" = \"PlusMix 虚拟摄像头\";"), "zh-Hans.lproj/InfoPlist.strings：\(zh)")
        // 编进 App 的扩展也带着（Contents/Library/SystemExtensions/<bundle id>.systemextension）
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/com.plusmix.switcher.camera-extension.systemextension")
        if FileManager.default.fileExists(atPath: embedded.path) {
            let embeddedInfo = NSDictionary(contentsOf: embedded.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            XCTAssertEqual(embeddedInfo?["CFBundleDisplayName"] as? String, "PlusMix Virtual Camera")
            XCTAssertEqual(embeddedInfo?["CFBundleIdentifier"] as? String, "com.plusmix.switcher.camera-extension")
            for lang in ["en", "zh-Hans"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: embedded.appendingPathComponent("Contents/Resources/\(lang).lproj/InfoPlist.strings").path),
                              "编进 App 的扩展里缺 \(lang).lproj/InfoPlist.strings")
            }
        } else {
            print("App 包里没有嵌入扩展（\(embedded.path)），跳过嵌入件的检查")
        }

        // 界面：App 菜单标题、主窗口标题、默认录制目录
        let main = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertEqual(main.items.first?.title, "PlusMix", "App 菜单标题")
        let title = try XCTUnwrap(AppTest.controller.windowController.window?.title)
        XCTAssertTrue(title.hasPrefix("PlusMix \(SwitcherVersion.current)"), "主窗口标题：\(title)")
        XCTAssertTrue(ShowDocuments.defaultRecordDirectory.hasSuffix("/Movies/PlusMix"), "默认录制目录 ~/Movies/PlusMix：\(ShowDocuments.defaultRecordDirectory)")
    }
}
