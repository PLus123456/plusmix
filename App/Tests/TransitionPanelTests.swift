// W3-E2 交付第 2 条：切换面板的 Wipe / Zoom / Stinger 按钮、时长预设（五种转场共用一个 durationTicks）、
// Wipe 方向 / 软边与 Stinger 输入 / 换底拍（落 TransitionState.wipe / .stinger）、T-bar 对当前类型生效。只看快照，不看画面。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class TransitionPanelTests: XCTestCase {
    /// 两路合成源，PGM 1 / PVW 2，转场时长 ticks。
    private func prepare(durationTicks: Int) throws -> SwitcherSession {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        session.send(.setTransition(type: .fade, durationTicks: durationTicks))
        guard AppTest.waitUntil(3, { session.state.program == 1 && session.state.preview == 2 && session.state.transition.durationTicks == durationTicks }) else {
            throw XCTSkip("前提没就绪：\(session.state.transition)")
        }
        return session
    }

    /// 等一次 auto 转场跑完，返回（起始拍，完成拍）。完成之后状态不再变，所以最新快照的拍就是对调那一拍（UISmokeTests 同一口径）。
    private func runToCompletion(_ session: SwitcherSession, from program: Int, to preview: Int, timeout: Double = 5) throws -> (start: Tick, end: Tick) {
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive }, "应开始转场：\(session.state.transition)")
        let start = try XCTUnwrap(session.state.transition.startTick, "auto 转场应记起始拍")
        XCTAssertTrue(AppTest.waitUntil(timeout) { session.state.program == preview && session.state.preview == program && !session.state.transition.isActive },
                      "转场结束应对调：program = \(session.state.program) preview = \(session.state.preview)")
        let end = try XCTUnwrap(session.stateMachine.publisher.latest?.tick)
        return (start, end)
    }

    /// 点 Wipe：快照 transition.type == .wipe，恰 24 拍后 program / preview 对调；类型留在状态里，之后 T-bar 也按 Wipe 推。
    func testTransitionButtons_wipeSwapsAfter24Ticks_tbarKeepsType() throws {
        let session = try prepare(durationTicks: 24)
        let panel = AppTest.controller.windowController.transitionPanel
        XCTAssertTrue(panel.wipeButton.isEnabled)
        panel.wipeButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .wipe }, "点 Wipe 后快照的类型应是 wipe：\(session.state.transition.type)")
        let run = try runToCompletion(session, from: 1, to: 2)
        XCTAssertEqual(run.end - run.start, 24, "Wipe 应恰在起始拍 + 24 对调")
        XCTAssertEqual(session.state.transition.type, .wipe, "类型留在状态里")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.tbarTypeText == "T-bar：Wipe" }, panel.tbarTypeText)

        // T-bar 对当前类型生效：推到一半 = 按 Wipe 的 tbar 转场（类型不变），推到顶提交
        panel.tbar.simulateDrag(to: 0.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.source == .tbar && abs(session.state.transition.progress - 0.5) < 1e-9 },
                      "T-bar 应推到 0.5：\(session.state.transition)")
        XCTAssertEqual(session.state.transition.type, .wipe)
        panel.tbar.simulateDrag(to: 1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 && !session.state.transition.isActive },
                      "T-bar 到顶应对调回来：\(session.state.program) / \(session.state.preview)")

        // Zoom / Stinger 两个按钮同一条路（Stinger 没选输入时渲染器只做延迟 Cut，状态机照常推进）
        panel.zoomButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .zoom })
        let zoom = try runToCompletion(session, from: 1, to: 2)
        XCTAssertEqual(zoom.end - zoom.start, 24)
        panel.stingerButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .stinger })
        let stinger = try runToCompletion(session, from: 2, to: 1)
        XCTAssertEqual(stinger.end - stinger.start, 24)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 时长预设对五种转场都生效（一个 durationTicks）：选 1 s 后点 Zoom = 60 拍；再点 Fade 也是 60 拍。
    func testTransitionDurationPreset_appliesToAllTypes() throws {
        let session = try prepare(durationTicks: 24)
        let panel = AppTest.controller.windowController.transitionPanel
        let index = try XCTUnwrap(TransitionPanelView.durationPresets.firstIndex(of: 1))
        panel.selectDurationPresetForTesting(index)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.durationTicks == 60 }, "\(session.state.transition)")
        panel.zoomButton.performClick(nil)
        let zoom = try runToCompletion(session, from: 1, to: 2)
        XCTAssertEqual(zoom.end - zoom.start, 60, "Zoom 用预设的 1 s = 60 拍")
        panel.fadeButton.performClick(nil)
        let fade = try runToCompletion(session, from: 2, to: 1)
        XCTAssertEqual(fade.end - fade.start, 60, "Fade 也用同一个时长")
        XCTAssertEqual(panel.durationControl.selectedSegment, index, "面板显示当前时长对应的预设")
    }

    /// Wipe 方向 / 软边、Stinger 输入 / 换底拍：没有 setTransitionParams 命令，经 loadShow 整体替换落进快照；
    /// 输入 / PGM / PVW 不变、输入不重建；转场进行中改的参数等转场结束再发（loadShow 会 resetTransientState，发了就打断转场）。
    func testTransitionParams_replaceViaLoadShow_deferredWhileTransitionActive() throws {
        let session = try prepare(durationTicks: 30)
        let panel = AppTest.controller.windowController.transitionPanel
        let m = panel.params
        let input1 = try XCTUnwrap(session.inputs.entries[1]?.input)
        m.setWipeDirection(.topToBottom)
        m.setWipeSoftness(0.9)
        XCTAssertEqual(m.wipe.softness, 0.3, "软边钳到 0–0.3")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.wipe == WipeParams(direction: .topToBottom, softness: 0.3) }, "\(session.state.transition.wipe)")
        m.setStingerInput(2)
        m.setStingerCutTick(12)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.stinger == StingerParams(input: 2, cutAtTick: 12) }, "\(session.state.transition.stinger)")
        m.setStingerCutTick(999)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.stinger.cutAtTick == 30 }, "换底拍钳到时长（≥ 时长 = 完成时换）：\(session.state.transition.stinger)")
        XCTAssertEqual(session.state.program, 1)
        XCTAssertEqual(session.state.preview, 2)
        XCTAssertEqual(session.state.inputs.count, 2)
        XCTAssertTrue(session.inputs.entries[1]?.input === input1, "整体替换不应重建输入")
        XCTAssertFalse(m.isPending)

        // 转场进行中：面板上立刻显示新值，但等转场结束才发（转场照常完成对调，没被打断）
        session.send(.autoTransition)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive })
        m.setWipeDirection(.diagonal)
        XCTAssertEqual(m.wipe.direction, .diagonal, "面板上立刻显示")
        XCTAssertTrue(m.isPending)
        AppTest.pump(seconds: 0.2)
        XCTAssertTrue(session.state.transition.isActive, "转场进行中不应被打断")
        XCTAssertEqual(session.state.transition.wipe.direction, .topToBottom, "转场进行中还没发")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 2 && session.state.preview == 1 && !session.state.transition.isActive },
                      "转场应照常完成对调：\(session.state.program) / \(session.state.preview)")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.wipe == WipeParams(direction: .diagonal, softness: 0.3) && !m.isPending },
                      "转场结束后参数生效：\(session.state.transition.wipe)")
        XCTAssertEqual(session.state.program, 2, "发参数用的是最新快照，不会把对调改回去")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }
}
