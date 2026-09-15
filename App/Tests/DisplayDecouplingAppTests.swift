// W2-B prompt 的"显示解耦"：真 App 主窗口 + 真引擎 + 两路合成源，拖动窗口、切全屏、（有外接屏时）挪到外接屏，
// 期间 missed_render 不增（读 Stats，不读引擎计数器）。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class DisplayDecouplingAppTests: XCTestCase {
    func testDisplay_dragFullscreenAndScreenMoveDoNotIncreaseMissedRender() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let pgm = wc.programMonitor.display

        // 预热 2 s，取基线（Stats.missed_render）
        AppTest.pump(seconds: 2)
        var statsLog: [Stats] = []
        let token = session.observeStats { statsLog.append($0) }
        defer { token.invalidate() }
        XCTAssertTrue(AppTest.waitUntil(3) { statsLog.count >= 1 }, "应收到 Stats")
        let baseline = statsLog.last!.missedRender
        let p0 = pgm.presentedFrames, c0 = pgm.linkCallbacks
        let t0 = Date()

        // 1. 拖动：每 30 ms 挪一次，2 s
        let origin = window.frame.origin
        var phase = 0.0
        let dragEnd = Date().addingTimeInterval(2)
        while Date() < dragEnd {
            phase += 0.3
            window.setFrameOrigin(NSPoint(x: origin.x + 100 * sin(phase), y: origin.y + 60 * cos(phase)))
            AppTest.pump(seconds: 0.03)
        }
        window.setFrameOrigin(origin)
        AppTest.pump(seconds: 1.2)
        let afterDrag = statsLog.last!.missedRender

        // 2. 全屏进出各 2 s
        window.toggleFullScreen(nil)
        AppTest.pump(seconds: 2)
        let entered = window.styleMask.contains(.fullScreen)
        window.toggleFullScreen(nil)
        AppTest.pump(seconds: 2)
        let afterFullscreen = statsLog.last!.missedRender

        // 3. 外接屏（如有）：挪过去 2 s 再挪回来
        var movedToExternal = false
        if let other = NSScreen.screens.first(where: { $0 != screen }) {
            let target = NSPoint(x: other.frame.midX - window.frame.width / 2, y: other.frame.midY - window.frame.height / 2)
            window.setFrameOrigin(target)
            AppTest.pump(seconds: 2)
            movedToExternal = window.screen == other
            print("外接屏 \(other.localizedName) \(other.maximumFramesPerSecond) Hz：display link 认为屏幕上限 \(String(describing: pgm.screenMaximumFramesPerSecond))")
            window.setFrameOrigin(origin)
            AppTest.pump(seconds: 1.2)
        }
        let final = statsLog.last!.missedRender
        let elapsed = Date().timeIntervalSince(t0)
        let presented = pgm.presentedFrames - p0, callbacks = pgm.linkCallbacks - c0

        print(String(format: "显示解耦（App）：%.1f s，PGM display link 回调 %d 次（%.1f Hz，屏幕 %d Hz），blit %d 次（%.1f fps）；missed_render 基线 %d → 拖动后 %d → 全屏后 %d → 最终 %d；全屏进入 %@；外接屏 %@",
                     elapsed, callbacks, Double(callbacks) / elapsed, screen.maximumFramesPerSecond, presented, Double(presented) / elapsed,
                     baseline, afterDrag, afterFullscreen, final, entered ? "成功" : "未成功", movedToExternal ? "已测" : "BLOCKED-硬件（没有第二块显示器）"))
        XCTAssertEqual(afterDrag, baseline, "拖动期间 missed_render 不该增加")
        XCTAssertEqual(afterFullscreen, baseline, "全屏切换期间 missed_render 不该增加")
        XCTAssertEqual(final, baseline, "整个过程 missed_render 不该增加")
        XCTAssertGreaterThan(presented, 0)
        XCTAssertLessThanOrEqual(Double(presented) / elapsed, 62, "PGM 每个节目帧最多 blit 一次")
        if NSScreen.screens.count < 2 { print("BLOCKED-硬件：挪到外接屏的部分没测（只有内置屏）") }
    }
}
