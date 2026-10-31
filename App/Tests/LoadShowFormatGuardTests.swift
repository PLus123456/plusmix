// G12 胶水（prompt 134 第 1 条）：Codex 2026-10-22 审查 N08 的 App 端到端用例——原文 `Audit20261022AppTests.testAPI_LoadShowMustKeepActualAndAdvertisedFormatConsistent`
// 等 loadShow 换格式被收下、再断言管线也跟着换；129 P5-7 按提案 034 ⑥ 定成"运行中不换格式、400 拒收"，所以改成：App 实际起的本机 API 收到换格式的 loadShow 回 400、
// state.format / session.format / 画面纹理 / 时钟全都不变；App 自己 `session.send` 同一条也被总线拒。
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class LoadShowFormatGuardTests: XCTestCase {
    func testN08_apiLoadShowWithDifferentFormat_rejected400_pipelineUnchanged() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        XCTAssertTrue(AppTest.waitUntil(5) { AppTest.readback(session) != nil }, "PGM 上先有画面")
        let before = session.state.format
        XCTAssertEqual(session.format, before, "起点：状态与会话同一格式")
        var show = session.makeShow()
        show.mixer.format = ProgramFormat(width: 1280, height: 720, frameRate: .fps30)
        XCTAssertNotEqual(show.mixer.format, before)
        guard let port = session.control.apiServer?.boundPort else {
            XCTFail("API 应已起：\(session.control.apiError ?? "无错误")"); return
        }
        let body = "{\"command\":" + String(decoding: try APIJSON.encoder.encode(Command.loadShow(show: show)), as: UTF8.self) + "}"
        let r = try AppTest.http("POST", "http://127.0.0.1:\(port)/api/v1/command" + AppTest.tokenQuery(session), body: body)
        XCTAssertEqual(r.status, 400, r.text)
        XCTAssertTrue((r.json?["error"] as? String ?? "").contains("运行中不能换格式"), r.text)
        let rejectedBefore = session.control.bus.counters.rejected
        session.send(.loadShow(show: show))
        AppTest.pump(seconds: 0.5)
        XCTAssertEqual(session.control.bus.counters.rejected, rejectedBefore + 1, "App 自己发同一条也被总线拒")
        XCTAssertEqual(session.state.format, before, "状态里的格式不变")
        XCTAssertEqual(session.format, before, "会话格式不变")
        let readback = AppTest.readback(session)
        XCTAssertEqual(readback?.width, before.width)
        XCTAssertEqual(readback?.height, before.height)
        XCTAssertEqual(session.engine.clock?.spec.frameRate, before.frameRate, "时钟不变")
    }
}
