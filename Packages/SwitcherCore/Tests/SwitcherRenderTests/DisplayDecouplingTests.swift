// 显示与渲染解耦（设计方案 §3.3、决策 2；prompt 的"显示解耦"测试）：
// 内置屏（120 Hz）上开预览窗口，假引擎按 60 Hz 节目时钟渲染；拖动窗口、遮住窗口、切全屏期间 missed_render（render 返回 .skipped）不增加。
import AppKit
import XCTest
import SwitcherContracts
@testable import SwitcherRender

@MainActor
final class DisplayDecouplingTests: XCTestCase {
    /// 像真正的 App 一样跑事件循环（display link 在主线程回调；窗口的遮挡状态由 window server 通过事件送来，光泵 RunLoop 收不到）。
    private func pump(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func launchApp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if !NSApp.isRunning { NSApp.finishLaunching() }
    }

    private func makeSetup() throws -> (MetalRenderer, FakeEngine, PreviewWindow) {
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd1080p60, maxInputs: 9)
        let engine = FakeEngine(renderer: renderer, format: .hd1080p60, inputs: FakeInputs.nv12(count: 8), state: LoadStates.eightInputsFourOverlays())
        let window = PreviewWindow(source: renderer, target: .program, title: "W1-C 显示解耦测试")
        return (renderer, engine, window)
    }

    /// 拖动 / 遮挡 / 全屏切换期间不跳拍；display link 按所在显示器刷新率跑（内置屏 120 Hz），预览只 blit 新完成的帧（≤ 60 fps）。
    func testDisplay_windowManipulationDoesNotCauseMissedRenders() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        launchApp()
        let (renderer, engine, preview) = try makeSetup()
        let view = preview.displayView
        preview.show()
        pump(seconds: 0.3)
        engine.startAsync()
        pump(seconds: 1)
        let skippedAfterWarmup = engine.skipped.load(ordering: .relaxed)
        let cb0 = view.linkCallbacks, p0 = view.presentedFrames
        let t0 = Date()

        // 1. 拖动：每 30 ms 挪一次，2 秒
        var phase = 0.0
        let origin = preview.window!.frame.origin
        let dragEnd = Date().addingTimeInterval(2)
        while Date() < dragEnd {
            phase += 0.3
            preview.window!.setFrameOrigin(NSPoint(x: origin.x + 120 * sin(phase), y: origin.y + 80 * cos(phase)))
            pump(seconds: 0.03)
        }
        let afterDrag = engine.skipped.load(ordering: .relaxed)

        // 2. 遮挡：一个不透明窗口整个盖住，1.5 秒
        let cover = NSWindow(contentRect: preview.window!.frame.insetBy(dx: -40, dy: -40), styleMask: [.titled], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .darkGray
        cover.level = .floating
        cover.orderFrontRegardless()
        pump(seconds: 1.5)
        let presentedWhileCovered = view.presentedFrames
        pump(seconds: 0.5)
        let presentedWhileCovered2 = view.presentedFrames
        cover.orderOut(nil)
        cover.close()
        let afterCover = engine.skipped.load(ordering: .relaxed)

        // 3. 全屏切换：进去 2 秒、出来 2 秒
        preview.window!.toggleFullScreen(nil)
        pump(seconds: 2)
        let fullscreenEntered = preview.window!.styleMask.contains(.fullScreen)
        preview.window!.toggleFullScreen(nil)
        pump(seconds: 2)
        let afterFullscreen = engine.skipped.load(ordering: .relaxed)

        // 4. 改大小
        preview.window!.setContentSize(NSSize(width: 640, height: 360))
        pump(seconds: 0.5)
        preview.window!.setContentSize(NSSize(width: 1280, height: 720))
        pump(seconds: 0.5)

        let elapsed = Date().timeIntervalSince(t0)
        let callbacks = view.linkCallbacks - cb0, presented = view.presentedFrames - p0
        engine.stopAndWait()
        let submitted = engine.submitted.load(ordering: .relaxed)
        let skipped = engine.skipped.load(ordering: .relaxed)
        renderer.shutdown()
        preview.close()

        let refresh = screen.maximumFramesPerSecond
        print(String(format: "显示解耦：%.1f 秒内 display link 回调 %d 次（%.1f Hz，显示器上限 %d Hz），blit %d 次（%.1f fps），引擎提交 %d 拍、跳过 %d 拍；遮挡 0.5 s 内 blit %d 次；全屏进入 %@",
                     elapsed, callbacks, Double(callbacks) / elapsed, refresh, presented, Double(presented) / elapsed, submitted, skipped,
                     presentedWhileCovered2 - presentedWhileCovered, fullscreenEntered ? "成功" : "未成功（测试进程可能没有全屏权限）"))
        XCTAssertEqual(skipped, skippedAfterWarmup, "拖动 / 遮挡 / 全屏切换期间 missed_render 不该增加")
        XCTAssertEqual(afterDrag, skippedAfterWarmup, "拖动期间跳拍")
        XCTAssertEqual(afterCover, skippedAfterWarmup, "遮挡期间跳拍")
        XCTAssertEqual(afterFullscreen, skippedAfterWarmup, "全屏切换期间跳拍")
        XCTAssertGreaterThan(presented, 0, "预览应该画了东西")
        XCTAssertLessThanOrEqual(Double(presented) / elapsed, 62, "预览每个节目帧最多 blit 一次（60 fps），不应跟着 120 Hz 重复画")
        XCTAssertEqual(presentedWhileCovered2 - presentedWhileCovered, 0, "被完全遮住时不该再 blit")
        XCTAssertGreaterThan(submitted, UInt64(elapsed * 55), "引擎应一直在 60 fps 提交")
    }

    /// 缩略图刷新率上限：maxFramesPerSecond = 15 时 2 秒内 blit ≤ 15 × 2（+ 余量）。
    func testDisplay_maxFrameRateCapsThumbnailBlits() throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有显示器") }
        launchApp()
        let (renderer, engine, preview) = try makeSetup()
        let view = preview.displayView
        view.maxFramesPerSecond = 15
        preview.show()
        pump(seconds: 0.3)
        engine.startAsync()
        pump(seconds: 1)
        let p0 = view.presentedFrames, c0 = view.linkCallbacks
        pump(seconds: 2)
        let presented = view.presentedFrames - p0, callbacks = view.linkCallbacks - c0
        engine.stopAndWait()
        renderer.shutdown()
        preview.close()
        print("缩略图上限 15 fps：2 秒内 display link 回调 \(callbacks) 次，blit \(presented) 次；没画的原因 \(view.skipCounters)")
        XCTAssertLessThanOrEqual(presented, 15 * 2 + 4)
        XCTAssertGreaterThan(presented, 10)
    }
}
