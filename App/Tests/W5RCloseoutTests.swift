// W5-R（prompt 130）App 收口二：Codex 2026-10-22 全仓审查与 10-24 网络安全审计里归 App 的四条（G11 排进 128 前）。
// N04 录制磁盘下限 MB → 字节换算溢出：defaults / 启动参数 / 设置窗 / 设置导入都钳到 AppSettings.maxRecordMinimumFreeMB，字节只在 recordMinimumFreeBytes 一处算；
// N06 ISO 切备用目录：旧录制器封口时把它的分支还给那一路；这一路分支开不到（4 个占满）就不切、停这一路并提示，绝不退成 PGM 录制器 + Master 音频；
// N07 纯音频输入的 ISO：开分支时往分支里推一帧黑，tap 每拍重复它 → 黑画面 + 本路声音；ISO 行副标题写明"画面为黑"；
// NS08 远程控制页允许局域网时提醒令牌和全部状态走明文（有没有 token 都提醒）。
// N06 两条与 N07 一条从 Codex 的红用例搬来（reports/codex-bug-audit-20261022-tests/ 的 testS7_ISOFallback… 两条与
// testAudioOnlyISOSelectedInSettingsMustProduceRecording）：DiskMonitor.onEvent 注入、独立临时目录、合成 PCM 工厂照旧；满额那条按本路的修法
// 改成"不切 + 提示"（原断言要求切过去且仍是 ISO，开不到分支时做不到）。
import AppKit
import AVFoundation
import XCTest
import SwitcherContracts
import SwitcherAudio
import SwitcherEngine
import SwitcherISO
import SwitcherInputs
import SwitcherTestKit
@testable import Switcher

/// 纯音频输入的替身：合成 PCM 写进 CAudioRing，videoSlot 恒为 nil、从不往帧槽推（同 AudioDeviceInput），不要麦克风权限（Codex 的 AO02 探针）。
private struct W5RAudioOnlyFactory: InputFactory {
    func makeInput(config: InputConfig, slot: any FrameSlot, timing: ProgramTiming) throws -> MadeInput {
        guard case .audio = config.source else {
            return try DefaultInputFactory().makeInput(config: config, slot: slot, timing: timing)
        }
        let ring = CAudioRing(channelCount: 2)
        let source = SyntheticAudioInput(number: config.number, name: config.name, frameRate: timing.format.frameRate,
                                         audioRing: ring, timeline: SyntheticTimeline(t0: timing.clock.t0, frameRate: timing.format.frameRate))
        return MadeInput(input: source, audioRing: ring, audioBlockFrames: source.blockFrames)
    }
}

@MainActor
final class W5RCloseoutTests: XCTestCase {
    /// 16 TiB（= 2^24 MB）：换算成字节 2^44，离 UInt64 的上限远着；溢出点是 2^44 MB。
    private static let limitMB = 16_777_216

    /// 自己起的 session 用的设置：不出声、不起 API / 兼容层 / tally、不防睡眠（不碰宿主那一个）。
    private static func isolatedSettings(_ base: AppSettings = AppSettings()) -> AppSettings {
        var s = base
        s.audioDevice = .null
        s.apiEnabled = false
        s.compatLayerEnabled = false
        s.tallyEnabled = false
        s.preventSleepWhileRunning = false
        s.preventDisplaySleepWhileRunning = false
        return s
    }

    // MARK: N04 录制磁盘下限

