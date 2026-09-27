// 外部显示（W3-C 交付 1）：全屏窗口在指定显示器、源可选、插拔处理、多窗口。"指定显示器"= 主屏，"拔掉"用一个不存在的显示器 ID 模拟，
// 插回 = 改回主屏 ID（真外接屏上的用例在 DisplayStatsTests，本机接着一块时跑）。纹理来源是真的 MetalRenderer（每 1/60 s 换版本）。
// W3-C2：Aux（source = 输入 n）不再取多画面格子，改由 AuxInputView 画该路帧槽分支里的全分辨率帧（AuxInputTests）。
@preconcurrency import Metal
import AppKit
import Darwin
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import SwitcherExternal

/// 纹理来源：真的 MetalRenderer（DisplayFrame 的构造器不公开，伪造不了），后台线程按节目时钟（默认 60 Hz）渲染一个没有输入的黑场状态。
final class FakeDisplaySource: @unchecked Sendable {
    let renderer: MetalRenderer
    let frameRate: FrameRate
    private final class Flag: Sendable { let value = Atomic<Bool>(false) }
    private let stopFlag = Flag()
    private var thread: Thread?

    init(frameRate: FrameRate = .fps60) throws {
        self.frameRate = frameRate
        renderer = try MetalRenderer()
        try renderer.prepare(format: .hd720p60, maxInputs: 3)
    }

