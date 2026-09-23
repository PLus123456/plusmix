// 外部显示（W3-C 交付 1）：全屏窗口在指定显示器、源可选、插拔处理、多窗口。本机只有内置屏（BLOCKED-硬件），
// 所以"指定显示器"= 主屏，"拔掉"用一个不存在的显示器 ID 模拟，插回 = 改回主屏 ID。纹理来源是一个假的 DisplayFrameSource（每 1/60 s 换版本）。
@preconcurrency import Metal
import AppKit
import Darwin
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import SwitcherExternal

/// 纹理来源：真的 MetalRenderer（DisplayFrame 的构造器不公开，伪造不了），后台线程按 60 Hz 节目时钟渲染一个没有输入的黑场状态。
final class FakeDisplaySource: @unchecked Sendable {
    let renderer: MetalRenderer
    private final class Flag: Sendable { let value = Atomic<Bool>(false) }
    private let stopFlag = Flag()
    private var thread: Thread?

    init() throws {
        renderer = try MetalRenderer()
        try renderer.prepare(format: .hd720p60, maxInputs: 3)
    }

    func start() {
        let t = Thread { [renderer, stopFlag] in
            let spec = TickClockSpec(t0: .now(), frameRate: .fps60)
            let table = RenderInputTable(capacity: 3)
            let snapshot = MixerSnapshot(state: MixerState(format: .hd720p60), sequence: 0, tick: .zero)
            var tick = Tick.zero
            while !stopFlag.value.load(ordering: .relaxed) {
                let t = spec.time(of: tick)
                mach_wait_until(t.ticks)
                _ = renderer.render(tick: tick, at: t, snapshot: snapshot, inputs: table)
                tick += 1
            }
        }
        t.name = "fake.render"
        thread = t
        t.start()
    }

    func stop() {
        stopFlag.value.store(true, ordering: .relaxed)
        usleep(50_000)
        renderer.shutdown()
    }

    var source: any DisplayFrameSource { renderer }
}

@MainActor
final class ExternalDisplayTests: XCTestCase {
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

    /// 提案 013：显示器 ID / 退回策略读写正式字段 `OutputSettings.display`；过渡键 extra 只作读的后备。
    func testP3_013_specRoundTripsThroughOfficialDisplayField() {
        var settings = OutputSettings(source: .program)
        let spec = ExternalDisplaySpec(displayID: 69734400, source: .input(number: 3), fallbackToMain: true)
        spec.apply(to: &settings)
        XCTAssertEqual(settings.source, .input(number: 3))
        XCTAssertEqual(settings.display, DisplayOutputSettings(displayID: 69734400, fallbackToMain: true))
        XCTAssertNil(settings.extra[ExternalDisplaySpec.displayIDKey], "写出只写正式字段")
        XCTAssertNil(settings.extra[ExternalDisplaySpec.fallbackKey])
        XCTAssertEqual(ExternalDisplaySpec(settings: settings), spec)
        // JSON 往返（Show 文件）
        let data = try! JSONEncoder().encode(settings)
        let back = try! JSONDecoder().decode(OutputSettings.self, from: data)
        XCTAssertEqual(ExternalDisplaySpec(settings: back), spec)
        // 主屏 + 不退回
        var plain = settings
        ExternalDisplaySpec(displayID: nil, source: .multiview).apply(to: &plain)
        XCTAssertEqual(plain.display, DisplayOutputSettings(displayID: nil, fallbackToMain: false))
        XCTAssertEqual(ExternalDisplaySpec(settings: plain), ExternalDisplaySpec(displayID: nil, source: .multiview))
        // 什么都没有（老 Show、也没有过渡键）：主屏 + 不退回（与 P3 之前一样）
        XCTAssertEqual(ExternalDisplaySpec(settings: OutputSettings(source: .program)),
                       ExternalDisplaySpec(displayID: nil, source: .program, fallbackToMain: false))
        // 过渡键作后备：正式字段为 nil 时仍读得出（一个版本）
        var legacy = OutputSettings(source: .preview)
        legacy.extra[ExternalDisplaySpec.displayIDKey] = .number(12345)
        legacy.extra[ExternalDisplaySpec.fallbackKey] = .bool(true)
        XCTAssertEqual(ExternalDisplaySpec(settings: legacy), ExternalDisplaySpec(displayID: 12345, source: .preview, fallbackToMain: true))
        // 正式字段优先于过渡键
        legacy.display = DisplayOutputSettings(displayID: 999, fallbackToMain: false)
        XCTAssertEqual(ExternalDisplaySpec(settings: legacy), ExternalDisplaySpec(displayID: 999, source: .preview, fallbackToMain: false))
        XCTAssertEqual(ExternalDisplaySpec.describe(.input(number: 2), inputs: [InputConfig(number: 2, name: "机位二", source: .image(path: "/x.png"))]), "输入 2 机位二")
    }