    /// N04：defaults 里存着 2^44 − 1 / 2^44 / Int.max MB（上一次在设置窗填超了、commitSettings 先落盘再崩；或手改 defaults）——读回来钳到上限，
    /// 建 session 不 trap，下限字节 = 上限 × 1 MiB。启动参数同一条路。
    func testN04_hugeMinimumFreeFromDefaultsClampsAndSessionBuilds() throws {
        _ = try AppTest.runningSession()
        let suite = "com.plusmix.tests.w5r-n04-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in [17_592_186_044_415, 17_592_186_044_416, Int.max] {
            defaults.set(value, forKey: AppSettings.Keys.recordMinimumFreeMB)
            let loaded = AppSettings.load(arguments: [], defaults: defaults)
            XCTAssertEqual(loaded.recordMinimumFreeMB, Self.limitMB, "defaults 里的 \(value) MB 读回来钳到上限")
            let session = try SwitcherSession(show: ShowDocuments.emptyShow(name: "w5r-n04"), settings: Self.isolatedSettings(loaded),
                                              hotkeyTable: .init(bindings: []), midiTable: .init(mappings: []))
            XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576, "\(value) MB：建 session 不 trap，字节 = 上限 × 1 MiB")
        }
        let cli = AppSettings.load(arguments: ["--record-min-free-mb", "\(Int.max)"], defaults: defaults)
        XCTAssertEqual(cli.recordMinimumFreeMB, Self.limitMB, "--record-min-free-mb 同样钳")
        defaults.set(-5, forKey: AppSettings.Keys.recordMinimumFreeMB)
        XCTAssertEqual(AppSettings.load(arguments: [], defaults: defaults).recordMinimumFreeMB, 0, "负数照旧按 0")
    }

    /// N04：设置 › 高级的数字框填 2^44（UI 的格式能解析）——失焦提交时钳到上限：框里显示钳后的值、内存 / 落盘 / 跑着的引擎都是钳后的值，不 trap。
    func testN04_settingsFieldClampsHugeValueAndShowsClampedValue() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let panels = controller.panels
        let original = controller.settings
        defer {
            panels.closeAll()
            controller.updateSettings(original)
        }
        panels.showSettings(page: .advanced)
        let settingsWindow = try XCTUnwrap(panels.settingsWindow)
        let prefs = settingsWindow.model.preferences
        let window = try XCTUnwrap(settingsWindow.window)
        prefs.recordMinimumFreeMB = 4321   // 认得出是哪个框
        var found: NSTextField?
        XCTAssertTrue(AppTest.waitUntil(3) {
            found = AppTest.descendants(of: window.contentView!, as: NSTextField.self) { $0.isEditable && $0.stringValue == "4321" }.first
            return found != nil
        }, "高级页的磁盘下限框")
        let field = try XCTUnwrap(found)
        window.makeKeyAndOrderFront(nil)
        func type(_ text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil)   // 失焦 = 提交
            AppTest.pump(seconds: 0.2)
        }
        try type("17592186044416")
        XCTAssertTrue(AppTest.waitUntil(2) { prefs.recordMinimumFreeMB == Self.limitMB }, "提交的是钳后的值：\(prefs.recordMinimumFreeMB)")
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        XCTAssertEqual(controller.defaults.integer(forKey: AppSettings.Keys.recordMinimumFreeMB), Self.limitMB, "落盘的也是钳后的值（下次启动不再崩）")
        XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576)
        XCTAssertTrue(AppTest.waitUntil(2) { field.stringValue == "\(Self.limitMB)" }, "框里显示钳后的值：\(field.stringValue)")
        // 已经是上限时再填超的（值没变）、填一串比 Int 还长的数字：框里照样回到钳后的值
        try type("17592186044416")
        XCTAssertTrue(AppTest.waitUntil(2) { field.stringValue == "\(Self.limitMB)" }, "再填一次超的：\(field.stringValue)")
        try type("99999999999999999999999")
        XCTAssertTrue(AppTest.waitUntil(2) { field.stringValue == "\(Self.limitMB)" }, "比 Int 还长：\(field.stringValue)")
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        try type("750")
        XCTAssertTrue(AppTest.waitUntil(2) { controller.settings.recordMinimumFreeMB == 750 }, "范围里的照常")
        XCTAssertEqual(session.outputs.minimumFreeBytes, 750 * 1_048_576)
        // 模型直接写（导入 / 恢复之后的重读也走这里）同样钳
        prefs.recordMinimumFreeMB = Int.max
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576)
    }

    /// N04：设置导入的包里带着 Int.max MB（别的机器手改过 / 旧版本存下的）——导进来钳到上限，跑着的引擎不 trap。
    func testN04_importedSettingsPackageClampsMinimumFree() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let original = controller.settings
        let saved = SettingsTransfer.makePackage(controller: controller)
        defer { try? SettingsTransfer.apply(saved, controller: controller); controller.updateSettings(original) }
        var package = saved
        package.defaults[AppSettings.Keys.recordMinimumFreeMB] = .int(Int.max)
        try SettingsTransfer.apply(package, controller: controller)
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        XCTAssertEqual(controller.defaults.integer(forKey: AppSettings.Keys.recordMinimumFreeMB), Self.limitMB, "导进来落盘的是钳后的值")
        XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576)
    }

    // MARK: N06 ISO 切备用目录

    /// 录 input2 的 ISO（PGM = input1），主目录与备用目录都在独立临时目录下；下限设 0（不让真的磁盘事件插进来），事件靠 DiskMonitor.onEvent 注入。
    private func startISOOnInput2() throws -> (session: SwitcherSession, number: Int, base: URL) {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-w5r-n06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let input = try XCTUnwrap(session.state.input(2))
        var output = ISORoutes.makeISOOutput(for: input, in: session.state, defaultDirectory: base.path)
        output.settings.record?.directory = base.appendingPathComponent("primary").path
        output.settings.record?.ownFormat = true
        session.outputs.minimumFreeBytes = 0
        session.outputs.fallbackDirectory = base.appendingPathComponent("fallback").path
        session.send(.addOutput(config: output))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(output.number) != nil })
        session.send(.startRecord(output: output.number))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[output.number] != nil })
        let tap = try XCTUnwrap(session.outputs.recorders[output.number]?.consumer as? ISOFrameTap)
        XCTAssertTrue(AppTest.waitUntil(3) { tap.counters.forwarded > 30 })
        return (session, output.number, base)
    }

    /// N06：切备用目录时旧录制器封口要还它的分支（finishRecording 那条路一直有，切备用目录这条漏了）——切完分支数回到切之前，停了以后是 0。
    func testN06_isoFallbackReleasesOldBranch() throws {
        let (session, number, base) = try startISOOnInput2()
        defer { try? FileManager.default.removeItem(at: base) }
        let tee = try XCTUnwrap(session.inputs.entries[2]?.tee)
        XCTAssertEqual(tee.branchCount, 1)
        let before = try XCTUnwrap(session.outputs.recorders[number])
        session.outputs.diskMonitor.onEvent?(number, .belowMinimum(freeBytes: 0))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[number].map { $0 !== before && $0.onFallback } ?? false }, "切到备用目录")
        let after = try XCTUnwrap(session.outputs.recorders[number])
        XCTAssertTrue(after.consumer is ISOFrameTap, "仍是输入 2 的 ISO")
        XCTAssertNotNil(after.branch)
        XCTAssertTrue(after.url.path.hasPrefix(base.appendingPathComponent("fallback").path), after.url.path)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.lastResults[number]?.url == before.url }, "旧文件在边界拍封口")
        XCTAssertTrue(AppTest.waitUntil(2) { tee.branchCount == 1 }, "旧录制器封口后分支数回到切之前（1）：\(tee.branchCount)")
        AppTest.pump(seconds: 0.5)
        session.send(.stopRecord(output: number))
        XCTAssertTrue(AppTest.waitUntil(10) { session.outputs.recorders[number] == nil })
        AppTest.pump(seconds: 0.5)
        print("W5R N06 切备用目录：停后 branchCount=\(tee.branchCount)，retired=\(tee.retiredCount)")
        XCTAssertEqual(tee.branchCount, 0, "停了以后新旧两个分支都还了")
    }

    /// N06：这一路 4 个分支都占着（ISO 自己 1 个 + 别的 3 个）时切备用目录开不到新分支——不切：停这一路（快照 enabled 回 false）、提示"分支满了，没有切"，
    /// 原来的文件照常封口；运行表里从不出现普通录制器 / 分支为 nil 的项（原来退成 PGM 录制器 + Master 音频，配置还写着 input 2，没提示）。
    func testN06_isoFallbackWithBranchesFullStopsInsteadOfRecordingProgram() throws {
        let (session, number, base) = try startISOOnInput2()
        defer { try? FileManager.default.removeItem(at: base) }
        var notices: [String] = []
        let token = session.observeNotices { notices.append($0) }
        defer { token.invalidate() }
        let extra = try (0..<3).map { _ in try XCTUnwrap(session.inputs.openBranch(input: 2)) }
        defer { for branch in extra { session.inputs.releaseBranch(branch, input: 2) } }
        let tee = try XCTUnwrap(session.inputs.entries[2]?.tee)
        XCTAssertEqual(tee.branchCount, 4)
        let before = try XCTUnwrap(session.outputs.recorders[number])
        session.outputs.diskMonitor.onEvent?(number, .belowMinimum(freeBytes: 0))
        var substituted: [String] = []
        let stopped = AppTest.waitUntil(8) {
            if let e = session.outputs.recorders[number], e !== before {
                substituted.append("consumer=\(type(of: e.consumer)) branchNil=\(e.branch == nil) url=\(e.url.lastPathComponent)")
            }
            return session.outputs.recorders[number] == nil && session.state.output(number)?.enabled == false
        }
        print("W5R N06 分支满：替换=\(substituted.first ?? "无")，提示 \(notices)")
        XCTAssertTrue(substituted.isEmpty, "输入 2 的 ISO 不能悄悄换成别的录制器：\(substituted.first ?? "")")
        XCTAssertTrue(stopped, "开不到分支：停这一路、快照的 enabled 回 false")
        XCTAssertTrue(notices.contains { $0.contains("备用目录") && $0.contains("分支满了") && $0.contains("没有切") }, "提示为什么没切：\(notices)")
        XCTAssertEqual(session.outputs.lastResults[number]?.url, before.url, "原来那个文件照常封口")
        let fallbackFiles = (try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("fallback").path)) ?? []
        XCTAssertTrue(fallbackFiles.isEmpty, "备用目录里没有新文件：\(fallbackFiles)")
        XCTAssertTrue(AppTest.waitUntil(2) { tee.branchCount == 3 }, "ISO 自己那个分支还了，剩下用例占的 3 个：\(tee.branchCount)")
    }

    // MARK: N07 纯音频输入的 ISO

    /// N07（Codex AO02 的宿主用例）：勾"显示全部输入"后给纯音频输入勾 ISO、录 2 s——要有文件：黑画面（开分支时推的那一帧，tap 每拍重复）+ 本路声音。
    /// 原来 AudioDeviceInput 没有 videoSlot、空分支没人推帧，tap 每拍 noFrame，Recorder 从没建 writer，停止时"没有写入任何视频帧"。
    func testN07_audioOnlyISO_recordsBlackVideoWithAudio() throws {
        _ = try AppTest.runningSession()   // 别跟宿主起它自己那个 session 抢
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-w5r-n07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var show = ShowDocuments.emptyShow(name: "w5r-n07-audio-iso", recordDirectory: directory.path)
        show.mixer.format = ProgramFormat(width: 320, height: 240, frameRate: .fps30)
        show.inputs = [InputConfig(number: 1, name: "话筒", source: .audio(deviceUID: "w5r-synthetic-audio"))]
        show.outputs = []   // 只录 ISO 页上勾的那一路
        show.mixer.program = 1
        var settings = Self.isolatedSettings()
        settings.recordMinimumFreeMB = 0
        let session = try SwitcherSession(show: show, settings: settings, inputFactory: W5RAudioOnlyFactory(),
                                          hotkeyTable: .init(bindings: []), midiTable: .init(mappings: []))
        defer {
            let stopped = AppTest.expectationBox()
            Task { await session.stop(); stopped.value = true }
            let didStop = AppTest.waitUntil(20) { stopped.value }
            XCTAssertTrue(didStop, "session 收得掉")
            if didStop { try? FileManager.default.removeItem(at: directory) }
        }
        final class StartOutcome { var done = false; var error: (any Error)? }
        let started = StartOutcome()
        Task {
            do { try await session.start() } catch { started.error = error }
            started.done = true
        }
        XCTAssertTrue(AppTest.waitUntil(20) { started.done }, "session 起得来")
        if let error = started.error { throw error }
        XCTAssertTrue(AppTest.waitUntil(5) { session.inputs.runtimeState(of: 1) == .live && session.audio.registeredInputs.contains(1) })
        let source = try XCTUnwrap(session.inputs.entries[1]?.input as? SyntheticAudioInput)
        XCTAssertNil(source.videoSlot, "替身是纯音频")
        XCTAssertTrue(AppTest.waitUntil(5) {
            source.counters.framesWritten > 48_000 && session.audio.status.inputs.first(where: { $0.number == 1 })?.primed == true
        }, "混音器收到这一路的声音")

        // 与界面同一条路：ISO 页勾"显示全部输入"→ 勾这一路
        let model = OutputSettingsModel(state: session.state, tab: .iso, defaultRecordDirectory: directory.path,
                                        showName: show.name, queriesSystemExtensions: false)
        model.send = { [weak session] command in session?.send(command) }
        XCTAssertFalse(model.isoRows.contains { $0.input == 1 }, "纯音频默认收起")
        model.isoShowAllInputs = true
        let row = try XCTUnwrap(model.isoRows.first { $0.input == 1 })
        model.setISORow(row.id, on: true)
        XCTAssertTrue(AppTest.waitUntil(3) { ISORoutes.isoRecord(in: session.state, input: 1) != nil })
        let iso = try XCTUnwrap(ISORoutes.isoRecord(in: session.state, input: 1))
        session.send(.startRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[iso.number] != nil })
        let entry = try XCTUnwrap(session.outputs.recorders[iso.number])
        let tap = try XCTUnwrap(entry.consumer as? ISOFrameTap)
        XCTAssertNotNil(entry.audio?.token, "ISO 音轨挂在这一路上")
        AppTest.pump(seconds: 2)
        let counters = tap.counters
        session.send(.stopRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(15) { session.state.output(iso.number)?.enabled == false && session.outputs.recorders[iso.number] == nil })
        print("W5R N07 纯音频 ISO：forwarded=\(counters.forwarded) repeated=\(counters.repeated) noFrame=\(counters.noFrame)，"
              + "录制器 \(entry.recorder.state) / \(entry.recorder.counters.lastError)，结果 \(session.outputs.lastResults[iso.number].map { "\($0.videoFrames) 帧 / \($0.audioFrames) 音频帧 / \($0.durationSeconds) s" } ?? "nil")")
        XCTAssertGreaterThan(counters.forwarded, 30, "tap 每拍交出那一帧黑")
        XCTAssertGreaterThan(counters.repeated, 30, "同一帧黑每拍重复（repeated 记账）")
        let result = try XCTUnwrap(session.outputs.lastResults[iso.number], "纯音频输入的 ISO 停了要有录像")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path), "文件在")
        XCTAssertGreaterThan(result.audioFrames, 0, "有这一路的声音")
        XCTAssertEqual(Int(result.videoFrames), Int(result.stopTick.rawValue - result.start.tick.rawValue), "每拍一帧，没有洞")
        XCTAssertEqual(result.durationSeconds, 2, accuracy: 0.6, "≈ 录的 2 s × 30 fps")
        let luma = try XCTUnwrap(Self.meanLuma(of: result.url, at: 1), "读得出第 1 秒的画面")
        XCTAssertLessThan(luma, 0.05, "画面是黑的：平均亮度 \(luma)")
    }

    /// N07：ISO 表里纯音频输入那一行写明录出来是黑画面（副标题；视频输入没有）。
    func testN07_isoRowForAudioOnlyInputSaysBlackPicture() {
        var state = MixerState()
        state.inputs = [InputConfig(number: 1, name: "话筒", source: .audio(deviceUID: "")),
                        InputConfig(number: 2, name: "机位", source: .synthetic(settings: SyntheticSourceSettings()))]
        let model = OutputSettingsModel(state: state, tab: .iso, defaultRecordDirectory: NSTemporaryDirectory(), showName: "w5r", queriesSystemExtensions: false)
        model.isoShowAllInputs = true
        XCTAssertEqual(model.isoRows.first { $0.input == 1 }?.subtitle, "纯音频：画面为黑")
        XCTAssertNil(model.isoRows.first { $0.input == 2 }?.subtitle)
        XCTAssertEqual(L10n.string("outputSettings.iso.audioOnlyHint", language: "en"), "Audio only: the picture is black")
    }

    /// 录像里第 `seconds` 秒那一帧的平均亮度（0…1）。
    private static func meanLuma(of url: URL, at seconds: Double) -> Double? {
        var result: Double?
        var done = false
        Task { @MainActor in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                let width = image.width, height = image.height
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                    guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return true
                }
                if drawn {
                    var sum = 0.0
                    for i in stride(from: 0, to: pixels.count, by: 4) {
                        sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
                    }
                    result = sum / Double(width * height) / 255
                }
            }
            done = true
        }
        AppTest.waitUntil(10) { done }
        return result
    }

    // MARK: NS08 局域网明文

    /// NS08（网络安全审计 [8]）：允许局域网时，令牌（ws://…?token=）和全部状态都是明文 HTTP / WebSocket——有没有 token 都提醒一句；仅本机不提醒。
    func testNS08_lanScopeWarnsCleartextWithOrWithoutToken() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let defaults = controller.defaults
        let keys = [AppSettings.Keys.apiEnabled, AppSettings.Keys.apiListen, AppSettings.Keys.apiToken]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let savedSettings = controller.settings
        addTeardownBlock { @MainActor in
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            AppTest.controller.settings = savedSettings
            AppTest.controller.panels.closeAll()
        }
        let m = controller.panels.showPreferences().model
        let cleartext = "令牌和全部状态走明文 HTTP / WebSocket（没有 TLS），只在可信局域网里开。"
        m.apiEnabled = true
        XCTAssertEqual(m.apiScope, .localOnly)
        XCTAssertNil(m.apiCleartextWarning, "仅本机不提醒")
        m.apiPort = 18765
        m.apiToken = "secret"
        m.apiScope = .lan
        XCTAssertNil(m.apiWarning, "设了 token：不再说没设 token")
        XCTAssertEqual(m.apiCleartextWarning, cleartext, "设了 token 也提醒明文")
        m.apiToken = ""
        XCTAssertNotNil(m.apiWarning, "没设 token 的那句照旧")
        XCTAssertEqual(m.apiCleartextWarning, cleartext)
        m.apiEnabled = false
        XCTAssertNil(m.apiCleartextWarning, "API 关着不提醒")
        m.apiEnabled = true
        m.apiScope = .localOnly
        XCTAssertNil(m.apiCleartextWarning)
        XCTAssertEqual(L10n.string("prefs.remote.cleartextWarning", language: "en"),
                       "The token and the whole state travel as plain HTTP / WebSocket (no TLS): only allow the local network on a network you trust.")
    }
}
