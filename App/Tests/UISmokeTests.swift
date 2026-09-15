// W2-B prompt 的"XCTest UI 冒烟"：启动 → 加两个合成源 → 按 2 → 空格 → 快照 program == 2；回车 → 30 拍后对调。
// 另外顺手验证：缩略图点击 / Shift 点击、T-bar 推到顶提交、Overlay / 静音按钮、快照分发 ≤ 60 Hz、监视器标题条。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class UISmokeTests: XCTestCase {
    func testUI_smoke_launchAddTwoSyntheticsKey2SpaceThenReturnSwapsAfter30Ticks() throws {
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        XCTAssertNotNil(wc.window, "主窗口应已建好")
        XCTAssertEqual(session.state.inputs.count, 0, "新节目应没有输入")

        // 1. 加两个合成源（走 Add Input 表单同一条路：AddInputModel → addInput 命令）
        var model = AddInputModel()
        model.kind = .synthetic
        model.number = 1
        let config1 = try model.makeConfig()
        session.send(.addInput(config: config1))
        model.number = 2
        model.syntheticFrameRate = .fps30
        session.send(.addInput(config: try model.makeConfig()))
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.inputs.count == 2 }, "两路输入应进快照")
        XCTAssertTrue(AppTest.waitUntil(10) { session.inputs.runtimeState(of: 1) == .live && session.inputs.runtimeState(of: 2) == .live },
                      "两路合成源应已 live：\(String(describing: session.inputs.runtimeState(of: 1))) / \(String(describing: session.inputs.runtimeState(of: 2)))")
        XCTAssertEqual(wc.inputStrip.cells.count, 2, "缩略图条应有两格")
        XCTAssertEqual(config1.name, "合成 1 · 60", "默认名字")

        // 2. 按 2 → PVW = 2
        AppTest.press("2")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 2 }, "按 2 应选 PVW 2，现在 preview = \(session.state.preview)")
        XCTAssertEqual(wc.previewMonitor.displayedNumber, "2")
        XCTAssertEqual(wc.previewMonitor.displayedName, "合成 2 · 30")

        // 3. 空格 → Cut → PGM = 2
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 }, "空格应 Cut，program = \(session.state.program)")
        XCTAssertEqual(session.state.preview, 0, "Cut 后 PVW 拿到原来的 PGM（黑场）")
        XCTAssertEqual(wc.programMonitor.displayedNumber, "2")
        XCTAssertEqual(wc.inputStrip.cells[2]?.titleColor, Theme.tallyProgram, "2 号格子标题条应是 PGM 红")

        // 4. 按 1 → PVW = 1；回车 → Fade 30 拍 → 对调：program 1 / preview 2
        AppTest.press("1")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 1 })
        XCTAssertEqual(wc.inputStrip.cells[1]?.titleColor, Theme.tallyPreview, "1 号格子标题条应是 PVW 绿")
        XCTAssertEqual(session.state.transition.durationTicks, 30, "默认 Fade 时长 30 拍")
        AppTest.press("\r")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive }, "回车应开始 Fade")
        XCTAssertEqual(session.state.transition.type, .fade)
        let startTick = try XCTUnwrap(session.state.transition.startTick, "auto 转场应记起始拍")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 && session.state.preview == 2 && !session.state.transition.isActive },
                      "Fade 结束应对调：program = \(session.state.program) preview = \(session.state.preview)")
        // 对调发生在起始拍 + 30 那一拍：对调之后状态不再变，所以最新快照的拍就是完成拍
        let swapTick = try XCTUnwrap(session.stateMachine.publisher.latest?.tick)
        let elapsed = swapTick - startTick
        XCTAssertEqual(elapsed, 30, "对调应恰在起始拍 + 30；实际 \(elapsed) 拍")

        // 5. Shift + 2 → 直切 PGM = 2，PVW 不变
        AppTest.press("2", shift: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 }, "Shift + 2 应直切 PGM")
        XCTAssertEqual(session.state.preview, 2, "setProgram 不动 PVW")

        // 6. 缩略图：点 1 号 = 选 PVW；Shift 点 = 直切 PGM
        let cell1 = try XCTUnwrap(wc.inputStrip.cells[1])
        let cell2 = try XCTUnwrap(wc.inputStrip.cells[2])
        click(cell1, shift: false)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 1 }, "点格子应选 PVW")
        click(cell1, shift: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 }, "Shift 点格子应直切 PGM")

        // 7. Overlay：2 号格子的 Overlay 1 按钮 → 通道 1 用输入 2 且打开；再点关掉
        cell2.overlayButtons[0].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[0].on && session.state.overlays[0].input == 2 }, "格子上的 Overlay 1 应把通道 1 指向输入 2 并打开")
        XCTAssertTrue(session.state.tally(ofInput: 2).program, "叠加中的输入 tally 应为 PGM")
        cell2.overlayButtons[0].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.overlays[0].on }, "再点应关掉")
        // 中列的 Overlay 1 开关：只改 on，不动输入
        wc.transitionPanel.overlayButtons[0].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[0].on && session.state.overlays[0].input == 2 })
        wc.transitionPanel.overlayButtons[0].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.overlays[0].on })

        // 8. 静音
        cell2.muteButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(2)?.settings.audio.muted == true })
        cell2.muteButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(2)?.settings.audio.muted == false })

        // 9. FTB：F 开、F 关
        AppTest.press("f")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.ftb.on }, "F 应开 FTB")
        AppTest.press("f")
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.ftb.on }, "再按 F 应关 FTB")

        // 10. 时长预设：选 2s → 120 拍
        wc.transitionPanel.durationControl.selectedSegment = 2
        wc.transitionPanel.durationControl.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.durationTicks == 120 }, "2 s @ 60 fps = 120 拍，实际 \(session.state.transition.durationTicks)")

        // 11. Master 推子 / 静音
        wc.mixerPanel.fader.doubleValue = -12
        wc.mixerPanel.fader.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { abs(session.state.audio.buses[0].gainDb - (-12)) < 0.01 }, "推子应发 busGain")
        wc.mixerPanel.muteButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.audio.buses[0].muted })

        // 12. 快照分发合并：整个过程每秒最多 60 次
        XCTAssertLessThanOrEqual(wc.maxSnapshotsPerSecond, 60, "快照分发每秒最多 60 次")
        print("UI 冒烟：Fade 用了 \(elapsed) 拍；快照回调 \(wc.snapshotsReceived) 次，峰值 \(wc.maxSnapshotsPerSecond)/s；命令 \(session.commandsSent) 条")
    }

    /// T-bar：拖到顶提交（对调），松手回弹到 0；拖一半停住。
    func testUI_tbarDragToTopCommitsAndSpringsBack() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        let tbar = AppTest.controller.windowController.transitionPanel.tbar
        tbar.simulateDrag(to: 0.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.source == .tbar && abs(session.state.transition.progress - 0.5) < 0.001 },
                      "拖一半应停在 0.5：\(session.state.transition)")
        XCTAssertEqual(session.state.program, 1, "没到顶不对调")
        tbar.simulateDrag(to: 1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 && !session.state.transition.isActive },
                      "推到顶应提交并对调：\(session.state.program)/\(session.state.preview)")
        XCTAssertTrue(AppTest.waitUntil(1) { tbar.progress == 0 }, "提交后应回弹到 0，现在 \(tbar.progress)")
    }

    private func click(_ view: NSView, shift: Bool) {
        guard let window = view.window else { return }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY + 10), to: nil)
        let flags: NSEvent.ModifierFlags = shift ? [.shift] : []
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: center, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: center, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        // 合成的鼠标事件经 window.sendEvent / NSApp.postEvent 都不会派发到视图（AppKit 只认系统事件），
        // 所以这里自己做 NSWindow 那一步：hitTest 找到最深的视图，把 mouseDown / mouseUp 交给它（再沿响应链到格子）。
        guard let target = window.contentView?.hitTest(center) else { XCTFail("点不到视图"); return }
        target.mouseDown(with: down)
        target.mouseUp(with: up)
        AppTest.pump(seconds: 0.05)
    }
}
