// W3-C2 交付 2 / 3：Stats.display[] 的填数复核（提案 013）与外部显示窗口在主屏上的层级选项。
// dropped 的口径（prompt 65）：没赶上显示刷新的帧 = 引擎给了新帧但两次刷新间被覆盖的次数。
//   PGM / PVW / 多画面：渲染器的完成帧版本号在两次呈现之间跳过的个数（DisplayFrameLedger 夹在渲染器和 MetalDisplayView 之间记）；
//   Aux：该路帧槽分支在两次刷新之间挤掉 / 跳过的帧（FrameSlotStats.dropped 的增量）+ 取了却没画出去（拿不到 drawable）又被新帧顶掉的。
//   窗口收起 / 被遮住 / 换源期间不算（那是没在呈现，不是没赶上）。
@preconcurrency import Metal
import AppKit
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import SwitcherExternal

@MainActor
final class DisplayStatsTests: XCTestCase {
    private func output(_ number: Int, _ spec: ExternalDisplaySpec) -> OutputState {
        OutputState(number: number, kind: .externalDisplay, name: "外部 \(number)", enabled: true, settings: spec.outputSettings)
    }

    private static let inputs = [InputConfig(number: 1, name: "机位一", source: .image(path: "/a.png"))]

    private func entry(_ manager: ExternalDisplayManager, _ number: Int) -> Stats.DisplayEntry? {
        manager.statsEntries.first { $0.output == number }
    }

    /// 1080p NV12 的几块缓冲给推帧线程轮换。
    private static func buffers() -> [CVPixelBuffer] {
        (0..<4).map { PatternFrames.nv12(frameNumber: UInt32($0)) }
    }

    /// 10 s 内 frames 单调递增、dropped 0（无负载）、state = presenting；拔显示器（模拟：目标显示器 ID 不存在）→ noDisplay；
    /// PGM 窗口（MetalDisplayView + 记账源）与 Aux 窗口（本包画输入帧）各跑一遍。插回来照常，拔掉期间不记丢帧。
    func testStats_displayEntriesCountPresentedFrames() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        launchTestApp()
        let source = try FakeDisplaySource()
        source.start()
        defer { source.stop() }
        let slot = TestFrameSlot()
        let pusher = FramePusher(slot: slot, buffers: Self.buffers(), framesPerSecond: 60)
        pusher.start()
        defer { pusher.stop() }
        _ = try AuxPipeline.shared(for: MTLCreateSystemDefaultDevice()!)
        let manager = ExternalDisplayManager(source: source.source)
        defer { manager.closeAll() }
        manager.auxFrames = AuxFrameTap(open: { $0 == 1 ? slot : nil }, close: { _, _ in })
        let id = ExternalDisplays.id(of: screen)
        let load = ProcessInfo.processInfo.thermalState
        print("外部显示 Stats：屏 \(screen.localizedName) \(screen.maximumFramesPerSecond) Hz，节目 60 fps，热状态 \(load.rawValue)")

        for (number, what) in [(2, OutputSource.program), (3, OutputSource.input(number: 1))] {
            let spec = ExternalDisplaySpec(displayID: id, source: what)
            manager.reconcile(outputs: [output(number, spec)], inputs: Self.inputs, format: .hd1080p60)
            XCTAssertTrue(pumpEvents(until: 3) { (self.entry(manager, number)?.frames ?? 0) > 5 }, "\(what)：窗口应开始呈现")
            let start = try XCTUnwrap(entry(manager, number))
            var samples: [Stats.DisplayEntry] = [start]
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 10 {
                pumpEvents(seconds: 0.1)
                samples.append(try XCTUnwrap(entry(manager, number)))
            }
            let end = samples.last!
            let elapsed = Date().timeIntervalSince(t0)
            print(String(format: "%@：10 s 呈现 %llu 帧（%.1f fps），dropped %llu，state %@",
                         "\(what)", end.frames - start.frames, Double(end.frames - start.frames) / elapsed, end.dropped, end.state))
            for (a, b) in zip(samples, samples.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.frames, a.frames, "\(what)：frames 是累计值，不减")
                XCTAssertGreaterThanOrEqual(b.dropped, a.dropped)
            }
            for k in stride(from: 10, to: samples.count, by: 10) {   // 每 1 s 都在涨
                XCTAssertGreaterThan(samples[k].frames, samples[k - 10].frames, "\(what)：第 \(k / 10) 秒 frames 没涨")
            }
            XCTAssertGreaterThan(Double(end.frames - start.frames) / elapsed, 50, "\(what)：应接近节目帧率 60")
            XCTAssertEqual(end.dropped, 0, "\(what)：无负载时不该掉帧")
            XCTAssertTrue(samples.allSatisfy { $0.state == "presenting" }, "\(what)：\(Set(samples.map(\.state)))")
            XCTAssertEqual(end.kind, "externalDisplay")

