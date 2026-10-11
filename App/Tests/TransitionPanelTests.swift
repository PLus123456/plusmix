// W3-E2 交付第 2 条：切换面板的 Wipe / Zoom / Stinger、时长预设、Wipe 方向 / 软边与 Stinger 输入 / 换底拍、T-bar 对当前类型生效。只看快照，不看画面。
// W5-M（prompt 100）起这一列是"转场 1–4"四个槽：Wipe / Zoom / Stinger 是出厂槽 2 / 3 / 4 的效果；时长分段改的是当前槽；参数…挪进每个槽的 ▾，
// 发 setTransitionSlot（进行中也收：进行中的那一次按开始时的参数走完，做完那一拍起生效）。原来三条用例的意思照旧，改成按槽测。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class TransitionPanelTests: XCTestCase {
    /// 两路合成源，PGM 1 / PVW 2；转场 1–4 的时长都改成 ticks 拍（效果仍是出厂的 Fade / Wipe / Zoom / Stinger），当前槽 = 1。
    private func prepare(durationTicks: Int) throws -> SwitcherSession {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        for (i, var slot) in TransitionSlot.factoryDefaults(for: session.state.format).enumerated() {
            slot.durationTicks = durationTicks
            session.send(.setTransitionSlot(slot: i + 1, config: slot))
        }
        session.send(.useTransitionSlot(slot: 1, start: false))
        guard AppTest.waitUntil(3, { session.state.program == 1 && session.state.preview == 2 && session.state.transition.slots.allSatisfy { $0.durationTicks == durationTicks }
            && session.state.transition.currentSlot == 1 && session.state.transition.durationTicks == durationTicks }) else {
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

    /// 点转场 2（Wipe）：快照 transition.type == .wipe，恰 24 拍后 program / preview 对调；转场 2 成了当前槽，之后 T-bar 也按 Wipe 推。
    /// 转场 3 / 4（Zoom / Stinger）同一条路（Stinger 先选输入，没选时点主体只弹输入选择，见 TransitionColumnTests）。
    func testTransitionSlots_wipeSwapsAfter24Ticks_tbarKeepsSlot() throws {
        let session = try prepare(durationTicks: 24)
        let panel = AppTest.controller.windowController.transitionPanel
        let wipe = panel.slotButtons[1].bodyButton
        XCTAssertTrue(wipe.isEnabled)
        XCTAssertEqual(wipe.title, "Wipe → 0.4s", "24 拍 @60 = 0.4 s")
        wipe.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .wipe }, "点转场 2 后快照的类型应是 wipe：\(session.state.transition.type)")
        let run = try runToCompletion(session, from: 1, to: 2)
        XCTAssertEqual(run.end - run.start, 24, "Wipe 应恰在起始拍 + 24 对调")
        XCTAssertEqual(session.state.transition.type, .wipe, "当前那组留在 Wipe")
        XCTAssertEqual(session.state.transition.currentSlot, 2, "转场 2 成了当前槽")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.tbarSlotText.hasPrefix("转场 2 · Wipe → 0.4 秒") }, panel.tbarSlotText)

        // T-bar 对当前槽生效：推到一半 = 按 Wipe 的 tbar 转场（类型不变），推到顶提交
        panel.tbar.simulateDrag(to: 0.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.source == .tbar && abs(session.state.transition.progress - 0.5) < 1e-9 },
                      "T-bar 应推到 0.5：\(session.state.transition)")
        XCTAssertEqual(session.state.transition.type, .wipe)
        panel.tbar.simulateDrag(to: 1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 && !session.state.transition.isActive },
                      "T-bar 到顶应对调回来：\(session.state.program) / \(session.state.preview)")

        // 转场 3（Zoom）同一条路
        panel.slotButtons[2].bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .zoom })
        let zoom = try runToCompletion(session, from: 1, to: 2)
        XCTAssertEqual(zoom.end - zoom.start, 24)
        // 转场 4（Stinger）：先给它选一路输入（渲染器按这一路叠、按换底拍换底），再点主体执行
        var stinger = session.state.transition.slots[3]
        stinger.stinger.input = 1
        session.send(.setTransitionSlot(slot: 4, config: stinger))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[3].stinger.input == 1 && panel.slotButtons[3].bodyButton.title == "Stinger 0.4s" },
                      panel.slotButtons[3].bodyButton.title)
        panel.slotButtons[3].bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .stinger })
        let run4 = try runToCompletion(session, from: 2, to: 1)
        XCTAssertEqual(run4.end - run4.start, 24)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 时长分段改的是当前槽（Q37 (a)），不再是"五种转场共用一个时长"：当前槽 = 转场 1 时选 1 s → 执行转场 1 = 60 拍，转场 3（Zoom）仍是 24 拍。
    func testTransitionDurationPreset_appliesToCurrentSlotOnly() throws {
        let session = try prepare(durationTicks: 24)
        let panel = AppTest.controller.windowController.transitionPanel
        let index = try XCTUnwrap(TransitionPanelView.durationPresets.firstIndex(of: 1))
        panel.selectDurationPresetForTesting(index)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[0].durationTicks == 60 && session.state.transition.durationTicks == 60 }, "\(session.state.transition)")
        XCTAssertEqual(session.state.transition.slots[2].durationTicks, 24, "别的槽不动")
        panel.slotButtons[0].bodyButton.performClick(nil)
        let fade = try runToCompletion(session, from: 1, to: 2)
        XCTAssertEqual(fade.end - fade.start, 60, "转场 1 用改过的 1 s = 60 拍")
        panel.slotButtons[2].bodyButton.performClick(nil)
        let zoom = try runToCompletion(session, from: 2, to: 1)
        XCTAssertEqual(zoom.end - zoom.start, 24, "转场 3 还是自己的 24 拍")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.durationControl.selectedSegment == TransitionPanelView.customSegment }, "当前槽成了转场 3（0.4 s 不是预设）")
        XCTAssertEqual(panel.durationControl.label(forSegment: TransitionPanelView.customSegment), "0.4s")
    }

    /// 参数…（每个槽的 ▾ 里）：Wipe 方向 / 软边、Stinger 输入 / 换底拍经 setTransitionSlot 落进这个槽，不再 loadShow 整体替换：
    /// 输入 / PGM / PVW 不变、输入不重建；叠加进出动画进行中照发、不打断它；转场进行中也立刻发（只改配置），进行中的那一次按开始时的参数走完，
    /// 做完那一拍起当前那组按当前槽重拷。
    func testTransitionParams_slotParamsUseSetTransitionSlot_evenWhileTransitionActive() throws {
        let session = try prepare(durationTicks: 30)
        let panel = AppTest.controller.windowController.transitionPanel
        panel.showSlotParams(slot: 2)
        defer { panel.closeSlotParams() }
        XCTAssertNotNil(panel.paramsPopoverContentView, "转场 2 的参数面板打开了")
        let m = panel.params
        XCTAssertEqual(m.slot, 2)
        let since = session.control.bus.recentEntries().last?.sequence ?? 0
        let input1 = try XCTUnwrap(session.inputs.entries[1]?.input)
        m.setWipeDirection(.topToBottom)
        m.setWipeSoftness(0.9)
        XCTAssertEqual(m.wipe.softness, 0.3, "软边钳到 0–0.3")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].wipe == WipeParams(direction: .topToBottom, softness: 0.3) }, "\(session.state.transition.slots[1])")
        m.setStingerInput(2)
        m.setStingerCutTick(12)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].stinger == StingerParams(input: 2, cutAtTick: 12) }, "\(session.state.transition.slots[1])")
        m.setStingerCutTick(999)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].stinger.cutAtTick == 30 }, "换底拍钳到这个槽的时长（≥ 时长 = 完成时换）")
        XCTAssertEqual(session.state.transition.slots[1].type, .wipe, "参数不改效果")
        XCTAssertEqual(session.state.transition.wipe, WipeParams(), "转场 2 不是当前槽：当前那组不动")
        XCTAssertEqual(session.state.program, 1)
        XCTAssertEqual(session.state.preview, 2)
        XCTAssertEqual(session.state.inputs.count, 2)
        XCTAssertTrue(session.inputs.entries[1]?.input === input1, "不应重建输入")
        XCTAssertFalse(m.isPending)

        // 面板手里的快照过时（快照到命令入队之间别的来源改了东西）：只发这一个槽，不会把别人的改动盖回去
        let stale = session.state
        session.send(.busGain(bus: .master, dB: -6))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.audio.buses[Bus.master.rawValue].gainDb == -6 })
        m.apply(state: stale)
        m.setWipeSoftness(0.1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].wipe.softness == 0.1 }, "\(session.state.transition.slots[1])")
        XCTAssertEqual(session.state.audio.buses[Bus.master.rawValue].gainDb, -6, "别的来源的改动保留")

        // 叠加进出动画进行中：照发、不打断动画
        session.send(.setOverlay(channel: 1, rect: .bottomRightQuarter, animation: OverlayAnimation(kind: .fade, durationTicks: 240)))
        session.send(.overlay(channel: 1, on: true, input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[0].startTick != nil })
        m.setWipeSoftness(0.2)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].wipe.softness == 0.2 && !m.isPending }, "叠加动画（4 s）不挡参数")
        XCTAssertNotNil(session.state.overlays[0].startTick, "叠加动画没被打断")
        XCTAssertLessThan(session.state.overlays[0].animProgress, 1)

        // 转场 2 进行中改它的方向：立刻进槽，进行中的这一次按开始时的参数走完，做完那一拍起当前那组 = 新参数
        panel.slotButtons[1].bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive && session.state.transition.currentSlot == 2 })
        XCTAssertEqual(session.state.transition.wipe.direction, .topToBottom)
        m.setWipeDirection(.diagonal)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].wipe.direction == .diagonal }, "进行中也收")
        XCTAssertTrue(session.state.transition.isActive, "不打断转场")
        XCTAssertEqual(session.state.transition.wipe.direction, .topToBottom, "进行中的这一次按开始时的参数走")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 2 && session.state.preview == 1 && !session.state.transition.isActive },
                      "转场应照常完成对调：\(session.state.program) / \(session.state.preview)")
        XCTAssertEqual(session.state.transition.wipe, WipeParams(direction: .diagonal, softness: 0.2), "做完那一拍按当前槽重拷")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)

        // 命令日志：全是 setTransitionSlot、每条都生效，没有 loadShow / setTransitionParams
        let entries = session.control.bus.recentEntries().filter { $0.sequence > since && $0.source == .ui }
        let slotEdits = entries.filter { if case .setTransitionSlot(2, _) = $0.command { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(slotEdits.count, 6, "\(entries.map(\.command))")
        XCTAssertTrue(slotEdits.allSatisfy(\.applied), "\(slotEdits.map { ($0.command, $0.applied) })")
        XCTAssertFalse(entries.contains { if case .loadShow = $0.command { return true } else { return false } }, "不 loadShow 整体替换")
        XCTAssertFalse(entries.contains { if case .setTransitionParams = $0.command { return true } else { return false } }, "参数跟槽走，不再改当前那组")
        session.send(.overlay(channel: 1, on: false, input: nil))
    }
}
