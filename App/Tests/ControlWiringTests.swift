// W2-B2 接缝 2、3：SwitcherSession.send → CommandBus（来源 ui）、主窗口 keyDown → HotkeyDispatcher（来源 hotkey）、
// StateFeed + APIServer（GET /state == 快照；POST cut 对调、applied true）、回执 applied == false 时状态行提示。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class ControlWiringTests: XCTestCase {
    /// GET /api/v1/state 的 program / preview == 快照；POST /api/v1/command {"cut":{}} 后画面对调（PGM 上的图案 ID 换了）、回执 applied true。
    func testAPI_stateMatchesSnapshotAndPostCutSwaps() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        guard let port = session.control.apiServer?.boundPort else {
            XCTFail("API 应已起：\(session.control.apiError ?? "无错误")")
            return
        }
        XCTAssertEqual(session.control.apiServer?.configuration.host, "127.0.0.1")
        print("API 端口 \(port)（测试宿主由系统分配；正式默认 \(APIServerConfiguration.defaultPort)）")
        // PGM 图案 ID = (编号 − 1) mod 16 → 输入 1 是 0
        XCTAssertTrue(AppTest.waitUntil(3) { AppTest.readback(session)?.decodePattern().inputID == 0 }, "PGM 应是输入 1 的图案")

        let state = try AppTest.http("GET", "http://127.0.0.1:\(port)/api/v1/state")
        XCTAssertEqual(state.status, 200)
        let stateObj = try XCTUnwrap(state.json?["state"] as? [String: Any])
        XCTAssertEqual(stateObj["program"] as? Int, session.state.program)
        XCTAssertEqual(stateObj["preview"] as? Int, session.state.preview)
        XCTAssertEqual((stateObj["inputs"] as? [Any])?.count, 2)
        let stats = session.stats
        XCTAssertNotNil(state.json?["stats"], "GET /state 应带最近一行 Stats（StatsPublisher 的同一行）")
        if let s = state.json?["stats"] as? [String: Any], let stats, let ts = s["ts"] as? Double {
            XCTAssertEqual(ts, stats.ts, accuracy: 1.5, "同一份 Stats（ts 相同或最多差一行）")
        }

        let cut = try AppTest.http("POST", "http://127.0.0.1:\(port)/api/v1/command", body: #"{"command":{"cut":{}}}"#)
        XCTAssertEqual(cut.status, 200, "\(cut.text)")
        XCTAssertEqual(cut.json?["applied"] as? Bool, true, "回执 applied 应为 true：\(cut.text)")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 }, "POST cut 后应对调")
        XCTAssertTrue(AppTest.waitUntil(3) { AppTest.readback(session)?.decodePattern().inputID == 1 }, "PGM 上应换成输入 2 的图案（ID 1）")
        let entry = session.control.bus.recentEntries().last { $0.source == .api }
        XCTAssertEqual(entry?.command, .cut)
        // tally 也一致
        let tally = try AppTest.http("GET", "http://127.0.0.1:\(port)/api/v1/tally")
        XCTAssertEqual(tally.json?["program"] as? Int, 2)
        XCTAssertEqual(tally.json?["preview"] as? Int, 1)
    }

    /// 主窗口按空格 → HotkeyDispatcher → 总线（来源 hotkey）计数 +1，PGM / PVW 对调。
    func testHotkey_spaceCutsThroughBusAndCounts() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        let before = session.control.bus.counters
        let handledBefore = session.control.hotkeys.counters.handled
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(2) { session.control.bus.counters.applied == before.applied + 1 }, "总线计数应 +1：\(session.control.bus.counters)")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 }, "空格应 Cut")
        XCTAssertEqual(session.control.hotkeys.counters.handled, handledBefore + 1)
        let entry = session.control.bus.recentEntries().last
        XCTAssertEqual(entry?.source, .hotkey)
        XCTAssertEqual(entry?.command, .cut)
        XCTAssertTrue(entry?.applied ?? false)
    }

    /// 回执 applied == false（FTB 目标已相同）→ 状态行右侧提示"命令被忽略"；结构性非法（不存在的输入）→ "命令被拒"。
    func testFeedback_ignoredAndRejectedCommandsShowNotice() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let wc = AppTest.controller.windowController
        XCTAssertFalse(session.state.ftb.on)
        session.send(.ftb(on: false))
        XCTAssertTrue(AppTest.waitUntil(2) { wc.bottomBar.displayedNotice.contains("命令被忽略") }, "applied == false 应提示：\(wc.bottomBar.displayedNotice)")
        XCTAssertEqual(session.control.bus.counters.ignored, 1)
        session.send(.setPreview(input: 9))
        XCTAssertTrue(AppTest.waitUntil(2) { wc.bottomBar.displayedNotice.contains("命令被拒") }, "结构性非法应提示：\(wc.bottomBar.displayedNotice)")
        XCTAssertEqual(session.control.bus.counters.rejected, 1)
        XCTAssertEqual(session.state.preview, 0, "被拒的命令没进状态机")
    }
}
