// W2-B prompt："缩略图刷新率实测 ≤ 24 fps（signpost 统计）"。MetalDisplayView 每次 blit 打一个 os_signpost 事件并加 presentedFrames，
// 这里数 presentedFrames（与 signpost 同一处），Instruments 里 subsystem app.switcher.display 能看到同样的数。
// 同时验证 PGM / PVW 监视器全速（每个节目帧一次）、缩略图切的是多画面里对应的格子。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import Switcher

@MainActor
final class ThumbnailRateTests: XCTestCase {
    func testThumbnail_refreshRateAtMost24fpsWhileMonitorsRunFullSpeed() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        let wc = AppTest.controller.windowController
        let cell1 = try XCTUnwrap(wc.inputStrip.cells[1])
        let cell2 = try XCTUnwrap(wc.inputStrip.cells[2])
        XCTAssertEqual(cell1.display.maxFramesPerSecond, 24)
        XCTAssertEqual(cell1.display.target, .multiview)
        XCTAssertEqual(cell1.display.sourceRect, MultiviewLayout.inputCell(index: 0, inputCount: 2, width: 1920, height: 1080))
        XCTAssertEqual(cell2.display.sourceRect, MultiviewLayout.inputCell(index: 1, inputCount: 2, width: 1920, height: 1080))
        XCTAssertNil(wc.programMonitor.display.maxFramesPerSecond, "PGM 监视器不限速")
        XCTAssertNil(wc.previewMonitor.display.maxFramesPerSecond, "PVW 监视器不限速")

        AppTest.pump(seconds: 1.5)   // 预热
        let seconds = 4.0
        let t0 = Date()
        let thumb0 = (cell1.display.presentedFrames, cell1.display.linkCallbacks)
        let thumb20 = cell2.display.presentedFrames
        let pgm0 = wc.programMonitor.display.presentedFrames
        let pvw0 = wc.previewMonitor.display.presentedFrames
        AppTest.pump(seconds: seconds)
        let elapsed = Date().timeIntervalSince(t0)
        let thumbPresented = cell1.display.presentedFrames - thumb0.0
        let thumbCallbacks = cell1.display.linkCallbacks - thumb0.1
        let thumb2Presented = cell2.display.presentedFrames - thumb20
        let pgmPresented = wc.programMonitor.display.presentedFrames - pgm0
        let pvwPresented = wc.previewMonitor.display.presentedFrames - pvw0
        let thumbFPS = Double(thumbPresented) / elapsed
        print(String(format: "缩略图刷新率：%.1f s 内格子 1 blit %d 次（%.2f fps，display link 回调 %d 次，闸门拦 %d 次），格子 2 %d 次；PGM %d 次（%.1f fps）、PVW %d 次（%.1f fps）；屏幕 %d Hz",
                     elapsed, thumbPresented, thumbFPS, thumbCallbacks, cell1.display.skipCounters.rateLimited, thumb2Presented,
                     pgmPresented, Double(pgmPresented) / elapsed, pvwPresented, Double(pvwPresented) / elapsed, screen.maximumFramesPerSecond))
        XCTAssertLessThanOrEqual(thumbFPS, 24.0 + 0.5, "缩略图 ≤ 24 fps")
        XCTAssertLessThanOrEqual(Double(thumb2Presented) / elapsed, 24.5)
        XCTAssertGreaterThan(thumbFPS, 10, "缩略图应在刷新（多画面纹理每拍都在变）")
        XCTAssertGreaterThan(Double(pgmPresented) / elapsed, 50, "PGM 监视器应接近节目帧率（60）")
        XCTAssertGreaterThan(Double(pvwPresented) / elapsed, 50, "PVW 监视器应接近节目帧率（60）")
        XCTAssertLessThanOrEqual(Double(pgmPresented) / elapsed, 62, "PGM 每个节目帧最多 blit 一次")
    }

    /// 遮挡时缩略图和监视器都停刷（display link 暂停），露出来恢复。
    func testThumbnail_pausesWhenWindowIsCovered() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let cell = try XCTUnwrap(wc.inputStrip.cells[1])
        AppTest.pump(seconds: 1)
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.titled], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .darkGray
        cover.level = .floating
        cover.orderFrontRegardless()
        AppTest.pump(seconds: 1)
        let p0 = cell.display.presentedFrames, c0 = cell.display.linkCallbacks, m0 = wc.programMonitor.display.presentedFrames
        AppTest.pump(seconds: 1)
        let coveredPresented = cell.display.presentedFrames - p0, coveredCallbacks = cell.display.linkCallbacks - c0
        let coveredMonitor = wc.programMonitor.display.presentedFrames - m0
        let pausedWhileCovered = cell.display.isLinkPaused
        cover.orderOut(nil)
        cover.close()
        AppTest.pump(seconds: 1)
        let p1 = cell.display.presentedFrames
        AppTest.pump(seconds: 1)
        let resumed = cell.display.presentedFrames - p1
        print("遮挡：1 s 内缩略图 blit \(coveredPresented) 次 / 回调 \(coveredCallbacks) 次（link 暂停 = \(pausedWhileCovered)），PGM blit \(coveredMonitor) 次；移开后 1 s blit \(resumed) 次")
        XCTAssertEqual(coveredPresented, 0, "被完全遮住时不该 blit")
        XCTAssertEqual(coveredMonitor, 0)
        XCTAssertTrue(pausedWhileCovered, "遮挡时 display link 应被暂停")
        XCTAssertGreaterThan(resumed, 10, "露出来应恢复刷新")
    }
}
