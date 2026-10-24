// 提案 034 ⑤ / Codex 2026-10-22 审查 N11：叠加设置里输入选"（无）"原来发 `overlay(input: nil)`——nil 的契约语义是"不换输入"，旧画面照播、下次打开也还是它。
// Codex 审查树上的 `Audit20261022AppTests.testOverlaySelectingNoneMustClearRoute` 原样搬来改名（reports/codex-bug-audit-20261022-tests/）。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class OverlayClearInputTests: XCTestCase {
    func testN11_overlaySettingsSelectingNone_clearsRoute() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let model = panels.showOverlaySettings(channel: 1).model
        model.setInput(channel: 1, input: 1)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.overlays[0].input == 1 })
        AppTest.pump(seconds: 0.2)
        model.setInput(channel: 1, input: nil)
        AppTest.pump(seconds: 0.5)
        XCTAssertNil(session.state.overlays[0].input, "叠加设置选\"（无）\"要清掉这一路的输入")
        XCTAssertEqual(session.control.bus.counters.rejected, 0, "清空的命令不该被总线拒")
    }
}
