// W5-P（prompt 119）App 止血的补充用例：Codex 四条（DebugAuditTests）之外，prompt 点名要的几种情形——
// K01 固定模板连录两次得两个文件、转封装 MP4 同名、分配层的单元口径；D04 读不出来的打开不改保存目标、排在打开后面的重起接手刚打开的节目；
// D06 换源前后 ISO 录像不断、拍点连续、换到没画面的来源画黑；D07 换源重试的代次（可控计钟替身）；D16 LastSession 相对素材落成绝对。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherISO
import SwitcherAudio
import SwitcherOutputs
@testable import Switcher

@MainActor
final class W5PFixesTests: XCTestCase {
    // MARK: K01 开录不覆盖旧录像

    private func temporaryDirectory(_ tag: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-w5p-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 录制 1 改成录到 directory、模板 pattern（可选转封装），等快照跟上。
    private func pointRecord(_ session: SwitcherSession, to directory: URL, pattern: String, remux: Bool = false) throws {
        var settings = try XCTUnwrap(session.state.output(1)).settings
        settings.record?.directory = directory.path
        settings.record?.fileNamePattern = pattern
        settings.record?.remuxToMP4 = remux
        session.send(.setOutputSettings(output: 1, settings: settings))
        XCTAssertTrue(AppTest.waitUntil(3) {
            session.state.output(1)?.settings.record?.directory == directory.path && session.state.output(1)?.settings.record?.remuxToMP4 == remux
        })
    }

    /// 开录一次、录 seconds 秒、停，返回这一次的结果（封口完成）。
    private func recordOnce(_ session: SwitcherSession, seconds: Double) throws -> RecordingResult {
        let before = session.outputs.lastResults[1]
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil }, "录制器应起来")
        AppTest.pump(seconds: seconds)
        session.send(.stopRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(15) { session.outputs.recorders[1] == nil && session.outputs.lastResults[1].map { $0.url != before?.url || before == nil } == true },
                      "封口应完成")
        return try XCTUnwrap(session.outputs.lastResults[1])
    }

    /// 固定模板 fixed 连录两次：第二次落到 fixed-2.mov，两个文件都在、第一次的内容原样（prompt 119 交付 2）。
    func testK01_fixedTemplateRecordedTwiceKeepsBothFiles() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        session.send(.setProgram(input: 1))
        let directory = try temporaryDirectory("fixed")
        defer { try? FileManager.default.removeItem(at: directory) }
        try pointRecord(session, to: directory, pattern: "fixed")
        let first = try recordOnce(session, seconds: 0.6)
        XCTAssertEqual(first.url.lastPathComponent, "fixed.mov")
        let firstBytes = try Data(contentsOf: first.url)
        XCTAssertGreaterThan(firstBytes.count, 1000, "第一次录出了东西")
        let second = try recordOnce(session, seconds: 0.6)
        print("W5P K01 连录两次：\(first.url.lastPathComponent)（\(firstBytes.count) 字节）→ \(second.url.lastPathComponent)，\(second.videoFrames) 帧")
        XCTAssertEqual(second.url.lastPathComponent, "fixed-2.mov", "同名就加后缀")
        XCTAssertEqual(try Data(contentsOf: first.url), firstBytes, "第一次的文件原样保住")
        XCTAssertGreaterThan(second.videoFrames, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["fixed-2.mov", "fixed.mov"])
        // 第三次接着往后排（-2 已占）
        let third = try recordOnce(session, seconds: 0.4)
        XCTAssertEqual(third.url.lastPathComponent, "fixed-3.mov")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 转封装成 MP4 的路：磁盘上只有同名 .mp4（上一次转封装留下的，.mov 已经不在）也算占了——Remux 会先删同名 .mp4（prompt 119 交付 2）。
    func testK01_remuxTargetWithSameNameIsKept() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        session.send(.setProgram(input: 1))
        let directory = try temporaryDirectory("remux")
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldMP4 = directory.appendingPathComponent("fixed.mp4")
        let prior = Data("W5P previous mp4 must survive".utf8)
        try prior.write(to: oldMP4)
        try pointRecord(session, to: directory, pattern: "fixed", remux: true)
        let result = try recordOnce(session, seconds: 0.6)
        print("W5P K01 转封装同名：录到 \(result.url.lastPathComponent)，mp4 \(result.mp4URL?.lastPathComponent ?? "nil")，remuxError \(result.remuxError ?? "nil")")
        XCTAssertEqual(result.url.lastPathComponent, "fixed-2.mov", "同名 .mp4 在：这一路换名字")
        XCTAssertEqual(try Data(contentsOf: oldMP4), prior, "旧的 fixed.mp4 原样保住")
        if let mp4 = result.mp4URL { XCTAssertEqual(mp4.lastPathComponent, "fixed-2.mp4") }
    }

    /// 分配层的口径（不起引擎）：磁盘上有的、这一批 / 在录的别的路要用的、转封装的同名 .mp4 都跳过，不分大小写，扩展名照原样。
    func testK01_uniquePathSkipsDiskBatchAndRunningNames() {
        let dir = URL(fileURLWithPath: "/rec", isDirectory: true)
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        var disk: Set<String> = []
        let exists: (URL) -> Bool = { disk.contains($0.path) }
        // 都没占：原样
        XCTAssertEqual(RecordingPaths.unique(url("a.mov"), remuxToMP4: false, taken: [], exists: exists), url("a.mov"))
        // 磁盘上有 a.mov、a-2.mov：a-3
        disk = [url("a.mov").path, url("a-2.mov").path]
        XCTAssertEqual(RecordingPaths.unique(url("a.mov"), remuxToMP4: false, taken: [], exists: exists), url("a-3.mov"))
        // 在录的别的路要用 a（文件还没建出来，磁盘上看不到）：a-2；大小写不同也算同一个
        disk = []
        XCTAssertEqual(RecordingPaths.unique(url("a.mov"), remuxToMP4: false, taken: [RecordingPaths.key(url("A.mov"))], exists: exists), url("a-2.mov"))
        // 只有同名 .mp4：不转封装的路不管它，转封装的路跳过
        disk = [url("a.mp4").path]
        XCTAssertEqual(RecordingPaths.unique(url("a.mov"), remuxToMP4: false, taken: [], exists: exists), url("a.mov"))
        XCTAssertEqual(RecordingPaths.unique(url("a.mov"), remuxToMP4: true, taken: [], exists: exists), url("a-2.mov"))
        // 同一批：前面分出去的进 taken，后面的接着往后排
        disk = [url("show.mov").path]
        var taken: Set<String> = []
        var got: [String] = []
        for _ in 0..<3 {
            let u = RecordingPaths.unique(url("show.mov"), remuxToMP4: false, taken: taken, exists: exists)
            taken.insert(RecordingPaths.key(u))
            got.append(u.lastPathComponent)
        }
        XCTAssertEqual(got, ["show-2.mov", "show-3.mov", "show-4.mov"])
    }

    // MARK: D06 ISO 录制中换源

    /// ISO 录着换这一路的来源（带音频的合成源 → 另一个带音频的合成源）：同一个录制器录到底，视频帧数 = 起止拍差（拍点连续、文件里没洞）、两轨等长；
    /// 换源到新来源第一帧之间重复旧帧记在 tap 的 repeated 里（dup 记账），几拍之内就换上新来源、不定格到底；这一路的 tee / 主槽 / 引擎注册都没换。
    func testD06_isoRecordingAcrossSourceChangeStaysContinuous() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, gray: 80, audio: true)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.registeredInputs.contains(1) })
        let input = try XCTUnwrap(session.state.input(1))
        let iso = ISORoutes.makeISOOutput(for: input, in: session.state, defaultDirectory: AppTest.controller.documents.recordDirectory)
        session.send(.addOutput(config: iso))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(iso.number) != nil })
        let tee = try XCTUnwrap(session.inputs.entries[1]?.tee)
        let slot = try XCTUnwrap(session.inputs.entries[1]?.slot)
        session.send(.startRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[iso.number] != nil })
        let entry = try XCTUnwrap(session.outputs.recorders[iso.number])
        let tap = try XCTUnwrap(entry.consumer as? ISOFrameTap)
        XCTAssertNotNil(entry.recorder.configuration.audio, "这一路带音频：ISO 有音轨")
        AppTest.pump(seconds: 1)
        let before = tap.counters
        let oldInput = try XCTUnwrap(session.inputs.entries[1]?.input)
        session.send(.setInputSource(input: 1, source: AppTest.syntheticConfig(number: 1, gray: 200, audio: true).source))
        XCTAssertTrue(AppTest.waitUntil(5) { session.inputs.entries[1].map { $0.input !== oldInput } ?? false })
        XCTAssertTrue(AppTest.waitUntil(2) { tap.counters.lastSequence < before.lastSequence }, "新来源的帧（序号从头数）应很快进 ISO：\(tap.counters)")
        let switched = tap.counters
        AppTest.pump(seconds: 1.5)
        let after = tap.counters
        print("W5P D06 换源前后：before \(before)，换上新来源时 \(switched)，1.5 s 后 \(after)")
        XCTAssertTrue(session.inputs.entries[1]?.tee === tee, "tee 不换")
        XCTAssertTrue(session.inputs.entries[1]?.slot === slot, "引擎注册的主槽不换")
        XCTAssertEqual(session.engine.registeredInputs, [1])
        XCTAssertTrue(session.outputs.recorders[iso.number] === entry, "同一个录制器录到底（Recorder 不断）")
        XCTAssertLessThanOrEqual(switched.repeated - before.repeated, 30, "换源到新来源第一帧之间的重复帧（dup）不到半秒")
        XCTAssertGreaterThan(after.forwarded - switched.forwarded, 80, "换上之后每拍都在交帧")
        XCTAssertLessThanOrEqual(after.repeated - switched.repeated, 2, "换上之后不再重复旧帧（60 fps 源）")
        session.send(.stopRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(15) { session.outputs.recorders[iso.number] == nil && session.outputs.lastResults[iso.number] != nil })
        let result = try XCTUnwrap(session.outputs.lastResults[iso.number])
        defer { try? FileManager.default.removeItem(at: result.url) }
        let ticks = Int(result.stopTick.rawValue - result.start.tick.rawValue)
        print("W5P D06 ISO 文件：\(result.url.lastPathComponent)，\(ticks) 拍，视频 \(result.videoFrames) 帧，音频 \(result.audioFrames) 样本")
        XCTAssertEqual(Int(result.videoFrames), ticks, "视频帧数 = 起止拍差：换源前后拍点连续、文件里没有洞")
        XCTAssertEqual(Int(result.audioFrames), ticks * 800, accuracy: 800, "两轨等长（换源时音频重新注册的那几十毫秒是静音，不是断）")
    }

    /// 换到起不来的来源（图片文件不在：start 当场失败）：这一路画黑，不停在旧来源的最后一帧上（与新加一路起不来的输入"空槽画黑"一致）。
    func testD06_sourceChangeToBrokenSourceGoesBlackNotFrozen() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, gray: 200)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        XCTAssertTrue(AppTest.waitUntil(3) { (AppTest.readback(session)?.lumaStats().mean ?? 0) > 120 }, "PGM 先是灰底的合成源")
        session.send(.setInputSource(input: 1, source: .image(path: "/nonexistent/w5p-missing.png")))
        XCTAssertTrue(AppTest.waitUntil(3) { if case .error? = session.inputs.runtimeState(of: 1) { return true } else { return false } },
                      "\(String(describing: session.inputs.runtimeState(of: 1)))")
        XCTAssertTrue(AppTest.waitUntil(3) { (AppTest.readback(session)?.lumaStats().mean ?? 255) < 3 },
                      "起不来的来源：画黑，不定格在旧画面（\(String(describing: AppTest.readback(session)?.lumaStats())))")
    }

    // MARK: D16 LastSession 的相对素材

    /// 走恢复入口的整条路：打开带相对素材（assets/logo.png）的节目 → 退出（shutdown 存 LastSession）→ 节目 › 打开上次退出时的节目：
    /// 恢复出来的没有文件身份，素材仍按原节目目录找到、这一路 live；LastSession 里存的是绝对路径（节目文件里照旧相对）。
    func testD16_openLastSessionFindsRelativeImageInShowDirectory() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let dir = try temporaryDirectory("lastsession")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
        try InputWiringTests.writeSolidPNG(to: dir.appendingPathComponent("assets/logo.png"), width: 320, height: 180, red: 200, green: 40, blue: 40)
        var show = ShowDocuments.emptyShow(name: "相对素材", recordDirectory: dir.path)
        show.inputs = [InputConfig(number: 1, name: "台标", source: .image(path: "assets/logo.png"))]
        let url = dir.appendingPathComponent("相对素材.\(ShowDocuments.fileExtension)")
        try ShowStore().save(show, to: url)
        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { opened.value && controller.session?.isRunning == true })
        XCTAssertEqual(AppTest.waitLive(try XCTUnwrap(controller.session), input: 1, timeout: 5), .live, "打开文件时按节目目录找到")
        defer { try? FileManager.default.removeItem(at: controller.documents.autosaveURL) }
        let restored = AppTest.expectationBox()
        Task {
            await controller.shutdown()          // 退出那一步：存 LastSession
            await controller.openLastSession()   // 节目 › 打开上次退出时的节目（确认框之后的本体）
            restored.value = true
        }
        XCTAssertTrue(AppTest.waitUntil(20) { restored.value && controller.session?.isRunning == true }, "\(String(describing: controller.lastError))")
        let session = try XCTUnwrap(controller.session)
        XCTAssertNil(controller.documents.currentURL, "恢复的不是文件：保存时要另存")
        guard case .image(let path)? = session.state.inputs.first?.source else { return XCTFail("\(String(describing: session.state.inputs.first))") }
        print("W5P D16 恢复后：\(path)，素材基准 \(controller.documents.mediaBaseDirectory.path)")
        XCTAssertTrue(path.hasPrefix("/") && path.hasSuffix("assets/logo.png"), "LastSession 里落成绝对路径：\(path)")
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live, "素材仍指向原节目目录：\(String(describing: session.inputs.runtimeState(of: 1)))")
        XCTAssertEqual(try ShowStore().load(from: url).inputs.first?.source, .image(path: "assets/logo.png"), "节目文件里照旧是相对路径")
    }

    // MARK: D04 打开 / 保存配对

    /// 读不出来的打开：保存目标、跑着的节目都不变（D04 的"拒绝的请求不能提前改保存目标"）。
    func testD04_failedOpenKeepsSaveTargetAndRunningShow() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let directory = try temporaryDirectory("open-bad")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("A.switcher.json")
        let bad = directory.appendingPathComponent("Bad.switcher.json")
        var showA = controller.documents.emptyShow(name: "A")
        showA.inputs = [AppTest.syntheticConfig(number: 1, gray: 60)]
        try ShowStore().save(showA, to: a)
        try Data("{ not a show".utf8).write(to: bad)
        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: a); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { opened.value && controller.session?.isRunning == true })
        let sessionA = try XCTUnwrap(controller.session)
        let failed = AppTest.expectationBox()
        Task { await controller.openShow(url: bad); failed.value = true }
        XCTAssertTrue(AppTest.waitUntil(10) { failed.value })
        XCTAssertTrue(controller.session === sessionA, "读不出来：跑着的还是 A")
        XCTAssertEqual(controller.documents.currentURL, a, "保存目标还是 A")
        XCTAssertNotEqual(controller.documents.recentURLs.first, bad, "读不出来的不进最近列表")
    }

    /// 排在打开后面的"重起引擎"接手的是刚打开的那份（轮到时才取当前节目），保存目标仍是那个文件。
    func testD04_restartQueuedBehindOpenRestartsTheOpenedShow() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let directory = try temporaryDirectory("open-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("A.switcher.json")
        var showA = controller.documents.emptyShow(name: "A")
        showA.inputs = [AppTest.syntheticConfig(number: 3, gray: 60)]
        try ShowStore().save(showA, to: a)
        let opened = AppTest.expectationBox(), restarted = AppTest.expectationBox()
        controller.requestOpenShow(url: a) { opened.value = true }
        Task { await controller.restartSession(); restarted.value = true }
        XCTAssertTrue(AppTest.waitUntil(30) { opened.value && restarted.value && controller.session?.isRunning == true })
        let session = try XCTUnwrap(controller.session)
        print("W5P D04 打开后排队重起：session=\(session.name)，inputs=\(session.state.inputs.map(\.number))，target=\(controller.documents.currentURL?.lastPathComponent ?? "nil")")
        XCTAssertEqual(session.name, "A")
        XCTAssertEqual(session.state.inputs.map(\.number), [3], "重起的是刚打开的 A，不是发请求时跑着的那份")
        XCTAssertEqual(controller.documents.currentURL, a)
    }
}
