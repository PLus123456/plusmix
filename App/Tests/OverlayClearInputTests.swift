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

    /// 提案 034 附带（用户 2026-10-25 批）：叠加时长的秒数框没有范围，`Int((秒 × 帧率).rounded())` 填一个 20 位数就溢出、App 崩；钳进 0…`DurationLimits.maxTicks`。
    func test034_overlayDurationSecondsClampedToTickLimit() {
        let model = OverlaySettingsModel(state: MixerState(format: .hd1080p60), channel: 1)
        XCTAssertEqual(model.ticks(seconds: 0.5), 30, "合法值照旧按帧率换拍")
        XCTAssertEqual(model.ticks(seconds: 99_999_999_999_999_999_999), DurationLimits.maxTicks)
        XCTAssertEqual(model.ticks(seconds: .infinity), DurationLimits.maxTicks)
        XCTAssertEqual(model.ticks(seconds: 14_400), DurationLimits.maxTicks, "60 fps 下 4 小时正好是上限")
        XCTAssertEqual(model.ticks(seconds: 14_401), DurationLimits.maxTicks)
        XCTAssertEqual(model.ticks(seconds: -3), 0)
        XCTAssertEqual(model.ticks(seconds: .nan), 0)
    }
}
