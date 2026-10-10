// W1-B4（prompt 105，提案 028；用户 2026-10-10 批扩到 SwitcherRender）：显示也延后。
// 主界面监视器 / 外部显示 / 多画面窗口不走 FrameConsumer，直接从渲染器拿纹理；引擎把画面延后 L 派发时，显示源要给"拍点 + L 已到期"的最新一帧，
// 显示与编码器在同一时刻看到同一帧。渲染器为此多留 ⌈L_max / 拍长⌉ 格合成目标（只在开了 displayDelayHistory 时），
// NV12 输出环也加深 ⌈L_max / 拍长⌉ + 1（引擎的延迟队列扣着这些帧的输出缓冲）。
import CoreVideo
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class DisplayDelayTests: XCTestCase {
    /// 闭包能捕获的可变延后值。
    final class DelayBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v = HostDuration.zero
        var value: HostDuration {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }

    private func waitCompleted(_ renderer: MetalRenderer, _ n: UInt64, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while renderer.completed.load(ordering: .acquiring) < n && Date() < deadline { usleep(500) }
    }

    /// 默认不留余量：3 格、输出环 8（与以前相同）；videoDelayHeadroom 35 ms @ 60 fps：输出环 8 + 3 + 1 = 12；再开 displayDelayHistory：合成目标 3 + 3 = 6 格。
    func testAV_displayDelay_headroomSizesSlotsAndOutputRing() throws {
        let plain = try MetalRenderer()
        try plain.prepare(format: .hd720p60, maxInputs: 2)
        XCTAssertEqual(plain.slotCount, 3)
        XCTAssertEqual(plain.outputRingCount, 8)
        plain.shutdown()

        var ringOnly = MetalRendererOptions()
        ringOnly.videoDelayHeadroom = HostDuration(milliseconds: 35)
        let r1 = try MetalRenderer(options: ringOnly)
        try r1.prepare(format: .hd720p60, maxInputs: 2)
        XCTAssertEqual(r1.slotCount, 3, "只给引擎的延迟队列留输出缓冲，不留显示历史")
        XCTAssertEqual(r1.outputRingCount, 12, "8 + ⌈35 / 16.67⌉ + 1")
        r1.shutdown()

        var both = ringOnly
        both.displayDelayHistory = true
        let r2 = try MetalRenderer(options: both)
        try r2.prepare(format: .hd720p60, maxInputs: 2)
        XCTAssertEqual(r2.slotCount, 6, "3 + ⌈35 / 16.67⌉")
        XCTAssertEqual(r2.outputRingCount, 12)
        r2.shutdown()

        let r3 = try MetalRenderer(options: both)
        try r3.prepare(format: ProgramFormat(width: 1280, height: 720, frameRate: .fps30), maxInputs: 2)
        XCTAssertEqual(r3.slotCount, 5, "30 fps：3 + ⌈35 / 33.3⌉")
        XCTAssertEqual(r3.outputRingCount, 11)
        r3.shutdown()
    }

    /// 帧 k 的拍点 = base + k 秒（拍点间隔放大到 1 s，避免测试本身的耗时影响判定），渲染 10 帧：
    /// 延后 2.5 s → 给第 7 帧（拍点 + 2.5 s ≤ 现在的最新一帧）；3.5 s → 第 6 帧；4.5 s 超出历史（6 格、已提交 10 帧，最旧还完整的是第 6 帧）→ 尽量给第 6 帧并计一次不足；
    /// 延后 0 或没给来源 → 最新的第 9 帧（以前的行为）。PGM / PVW / 多画面三个目标给的是同一帧；纹理就是那一帧所在格的纹理。
    func testAV_displayDelay_picksNewestDueFrameWithinHistory() throws {
        var options = MetalRendererOptions()
        options.videoDelayHeadroom = HostDuration(milliseconds: 35)
        options.displayDelayHistory = true
        let renderer = try MetalRenderer(options: options)
        try renderer.prepare(format: .hd720p60, maxInputs: 2)
        renderer.sink = CollectingSink()
        let table = RenderInputTable(capacity: 2)
        let snap = MixerSnapshot(state: MixerState(format: .hd720p60), sequence: 1, tick: .zero)
        let base = HostClock.now() - HostDuration(seconds: 10)
        var textures: [ObjectIdentifier] = []
        for k in 0..<10 {
            XCTAssertEqual(renderer.render(tick: Tick(Int64(k)), at: base + HostDuration(seconds: Double(k)), snapshot: snap, inputs: table), .submitted)
            waitCompleted(renderer, UInt64(k + 1))
            let latest = try XCTUnwrap(renderer.latestDisplayFrame(for: .program))
            XCTAssertEqual(latest.tick, Tick(Int64(k)))
            XCTAssertEqual(latest.version, UInt64(k + 1))
            textures.append(ObjectIdentifier(latest.texture))
        }
        let delay = DelayBox()
        renderer.displayDelayProvider = { delay.value }
        func pick(_ seconds: Double, _ target: DisplayTarget = .program) -> DisplayFrame? {
            delay.value = HostDuration(seconds: seconds)
            return renderer.latestDisplayFrame(for: target)
        }
        let f7 = try XCTUnwrap(pick(2.5))
        XCTAssertEqual(f7.tick, Tick(7))
        XCTAssertEqual(f7.version, 8)
        XCTAssertEqual(ObjectIdentifier(f7.texture), textures[7], "第 7 帧所在格的纹理")
        XCTAssertEqual(pick(2.5, .preview)?.tick, Tick(7))
        XCTAssertEqual(pick(2.5, .multiview)?.tick, Tick(7))
        XCTAssertEqual(pick(3.5)?.tick, Tick(6))
        let before = renderer.displayDelayShortfalls
        XCTAssertEqual(pick(4.5)?.tick, Tick(6), "延后超出历史：给最旧的还完整的一帧")
        XCTAssertEqual(renderer.displayDelayShortfalls, before + 1)
        XCTAssertEqual(pick(0)?.tick, Tick(9), "延后 0：最新完成的一帧")
        XCTAssertEqual(pick(0)?.version, 10)
        renderer.displayDelayProvider = nil
        XCTAssertEqual(renderer.latestDisplayFrame(for: .program)?.tick, Tick(9), "没给来源：以前的行为")
        renderer.shutdown()
    }

    /// 开头还没有到期的帧（第一帧完成了但拍点 + L 还没到）：不给帧（显示保持黑 / 上一帧），不提前把未到期的帧显示出来。
    func testAV_displayDelay_nothingDueYetReturnsNil() throws {
        var options = MetalRendererOptions()
        options.videoDelayHeadroom = HostDuration(milliseconds: 35)
        options.displayDelayHistory = true
        let renderer = try MetalRenderer(options: options)
        try renderer.prepare(format: .hd720p60, maxInputs: 2)
        renderer.sink = CollectingSink()
        let table = RenderInputTable(capacity: 2)
        let snap = MixerSnapshot(state: MixerState(format: .hd720p60), sequence: 1, tick: .zero)
        let base = HostClock.now() + HostDuration(seconds: 10)
        for k in 0..<3 {
            _ = renderer.render(tick: Tick(Int64(k)), at: base + HostDuration(seconds: Double(k)), snapshot: snap, inputs: table)
            waitCompleted(renderer, UInt64(k + 1))
        }
        let delay = DelayBox()
        delay.value = HostDuration(seconds: 1)
        renderer.displayDelayProvider = { delay.value }
        XCTAssertNil(renderer.latestDisplayFrame(for: .program), "一帧都没到期")
        XCTAssertEqual(renderer.displayDelayShortfalls, 0, "不是历史不够，是还没到期")
        delay.value = .zero
        XCTAssertEqual(renderer.latestDisplayFrame(for: .program)?.tick, Tick(2))
        renderer.shutdown()
    }

    /// 输出环够深：消费者那边一直扣着最近 9 帧（引擎延迟队列 4 + 编码器队列 3 + VideoToolbox 在途 2 的量级），
    /// 默认环（8）会被扣满、退回池子分配（渲染线程分配）；videoDelayHeadroom 35 ms 加深到 12 之后一次都不退回。
    func testAV_videoDelayHeadroom_outputRingCoversHeldFrames() throws {
        func fallbacks(headroom: HostDuration) throws -> Int {
            var options = MetalRendererOptions()
            options.multiview = false
            options.videoDelayHeadroom = headroom
            let renderer = try MetalRenderer(options: options)
            try renderer.prepare(format: .hd720p60, maxInputs: 2)
            let state = MixerState(format: .hd720p60, inputs: ReferenceStates.inputs(count: 1), program: 1)
            let engine = FakeEngine(renderer: renderer, format: .hd720p60, inputs: FakeInputs.nv12(count: 1, width: 1280, height: 720), state: state)
            engine.sink.holdDepth = 9
            engine.run(seconds: 1.5)
            let n = renderer.outputFallbackCount
            renderer.shutdown()
            return n
        }
        let plain = try fallbacks(headroom: .zero)
        let deep = try fallbacks(headroom: HostDuration(milliseconds: 35))
        print("W1-B4 输出环：扣着 9 帧时退回池子 默认环 \(plain) 次、加深后 \(deep) 次")
        XCTAssertGreaterThan(plain, 0, "对照：默认 8 个缓冲盖不住扣着的 9 帧 + 在途 2 帧")
        XCTAssertEqual(deep, 0, "加深到 12：一次都不退回池子")
    }
}
