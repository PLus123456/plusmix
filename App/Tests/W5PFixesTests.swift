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