            // 拔显示器（目标 ID 不存在）→ noDisplay；窗口收起期间不呈现、不记丢帧
            let unplugged = ExternalDisplaySpec(displayID: 0xDEAD_BEEF, source: what)
            manager.reconcile(outputs: [output(number, unplugged)], inputs: Self.inputs, format: .hd1080p60)
            pumpEvents(seconds: 1)
            let gone = try XCTUnwrap(entry(manager, number))
            XCTAssertEqual(gone.state, "noDisplay")
            pumpEvents(seconds: 1)
            let stillGone = try XCTUnwrap(entry(manager, number))
            XCTAssertEqual(stillGone.frames, gone.frames, "收起的窗口不呈现")
            XCTAssertEqual(stillGone.dropped, 0, "显示器不在期间的帧不是'没赶上刷新'")
            // 插回来：照常呈现，拔掉那段的版本 / 帧差不算丢
            manager.reconcile(outputs: [output(number, spec)], inputs: Self.inputs, format: .hd1080p60)
            XCTAssertTrue(pumpEvents(until: 3) { (self.entry(manager, number)?.frames ?? 0) > gone.frames + 30 }, "\(what)：插回来应继续呈现")
            let back = try XCTUnwrap(entry(manager, number))
            XCTAssertEqual(back.state, "presenting")
            XCTAssertEqual(back.dropped, 0, "\(what)：拔插之间的空档不该记成丢帧")
            manager.closeAll()
        }
        XCTAssertTrue(manager.statsEntries.isEmpty)
    }

    /// dropped 的口径本身：源比显示刷新快（渲染器 / 推帧 240 fps，内置屏 120 Hz）→ 两次刷新之间被覆盖的帧都记上；
    /// 呈现 + 丢 ≈ 这段时间里引擎给的新帧（差几帧是还在路上的）。
    func testStats_droppedCountsFramesOverwrittenBetweenRefreshes() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        launchTestApp()
        let source = try FakeDisplaySource(frameRate: FrameRate(240))
        source.start()
        defer { source.stop() }
        let slot = TestFrameSlot()
        let pusher = FramePusher(slot: slot, buffers: Self.buffers(), framesPerSecond: 240)
        pusher.start()
        defer { pusher.stop() }
        _ = try AuxPipeline.shared(for: MTLCreateSystemDefaultDevice()!)
        let manager = ExternalDisplayManager(source: source.source)
        defer { manager.closeAll() }
        manager.auxFrames = AuxFrameTap(open: { $0 == 1 ? slot : nil }, close: { _, _ in })
        let id = ExternalDisplays.id(of: screen)

        // PGM：版本号跳过的个数
        manager.reconcile(outputs: [output(2, ExternalDisplaySpec(displayID: id, source: .program))], inputs: Self.inputs, format: .hd1080p60)
        XCTAssertTrue(pumpEvents(until: 3) { (self.entry(manager, 2)?.frames ?? 0) > 20 })
        let a0 = try XCTUnwrap(entry(manager, 2)), v0 = source.renderer.latestDisplayFrame(for: .program)?.version ?? 0
        pumpEvents(seconds: 2)
        let a1 = try XCTUnwrap(entry(manager, 2)), v1 = source.renderer.latestDisplayFrame(for: .program)?.version ?? 0
        let produced = Int(v1 - v0), shown = Int(a1.frames - a0.frames), lost = Int(a1.dropped - a0.dropped)
        print("PGM 240 fps → \(screen.maximumFramesPerSecond) Hz：2 s 新版本 \(produced)，呈现 \(shown)，dropped \(lost)")
        XCTAssertGreaterThan(lost, produced / 4, "比刷新快的源必然有被覆盖的版本")
        XCTAssertLessThanOrEqual(abs(shown + lost - produced), 4, "呈现 + 丢 = 新版本（差的是首尾还在路上的）")
        manager.closeAll()

        // Aux：帧槽分支在两次刷新之间被挤掉 / 跳过的帧
        manager.reconcile(outputs: [output(3, ExternalDisplaySpec(displayID: id, source: .input(number: 1)))], inputs: Self.inputs, format: .hd1080p60)
        XCTAssertTrue(pumpEvents(until: 3) { (self.entry(manager, 3)?.frames ?? 0) > 20 })
        let b0 = try XCTUnwrap(entry(manager, 3)), p0 = pusher.pushed
        pumpEvents(seconds: 2)
        let b1 = try XCTUnwrap(entry(manager, 3)), p1 = pusher.pushed
        let pushed = Int(p1 - p0), auxShown = Int(b1.frames - b0.frames), auxLost = Int(b1.dropped - b0.dropped)
        print("Aux 240 fps → \(screen.maximumFramesPerSecond) Hz：2 s 推 \(pushed)，呈现 \(auxShown)，dropped \(auxLost)")
        XCTAssertGreaterThan(auxLost, pushed / 4)
        XCTAssertLessThanOrEqual(abs(auxShown + auxLost - pushed), 5, "呈现 + 丢 = 推进来的（差的是帧槽里还没取的，容量 3）")
    }

    /// W3-C 报告 §3 第 5 条：外部显示窗口开在主屏上默认盖住主界面（行为不变）；选项 behindInterface 让它垫在界面下面（层级低于普通窗口），
    /// 别的屏不受影响。
    func testWindow_mainScreenLayeringOption_keepsInterfaceOnTop() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("没有显示器") }
        launchTestApp()
        let source = try FakeDisplaySource()
        let ui = NSWindow(contentRect: NSRect(x: screen.frame.minX + 120, y: screen.frame.minY + 120, width: 640, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        ui.isReleasedWhenClosed = false
        ui.title = "主界面替身"
        // 尽量让本进程成前台 App：macOS 14 起是协作式激活，后台 App 的 orderFront 排到哪由系统定（实测两种都出现过），
        // 所以"默认在最前"的前后次序只在真成了前台时核；层级（决定"垫在界面下面"的那个）不受激活影响，一律核
        NSApp.activate(ignoringOtherApps: true)
        ui.makeKeyAndOrderFront(nil)
        defer { ui.orderOut(nil) }
        pumpEvents(seconds: 0.3)
        let manager = ExternalDisplayManager(source: source.source)
        defer { manager.closeAll() }
        XCTAssertEqual(manager.mainScreenLayering, .front, "默认行为不变")
        let id = ExternalDisplays.id(of: screen)
        manager.reconcile(outputs: [output(2, ExternalDisplaySpec(displayID: id, source: .program))], inputs: [], format: .hd1080p60)
        let w = try XCTUnwrap(manager.windows[2]?.window)
        func order() -> [String] { NSApp.orderedWindows.compactMap { $0 === ui ? "ui" : ($0 === w ? "out" : nil) } }
        pumpEvents(seconds: 0.2)
        func cgOrder() -> [String] {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return info.compactMap { d in
                let n = d[kCGWindowNumber as String] as? Int
                return n == ui.windowNumber ? "ui" : (n == w.windowNumber ? "out" : nil)
            }
        }
        print("层级：orderedWindows \(order())，CG \(cgOrder())，key \(NSApp.keyWindow === ui ? "ui" : (NSApp.keyWindow === w ? "out" : "\(String(describing: NSApp.keyWindow))"))，active \(NSApp.isActive)")
        XCTAssertEqual(w.level, .normal, "默认：普通层级（W3-C 起的行为不变）")
        XCTAssertTrue(w.isVisible)
        if NSApp.isActive {
            XCTAssertEqual(order(), ["out", "ui"], "默认：盖满主屏、在最前")
        } else {
            print("层级：测试宿主不是前台 App（协作式激活没给），默认的前后次序由系统定，这里只核层级")
        }

        manager.mainScreenLayering = .behindInterface
        pumpEvents(seconds: 0.2)
        XCTAssertLessThan(w.level.rawValue, NSWindow.Level.normal.rawValue, "主屏上垫到普通窗口下面")
        XCTAssertEqual(order(), ["ui", "out"])
        XCTAssertTrue(w.isVisible, "仍在屏上（界面没盖住的地方看得见）")
        XCTAssertEqual(manager.windows[2]?.status, .showing(displayID: id))
        XCTAssertEqual(w.frame, screen.frame)
        w.makeKeyAndOrderFront(nil)   // 点一下外部窗口（成 key 收 Esc）也不会翻到界面上面
        pumpEvents(seconds: 0.2)
        XCTAssertEqual(order(), ["ui", "out"])
        // 别的屏不受影响
        if NSScreen.screens.count > 1 {
            let other = NSScreen.screens[1]
            let otherID = ExternalDisplays.id(of: other)
            manager.reconcile(outputs: [output(2, ExternalDisplaySpec(displayID: id, source: .program)),
                                        output(3, ExternalDisplaySpec(displayID: otherID, source: .program))], inputs: [], format: .hd1080p60)
            XCTAssertEqual(manager.windows[3]?.window?.level, .normal, "外接屏上照常")
            XCTAssertEqual(manager.windows[3]?.window?.screen, other)
        }
        manager.mainScreenLayering = .front
        pumpEvents(seconds: 0.2)
        XCTAssertEqual(w.level, .normal, "切回默认：普通层级")
        if NSApp.isActive { XCTAssertEqual(order().first, "out", "切回默认：又在最前") }
    }

    /// 真外接屏（本机现在接着一块时跑；没有就 BLOCKED-硬件）：PGM 与 Aux 窗口挪到外接屏上全屏，按那块屏的刷新率呈现、
    /// Aux 的 drawable = 那块屏的像素尺寸（全分辨率画，不是格子），无负载不掉帧。插拔与 L2 秒表法仍是人工项（报告 §2）。
    func testExternal_realSecondDisplay_pgmAndAuxPresentWithoutDrops() throws {
        guard NSScreen.screens.count > 1 else {
            throw XCTSkip("BLOCKED-硬件：本机只有一块屏；解锁条件 = 接一块外接显示器（HDMI / DP / USB-C）")
        }
        launchTestApp()
        let external = NSScreen.screens.first { $0 != NSScreen.main } ?? NSScreen.screens[1]
        let id = ExternalDisplays.id(of: external)
        let source = try FakeDisplaySource()
        source.start()
        defer { source.stop() }
        let slot = TestFrameSlot()
        let pusher = FramePusher(slot: slot, buffers: Self.buffers(), framesPerSecond: 60)
        pusher.start()
        defer { pusher.stop() }
        _ = try AuxPipeline.shared(for: MTLCreateSystemDefaultDevice()!)
        let manager = ExternalDisplayManager(source: source.source)
        defer { manager.closeAll() }
        manager.auxFrames = AuxFrameTap(open: { $0 == 1 ? slot : nil }, close: { _, _ in })
        for (number, what) in [(2, OutputSource.program), (3, OutputSource.input(number: 1))] {
            manager.reconcile(outputs: [output(number, ExternalDisplaySpec(displayID: id, source: what))], inputs: Self.inputs, format: .hd1080p60)
            let w = try XCTUnwrap(manager.windows[number])
            XCTAssertEqual(w.status, .showing(displayID: id))
            XCTAssertEqual(w.window?.frame, external.frame, "盖满外接屏")
            XCTAssertTrue(pumpEvents(until: 3) { (self.entry(manager, number)?.frames ?? 0) > 5 })
            let e0 = try XCTUnwrap(entry(manager, number))
            let t0 = Date()
            pumpEvents(seconds: 3)
            let e1 = try XCTUnwrap(entry(manager, number))
            let fps = Double(e1.frames - e0.frames) / Date().timeIntervalSince(t0)
            print(String(format: "外接屏 %@（%d Hz，%.0f×%.0f @%.0fx）%@：%.1f fps，dropped %llu", external.localizedName, external.maximumFramesPerSecond,
                         external.frame.width, external.frame.height, external.backingScaleFactor, "\(what)", fps, e1.dropped))
            XCTAssertGreaterThan(fps, 50)
            XCTAssertEqual(e1.dropped, 0)
            XCTAssertEqual(e1.state, "presenting")
            if case .input = what {
                let size = w.auxView.drawableSize
                XCTAssertEqual(size.width, external.frame.width * external.backingScaleFactor, "Aux 画在整块屏的像素上")
                XCTAssertEqual(size.height, external.frame.height * external.backingScaleFactor)
            }
            manager.closeAll()
        }
    }
}