    func start() {
        let t = Thread { [renderer, stopFlag, frameRate] in
            let spec = TickClockSpec(t0: .now(), frameRate: frameRate)
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
        // 与真渲染线程一样是高优先级（引擎的渲染线程是 time-constraint 线程）：默认优先级在别的会话跑测试时会被拖后、再连着补渲几拍，
        // 两帧落进同一次显示刷新就被覆盖——那是夹具不像真的，不是显示侧掉帧
        t.qualityOfService = .userInteractive
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

    /// 提案 013：显示器 ID / 退回策略读写正式字段 `OutputSettings.display`。W3-C2 删了过渡键的后备读取（P3 报告 §4 第 1 条）：
    /// 旧键 extra["displayID"] / ["fallbackToMain"] 一律忽略（`Show.load` 已把旧节目文件里的它们搬进正式字段）；写出照旧顺手清掉。
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
        // 什么都没有（没有正式字段）：主屏 + 不退回——= DisplayOutputSettings 的默认（提案 015：fallbackToMain 默认 false）
        XCTAssertEqual(ExternalDisplaySpec(settings: OutputSettings(source: .program)),
                       ExternalDisplaySpec(displayID: nil, source: .program, fallbackToMain: false))
        XCTAssertEqual(ExternalDisplaySpec(settings: OutputSettings(source: .program)).fallbackToMain, DisplayOutputSettings().fallbackToMain)
        // 旧键被忽略：正式字段为 nil 时不再读 extra（没经过 Show.load 的内存状态也一样）
        var legacy = OutputSettings(source: .preview)
        legacy.extra[ExternalDisplaySpec.displayIDKey] = .number(12345)
        legacy.extra[ExternalDisplaySpec.fallbackKey] = .bool(true)
        XCTAssertEqual(ExternalDisplaySpec(settings: legacy), ExternalDisplaySpec(displayID: nil, source: .preview, fallbackToMain: false),
                       "过渡键不再作后备")
        // 有正式字段就只看正式字段，旧键在不在都一样
        legacy.display = DisplayOutputSettings(displayID: 999, fallbackToMain: true)
        XCTAssertEqual(ExternalDisplaySpec(settings: legacy), ExternalDisplaySpec(displayID: 999, source: .preview, fallbackToMain: true))
        // 写回：只写正式字段，旧键顺手清掉
        ExternalDisplaySpec(settings: legacy).apply(to: &legacy)
        XCTAssertNil(legacy.extra[ExternalDisplaySpec.displayIDKey])
        XCTAssertNil(legacy.extra[ExternalDisplaySpec.fallbackKey])
        // 源的显示名不在包里（W3-C3 删了 ExternalDisplaySpec.describe，App 用 OutputSource.title(in:) 查表）
    }

    /// W3-C3：窗口标题是包里唯一非有不可的文字——默认 ASCII，组装方（App）可以传本地化后的；管理器下发给现有的和以后开的窗口。
    /// 目标显示器用不存在的 ID：窗口收起等它，不在屏上闪。
    func testL10n_windowTitleDefaultsToASCIIAndIsInjectable() throws {
        launchApp()
        let source = try FakeDisplaySource()
        let manager = ExternalDisplayManager(source: source.source)
        defer { manager.closeAll() }
        XCTAssertEqual(ExternalDisplayWindow.defaultWindowTitle, "Switcher External Output")
        XCTAssertTrue(ExternalDisplayWindow.defaultWindowTitle.unicodeScalars.allSatisfy(\.isASCII))
        func output(_ n: Int) -> OutputState {
            OutputState(number: n, kind: .externalDisplay, name: "外部 \(n)", enabled: true,
                        settings: ExternalDisplaySpec(displayID: 0xDEAD_BEEF, source: .program).outputSettings)
        }
        manager.reconcile(outputs: [output(1)], inputs: [], format: .hd1080p60)
        XCTAssertEqual(manager.windowTitle, ExternalDisplayWindow.defaultWindowTitle)
        XCTAssertEqual(manager.windows[1]?.window?.title, ExternalDisplayWindow.defaultWindowTitle)
        manager.windowTitle = "Switcher 外部输出"   // App 按本地化表给
        XCTAssertEqual(manager.windows[1]?.windowTitle, "Switcher 外部输出")
        XCTAssertEqual(manager.windows[1]?.window?.title, "Switcher 外部输出", "现有窗口跟着换")
        manager.reconcile(outputs: [output(1), output(2)], inputs: [], format: .hd1080p60)
        XCTAssertEqual(manager.windows[2]?.window?.title, "Switcher 外部输出", "以后开的窗口也用它")
        let lone = ExternalDisplayWindow(spec: ExternalDisplaySpec(displayID: 0xDEAD_BEEF), source: nil, windowTitle: "Aux")
        defer { lone.closeOutput() }
        XCTAssertEqual(lone.window?.title, "Aux", "直接建窗口也能传")
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
        // 换源：PVW → 多画面 → 输入 2（Aux：AuxInputView 画该路帧槽分支的全分辨率帧，显示视图收起）
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .preview))
        XCTAssertEqual(w.displayView.target, .preview)
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .multiview))
        XCTAssertEqual(w.displayView.target, .multiview)
        XCTAssertEqual(w.displayView.sourceRect, .full)
        XCTAssertTrue(w.auxView.isHidden)
        let inputs = [InputConfig(number: 1, name: "a", source: .image(path: "/a.png")), InputConfig(number: 2, name: "b", source: .image(path: "/b.png"))]
        var opened: [Int] = [], closed: [Int] = []
        let slot2 = TestFrameSlot()
        w.auxFrames = AuxFrameTap(open: { n in opened.append(n); return n == 2 ? slot2 : nil }, close: { n, _ in closed.append(n) })
        w.apply(inputs: inputs, textureWidth: 1920, textureHeight: 1080)
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .input(number: 2)))
        XCTAssertTrue(w.displayView.isHidden, "Aux 不再用多画面纹理")
        XCTAssertFalse(w.auxView.isHidden)
        XCTAssertEqual(w.auxView.presenter.input, 2)
        XCTAssertEqual(opened, [2], "开窗口时给这路开一个帧槽分支")
        XCTAssertFalse(w.auxUnresolved)
        w.apply(inputs: [inputs[0]], textureWidth: 1920, textureHeight: 1080)   // 输入 2 被删
        XCTAssertTrue(w.auxUnresolved, "找不到那路输入：画占位")
        XCTAssertEqual(closed, [2], "那路没了就把分支还回去")
        XCTAssertTrue(w.displayView.isHidden)
        XCTAssertFalse(w.auxView.isHidden)
        w.update(spec: ExternalDisplaySpec(displayID: id, source: .program))
        XCTAssertFalse(w.displayView.isHidden)
        XCTAssertTrue(w.auxView.isHidden)
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

    /// 管理器：按输出表增删窗口（多窗口），设置变了更新，Aux 输入交给 AuxInputView（帧槽分支按需开 / 还），显示器变化通知到每个窗口。
    func testManager_reconcileCreatesUpdatesClosesWindows_multipleWindows() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        launchApp()
        let source = try FakeDisplaySource()
        source.start()
        defer { source.stop() }
        let manager = ExternalDisplayManager(source: source.source)
        defer { manager.closeAll() }
        let slot = TestFrameSlot()
        var opened: [Int] = [], closed: [Int] = []
        manager.auxFrames = AuxFrameTap(open: { n in opened.append(n); return slot }, close: { n, _ in closed.append(n) })
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
        XCTAssertEqual(manager.windows[3]?.auxView.presenter.input, 2, "Aux：本包自己画输入 2 的帧")
        XCTAssertEqual(manager.windows[3]?.displayView.isHidden, true)
        XCTAssertEqual(opened, [2])
        XCTAssertEqual(statusLog.map(\.0).sorted(), [2, 3])
        pump(seconds: 0.5)
        XCTAssertGreaterThan(manager.windows[2]!.displayView.presentedFrames, 0)
        // 改 3 号的源、开 4 号、删 2 号
        outputs[2] = output(3, ExternalDisplaySpec(displayID: id, source: .multiview))
        outputs[3] = output(4, ExternalDisplaySpec(displayID: 0xDEAD_BEEF, source: .preview), enabled: true)
        outputs.remove(at: 1)
        let old2 = manager.windows[2]
        manager.reconcile(outputs: outputs, inputs: inputs, format: .hd1080p60)
        XCTAssertEqual(Set(manager.windows.keys), [3, 4])
        XCTAssertEqual(old2?.isShowing, false, "删掉的输出窗口应关掉")
        XCTAssertEqual(manager.windows[3]?.displayView.sourceRect, .full)
        XCTAssertEqual(manager.windows[3]?.displayView.target, .multiview)
        XCTAssertEqual(closed, [2], "3 号从 Aux 换成多画面：分支还回去")
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
        XCTAssertEqual(after, manager.windows[3]!.presentedFrames, "与窗口的呈现计数同源（铁律 4）")
        XCTAssertEqual(after, manager.windows[3]!.displayView.presentedFrames + manager.windows[3]!.auxView.presentedFrames)

        manager.closeAll()
        XCTAssertTrue(manager.windows.isEmpty)
        XCTAssertTrue(manager.statsEntries.isEmpty)
    }

    /// L2 端到端（秒表法）：镜头前的手机毫秒秒表 → 外部显示上的 PGM，1/1000 s 快门同时拍下两者读差，5 次取中位数，另测摄像头直连显示器作扣除。
    func testL2_externalDisplayStopwatch_manual() throws {
        if NSScreen.screens.count < 2 {
            throw XCTSkip("BLOCKED-硬件：本机只有内置屏，没有外接显示器；解锁条件 = 接一块外接显示器 + 摄像头 + 手机毫秒秒表，按 reports/w3-outputs-3.md §2 的 L2 步骤人工测 5 次")
        }
        throw XCTSkip("BLOCKED-硬件（人工）：L2 秒表法要摄像头 + 手机秒表 + 高速快门拍照（测试标准 §3 L2），步骤在 reports/w3-outputs-3.md §2，下一版写进 docs/checklists")
    }
}