    func testDisplays_listContainsMainScreenWithItsID() throws {
        guard let main = NSScreen.main else { throw XCTSkip("没有显示器") }
        let all = ExternalDisplays.all()
        XCTAssertEqual(all.count, NSScreen.screens.count)
        XCTAssertEqual(all.first?.isMain, true)
        XCTAssertEqual(all.first?.id, ExternalDisplays.id(of: main))
        XCTAssertNotEqual(all.first?.id, 0)
        XCTAssertEqual(ExternalDisplays.screen(for: nil), main)
        XCTAssertEqual(ExternalDisplays.screen(for: all.first!.id), main)
        XCTAssertNil(ExternalDisplays.screen(for: 0xDEAD_BEEF))
        print("显示器：\(all.map { "\($0.name) #\($0.id) \($0.frame.size) \($0.maximumFramesPerSecond) Hz\($0.isMain ? " 主" : "")" })" + (all.count < 2 ? "（只有内置屏：外接屏部分 BLOCKED-硬件）" : ""))
    }

    /// 全屏窗口盖满指定显示器、按显示器刷新率 blit 新帧（≤ 节目帧率）；换源即时生效；Esc 请求关闭。
    func testWindow_fullscreenOnTargetDisplay_presentsFrames_sourceSwitch_escCloses() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        launchApp()
        let source = try FakeDisplaySource()
        source.start()
        defer { source.stop() }
        let id = ExternalDisplays.id(of: screen)
        let w = ExternalDisplayWindow(spec: ExternalDisplaySpec(displayID: id, source: .program), source: source.source)
        defer { w.closeOutput() }
        XCTAssertEqual(w.status, .showing(displayID: id))
        XCTAssertTrue(w.isShowing)
        XCTAssertEqual(w.window?.frame, screen.frame, "盖满显示器")
        XCTAssertEqual(w.window?.styleMask, [.borderless])
        XCTAssertEqual(w.displayView.target, .program)
        pump(seconds: 0.5)
        let p0 = w.displayView.presentedFrames
        let t0 = Date()
        pump(seconds: 2)
        let elapsed = Date().timeIntervalSince(t0)
        let presented = w.displayView.presentedFrames - p0
        print(String(format: "外部显示窗口：%.1f s blit %d 次（%.1f fps），display link 回调 %d 次，屏幕 %d Hz", elapsed, presented, Double(presented) / elapsed, w.displayView.linkCallbacks, screen.maximumFramesPerSecond))
        XCTAssertGreaterThan(Double(presented) / elapsed, 40, "应接近节目帧率（渲染器 60 Hz）")
        XCTAssertLessThanOrEqual(Double(presented) / elapsed, 62, "每个新版本最多 blit 一次")
        // 换源：PVW → 多画面 → 输入 2（Aux = 多画面里第 2 格）
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .preview))
        XCTAssertEqual(w.displayView.target, .preview)
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .multiview))
        XCTAssertEqual(w.displayView.target, .multiview)
        XCTAssertEqual(w.displayView.sourceRect, .full)
        let inputs = [InputConfig(number: 1, name: "a", source: .image(path: "/a.png")), InputConfig(number: 2, name: "b", source: .image(path: "/b.png"))]
        w.apply(inputs: inputs, textureWidth: 1920, textureHeight: 1080)
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .input(number: 2)))
        XCTAssertEqual(w.displayView.target, .multiview)
        XCTAssertEqual(w.displayView.sourceRect, MultiviewLayout.inputCell(index: 1, inputCount: 2, width: 1920, height: 1080))
        XCTAssertFalse(w.auxUnresolved)
        w.apply(inputs: [inputs[0]], textureWidth: 1920, textureHeight: 1080)   // 输入 2 被删
        XCTAssertTrue(w.auxUnresolved, "找不到那路输入就画黑")
        XCTAssertTrue(w.displayView.isHidden)
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .program))
        XCTAssertFalse(w.displayView.isHidden)
        pump(seconds: 0.3)
        // Esc → onCloseRequested
        var closeRequested = false
        w.onCloseRequested = { closeRequested = true }
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.window!.windowNumber, context: nil,
                                   characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        w.window?.sendEvent(esc)
        XCTAssertTrue(closeRequested, "Esc 应请求关闭")
    }

    /// 插拔：目标显示器不在 → 收起等待；插回 → 放回去；退回策略开着 → 暂用主屏。
    func testWindow_missingDisplayWaitsOrFallsBack_thenReturns() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        launchApp()
        let source = try FakeDisplaySource()
        let bogus: UInt32 = 0xDEAD_BEEF
        let w = ExternalDisplayWindow(spec: ExternalDisplaySpec(displayID: bogus, source: .program), source: source.source)
        defer { w.closeOutput() }
        var statuses: [ExternalDisplayWindow.Status] = []
        w.onStatusChange = { statuses.append($0) }
        XCTAssertEqual(w.status, .waitingForDisplay(displayID: bogus))
        XCTAssertFalse(w.isShowing, "显示器不在就收起")
        w.screensDidChange()   // 没变化：仍等待
        XCTAssertEqual(w.status, .waitingForDisplay(displayID: bogus))
        // "插回"：把目标改成主屏（真机上是同一个 ID 又出现在 NSScreen.screens 里，走 screensDidChange 同一条路）
        let id = ExternalDisplays.id(of: screen)
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .program))
        XCTAssertEqual(w.status, .showing(displayID: id))
        XCTAssertTrue(w.isShowing)
        XCTAssertEqual(w.window?.frame, screen.frame)
        // "拔掉"：目标换成不存在的 + 退回主屏策略 → 暂用主屏
        w.update(spec: ExternalDisplaySpec(displayID: bogus, source: .program, fallbackToMain: true))
        XCTAssertEqual(w.status, .fallbackToMain(displayID: bogus))
        XCTAssertTrue(w.isShowing)
        XCTAssertEqual(w.window?.screen, screen)
        // 不退回 → 收起
        w.update(spec: ExternalDisplaySpec(displayID: bogus, source: .program, fallbackToMain: false))
        XCTAssertEqual(w.status, .waitingForDisplay(displayID: bogus))
        XCTAssertFalse(w.isShowing)
        XCTAssertEqual(statuses, [.showing(displayID: id), .fallbackToMain(displayID: bogus), .waitingForDisplay(displayID: bogus)])
    }

    /// 管理器：按输出表增删窗口（多窗口），设置变了更新，Aux 输入映射到多画面格子，显示器变化通知到每个窗口。
    func testManager_reconcileCreatesUpdatesClosesWindows_multipleWindows() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        launchApp()
        let source = try FakeDisplaySource()
        source.start()
        defer { source.stop() }
        let manager = ExternalDisplayManager(source: source.source)
        defer { manager.closeAll() }
        let id = ExternalDisplays.id(of: screen)
        var statusLog: [(Int, ExternalDisplayWindow.Status)] = []
        manager.onStatusChange = { statusLog.append(($0, $1)) }
        let inputs = [InputConfig(number: 1, name: "a", source: .image(path: "/a.png")), InputConfig(number: 2, name: "b", source: .image(path: "/b.png"))]
        func output(_ n: Int, _ spec: ExternalDisplaySpec, enabled: Bool = true) -> OutputState {
            OutputState(number: n, kind: .externalDisplay, name: "外部 \(n)", enabled: enabled, settings: spec.outputSettings)
        }
        var outputs = [
            OutputState(number: 1, kind: .record, name: "录制"),
            output(2, ExternalDisplaySpec(displayID: id, source: .program)),
            output(3, ExternalDisplaySpec(displayID: id, source: .input(number: 2))),
            output(4, ExternalDisplaySpec(displayID: 0xDEAD_BEEF, source: .preview), enabled: false),
        ]
        manager.reconcile(outputs: outputs, inputs: inputs, format: .hd1080p60)
        XCTAssertEqual(Set(manager.windows.keys), [2, 3], "enabled 的外部显示输出各一个窗口；录制 / 关着的不算")
        XCTAssertEqual(manager.windows[2]?.displayView.target, .program)
        XCTAssertEqual(manager.windows[3]?.displayView.target, .multiview)
        XCTAssertEqual(manager.windows[3]?.displayView.sourceRect, MultiviewLayout.inputCell(index: 1, inputCount: 2, width: 1920, height: 1080))
        XCTAssertEqual(statusLog.map(\.0).sorted(), [2, 3])
        pump(seconds: 0.5)
        XCTAssertGreaterThan(manager.windows[2]!.displayView.presentedFrames + manager.windows[3]!.displayView.presentedFrames, 0)
        // 改 3 号的源、开 4 号、删 2 号
        outputs[2] = output(3, ExternalDisplaySpec(displayID: id, source: .multiview))
        outputs[3] = output(4, ExternalDisplaySpec(displayID: 0xDEAD_BEEF, source: .preview), enabled: true)
        outputs.remove(at: 1)
        let old2 = manager.windows[2]
        manager.reconcile(outputs: outputs, inputs: inputs, format: .hd1080p60)
        XCTAssertEqual(Set(manager.windows.keys), [3, 4])
        XCTAssertEqual(old2?.isShowing, false, "删掉的输出窗口应关掉")
        XCTAssertEqual(manager.windows[3]?.displayView.sourceRect, .full)
        XCTAssertEqual(manager.windows[4]?.status, .waitingForDisplay(displayID: 0xDEAD_BEEF))
        XCTAssertEqual(manager.windows[4]?.isShowing, false)
        // 显示器变化通知：每个窗口重新找屏（没变化不动）
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        pump(seconds: 0.1)
        XCTAssertGreaterThanOrEqual(manager.screenChanges, 1)
        XCTAssertEqual(manager.windows[3]?.status, .showing(displayID: id))
        // 提案 013：每个窗口在 Stats 里一项，frames 随呈现递增，state 在 013 的列表里
        let entries = manager.statsEntries
        XCTAssertEqual(entries.map(\.output), [3, 4], "按输出编号升序，每个窗口一项")
        XCTAssertTrue(entries.allSatisfy { $0.kind == "externalDisplay" })
        XCTAssertTrue(entries.allSatisfy { Stats.DisplayEntry.states.contains($0.state) }, "\(entries.map(\.state))")
        XCTAssertEqual(entries.first { $0.output == 3 }?.state, "presenting")
        XCTAssertEqual(entries.first { $0.output == 4 }?.state, "noDisplay", "显示器不在 → noDisplay")
        let before = try XCTUnwrap(entries.first { $0.output == 3 }).frames
        pump(seconds: 0.5)
        let after = try XCTUnwrap(manager.statsEntries.first { $0.output == 3 }).frames
        XCTAssertGreaterThan(after, before, "在显示的窗口 frames 应随呈现递增")
        XCTAssertEqual(after, manager.windows[3]!.displayView.presentedFrames, "与 MetalDisplayView.presentedFrames 同源（铁律 4）")

        manager.closeAll()
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertTrue(manager.statsEntries.isEmpty)
    }

    /// L2 端到端（秒表法）：镜头前的手机毫秒秒表 → 外部显示上的 PGM，1/1000 s 快门同时拍下两者读差，5 次取中位数，另测摄像头直连显示器作扣除。
    func testL2_externalDisplayStopwatch_manual() throws {
        if NSScreen.screens.count < 2 {
            throw XCTSkip("BLOCKED-硬件：本机只有内置屏，没有外接显示器；解锁条件 = 接一块 HDMI 显示器 + 摄像头 + 手机秒表，按 reports/w3-outputs2.md §2 的 L2 步骤人工测 5 次")
        }
        throw XCTSkip("L2 秒表法是人工测量（测试标准 §3 L2），结果写 reports/w3-outputs2.md")
    }
}
