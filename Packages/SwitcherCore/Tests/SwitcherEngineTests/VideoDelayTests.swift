import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// W1-B4（prompt 105，提案 028）：视频延后 L。渲染完成的帧在 tickTime = 拍点 + Lₙ 到期时才交给消费者；
/// Lₙ 跟着设定值每帧最多改 1/4 拍（tickTime 严格递增、不丢不重）；L = 0 且队列空时仍在完成线程直接派发（与以前逐行相同）。
/// 延迟队列预分配，深度 = ⌈maxDelay / 拍长⌉ + 1（35 ms @ 60 fps = 4）；渲染线程、完成线程、派发线程零分配。
final class VideoDelayTests: XCTestCase {
    func makeEngine(renderer: FakeRenderer, options: EngineOptions = EngineOptions(), format: ProgramFormat = .hd1080p60) -> Engine {
        var state = ReducerTests.baseState()
        state.format = format
        return Engine(stateMachine: StateMachine(initialState: state), renderer: renderer, maxInputs: 8, options: options)
    }

    /// 60 fps 的拍长（host tick）。
    static let period = TickClockSpec(t0: .zero, frameRate: .fps60).duration(ofTicks: 1)

    /// 设定 12 ms：每帧 tickTime = 拍点 + 12 ms（program.pts 仍是拍点），在 tickTime 到期时派发（实时线程，晚醒 ≤ 1 拍），
    /// 派发时刻比渲染完成（gpuEnd，假 GPU 2 ms）晚 ≈ 10 ms；一帧不丢、不重、不乱序；不在完成线程上派发。
    func testAV_videoDelay_dispatchAtTickTimePlusDelay() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
        let engine = makeEngine(renderer: renderer)
        let rec = TimingConsumer(name: "timing", capacity: 512)
        engine.addConsumer(rec)
        engine.addConsumer(CountingConsumer(name: "b"))
        let delay = HostDuration(milliseconds: 12)
        engine.setVideoDelayTarget(delay)
        XCTAssertEqual(engine.videoDelayTarget, delay)
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 30), lastTick: Tick(179))
        engine.clock!.join()
        renderer.waitForCompletion()
        XCTAssertTrue(waitUntil(timeout: 2) { rec.received == 180 }, "收到 \(rec.received)")
        await engine.stop()
        let completionThread = renderer.completionThread.load(ordering: .relaxed)
        var lateness: [Double] = [], afterGPU: [Double] = []
        for n in 0..<180 {
            let e = try XCTUnwrap(rec.entry(n), "第 \(n) 拍没派发")
            XCTAssertEqual(e.tickTime - e.pts, delay, "第 \(n) 拍：tickTime = 拍点 + 12 ms（program.pts 不动）")
            XCTAssertEqual(e.pts, engine.clock!.spec.time(of: Tick(Int64(n))), "program.pts 仍是理想拍点")
            XCTAssertNotEqual(e.thread, completionThread, "延后的帧在派发线程上派发，不占完成线程")
            lateness.append((e.dispatched - e.tickTime).milliseconds)
            afterGPU.append((e.dispatched - e.gpuEnd).milliseconds)
        }
        let sorted = lateness.sorted()
        print("W1-B4 延后 12 ms：派发 − 到期 中位 \(String(format: "%.3f", sorted[90])) / 最大 \(String(format: "%.3f", sorted.last!)) ms；派发 − 渲染完成 平均 \(String(format: "%.3f", afterGPU.reduce(0, +) / 180)) ms")
        XCTAssertGreaterThanOrEqual(sorted.first!, -0.01, "不提前派发")
        XCTAssertLessThanOrEqual(sorted[90], 1, "派发线程按到期时刻醒（实时策略）")
        XCTAssertLessThanOrEqual(sorted.last!, Self.period.milliseconds, "最晚也在一拍之内")
        for a in afterGPU { XCTAssertEqual(a, 12, accuracy: Self.period.milliseconds, "派发比渲染完成晚 12 ms ± 1 拍") }
        XCTAssertEqual(rec.duplicates, 0)
        XCTAssertEqual(rec.outOfOrder, 0)
        XCTAssertEqual(rec.ptsRegressions, 0)
        XCTAssertEqual(engine.videoDelayApplied, delay)
        XCTAssertEqual(engine.counters.videoDelayApplied, delay)
        XCTAssertEqual(engine.counters.videoDelayMs, 12, accuracy: 1e-6)
        XCTAssertEqual(engine.counters.framesDelayed, 180)
        XCTAssertEqual(engine.counters.videoDelayOverflow, 0)
        XCTAssertLessThanOrEqual(engine.counters.videoDelayQueueMax, engine.videoDelayQueueCapacity)
        XCTAssertEqual(engine.counters.framesDispatched, 360, "两个消费者各 180")
    }

    /// 设定为 0（默认）：完成线程直接派发（与 W1-B 以来的路径相同），tickTime 不动、不经过延迟队列。gate4 不带效果，就是这条路。
    func testAV_videoDelay_zeroDelayDispatchesDirectlyOnCompletionThread() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
        let engine = makeEngine(renderer: renderer)
        let rec = TimingConsumer(name: "timing", capacity: 256)
        engine.addConsumer(rec)
        XCTAssertEqual(engine.videoDelayTarget, .zero)
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 30), lastTick: Tick(119))
        engine.clock!.join()
        renderer.waitForCompletion()
        await engine.stop()
        let completionThread = renderer.completionThread.load(ordering: .relaxed)
        XCTAssertEqual(rec.received, 120)
        for n in 0..<120 {
            let e = try XCTUnwrap(rec.entry(n))
            XCTAssertEqual(e.tickTime, e.pts, "L = 0：tickTime = 拍点")
            XCTAssertEqual(e.thread, completionThread, "L = 0：在完成线程上直接派发")
            XCTAssertLessThan((e.dispatched - e.gpuEnd).milliseconds, 1, "不等")
        }
        XCTAssertEqual(engine.counters.framesDelayed, 0)
        XCTAssertEqual(engine.counters.videoDelayMs, 0)
    }

    /// 运行中设定值跳变（0 → 35 → 0 → 20 → 5 ms）：Lₙ 每帧最多改 1/4 拍，相邻 tickTime 间隔在 [¾, 1¼] 拍内（严格递增），
    /// 每一拍恰好派发一次、按序；稳态 Lₙ = 设定值；最后停在 5 ms。
    func testAV_videoDelay_targetChangesSlewWithoutDropDupOrPTSRegression() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        let engine = makeEngine(renderer: renderer)
        let rec = TimingConsumer(name: "timing", capacity: 512)
        engine.addConsumer(rec)
        let schedule: [(tick: Int64, ms: Double)] = [(60, 35), (150, 0), (240, 20), (330, 5)]
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 30), lastTick: Tick(419))
        for step in schedule {
            XCTAssertTrue(waitUntil(timeout: 10) { (engine.counters.lastTick?.rawValue ?? -1) >= step.tick })
            engine.setVideoDelayTarget(HostDuration(milliseconds: step.ms))
        }
        engine.clock!.join()
        renderer.waitForCompletion()
        XCTAssertTrue(waitUntil(timeout: 2) { rec.received == 420 }, "收到 \(rec.received)")
        await engine.stop()
        XCTAssertEqual(rec.duplicates, 0)
        XCTAssertEqual(rec.outOfOrder, 0)
        XCTAssertEqual(rec.ptsRegressions, 0, "tickTime 严格递增")
        let maxStep = Self.period.ticks / 4
        var prev: (tick: Int, entry: TimingConsumer.Entry)?
        var maxDelta: Int64 = 0
        var delivered = 0
        for n in 0..<420 {
            guard let e = rec.entry(n) else { continue }   // 时钟跳过的拍（机器忙时 missed_render）没有帧
            delivered += 1
            if let p = prev {
                let g = Int64(n - p.tick)
                let gap = (e.tickTime - p.entry.tickTime).ticks
                XCTAssertGreaterThanOrEqual(gap, g * (Self.period.ticks - maxStep) - 1, "第 \(n) 拍：间隔 ≥ ¾ 拍")
                XCTAssertLessThanOrEqual(gap, g * (Self.period.ticks + maxStep) + 1, "第 \(n) 拍：间隔 ≤ 1¼ 拍")
                let delta = abs((e.tickTime - e.pts).ticks - (p.entry.tickTime - p.entry.pts).ticks)
                maxDelta = max(maxDelta, delta / g)
                XCTAssertLessThanOrEqual(delta, g * maxStep, "第 \(n) 拍：Lₙ 每拍最多改 1/4 拍")
            }
            prev = (n, e)
        }
        XCTAssertEqual(UInt64(delivered) + engine.counters.missedRender, 420, "每一拍要么派发一次、要么是时钟跳过的拍")
        print("W1-B4 设定跳变：Lₙ 每帧最大改动 \(String(format: "%.3f", HostDuration(ticks: maxDelta).milliseconds)) ms（上限 \(String(format: "%.3f", HostDuration(ticks: maxStep).milliseconds))）")
        // 稳态：每段末尾 Lₙ = 那一段的设定值（35 ms 要 ⌈35 / 4.17⌉ = 9 帧爬上去，每段都留了 ≥ 60 帧）
        for (i, step) in schedule.enumerated() {
            let end = i + 1 < schedule.count ? Int(schedule[i + 1].tick) - 1 : 419
            let e = try XCTUnwrap(rec.entry(end - 5))
            XCTAssertEqual((e.tickTime - e.pts).milliseconds, step.ms, accuracy: 0.001, "第 \(end - 5) 拍应已到 \(step.ms) ms")
        }
        XCTAssertEqual(engine.videoDelayApplied, HostDuration(milliseconds: 5))
        XCTAssertEqual(engine.counters.videoDelayOverflow, 0)
    }

    /// 停的时候队列里还压着的帧（延后 30 ms、跑满 60 拍马上停）全部派发出去，一帧不留在队列里。
    func testAV_videoDelay_stopDrainsPendingFrames() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        let engine = makeEngine(renderer: renderer)
        let rec = TimingConsumer(name: "timing", capacity: 128)
        engine.addConsumer(rec)
        engine.setVideoDelayTarget(HostDuration(milliseconds: 30))
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 30), lastTick: Tick(59))
        engine.clock!.join()
        renderer.waitForCompletion()
        await engine.stop()
        XCTAssertEqual(rec.received, 60, "停之前压在延迟队列里的帧也派发了")
        XCTAssertEqual(rec.outOfOrder, 0)
        XCTAssertEqual(rec.ptsRegressions, 0)
        XCTAssertEqual(engine.counters.framesDelayed, 60)
    }

    /// 设定值钳到 [0, maxDelay]（默认 35 ms）；队列深度 = ⌈maxDelay / 拍长⌉ + 1：60 fps 4、30 fps 3、24 fps 2。
    /// 引擎就是 VideoDelayControl（音频引擎按这个协议把 Master 效果链的实测延迟交过来）。
    func testAV_videoDelay_targetClampedAndQueueDepthFromMaxDelay() {
        let engine = makeEngine(renderer: FakeRenderer())
        XCTAssertEqual(engine.options.videoDelay.maxDelay, HostDuration(milliseconds: 35))
        engine.setVideoDelayTarget(HostDuration(milliseconds: 100))
        XCTAssertEqual(engine.videoDelayTarget, HostDuration(milliseconds: 35))
        engine.setVideoDelayTarget(HostDuration(milliseconds: -3))
        XCTAssertEqual(engine.videoDelayTarget, .zero)
        let control: any VideoDelayControl = engine
        control.setVideoDelayTarget(HostDuration(milliseconds: 7))
        XCTAssertEqual(engine.videoDelayTarget, HostDuration(milliseconds: 7))
        XCTAssertEqual(engine.videoDelayQueueCapacity, 4, "35 ms @ 60 fps = 3 帧 + 1")
        XCTAssertEqual(makeEngine(renderer: FakeRenderer(), format: ProgramFormat(width: 1920, height: 1080, frameRate: .fps30)).videoDelayQueueCapacity, 3)
        XCTAssertEqual(makeEngine(renderer: FakeRenderer(), format: ProgramFormat(width: 1920, height: 1080, frameRate: .fps24)).videoDelayQueueCapacity, 2)
        var options = EngineOptions()
        options.videoDelay.maxDelay = HostDuration(milliseconds: 100)
        XCTAssertEqual(makeEngine(renderer: FakeRenderer(), options: options).videoDelayQueueCapacity, 7, "100 ms @ 60 fps = 6 帧 + 1")
    }

    /// L1（提案 005：帧交给第一个消费者的那一刻 − ingressTime）在延后之后量：延后 12 ms 的 L1 比不延后的多 ≈ 12 − 2 ms（假 GPU 2 ms 被延后吸收）。
    func testAV_videoDelay_l1LatencyIncludesDelay() async throws {
        func runL1(delayMs: Double) async throws -> Double {
            let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
            let engine = makeEngine(renderer: renderer)
            let slot = LockFreeFrameSlot(capacity: 3)
            engine.registerInput(number: 1, slot: slot)
            engine.addConsumer(CountingConsumer(name: "a"))
            engine.setVideoDelayTarget(HostDuration(milliseconds: delayMs))
            let t0 = HostClock.now() + HostDuration(milliseconds: 50)
            let running = EngineTests.RunFlag()
            let producer = try Self.startProducer(slot: slot, input: 1, spec: TickClockSpec(t0: t0 - HostDuration(milliseconds: 8), frameRate: .fps60),
                                                  delay: HostDuration(milliseconds: 1), running: running)
            try await engine.start(t0: t0, lastTick: Tick(179))
            engine.clock!.join()
            running.stop()
            producer.join()
            renderer.waitForCompletion()
            await engine.stop()
            return engine.makeStats().perInput[1]!.latencyMs
        }
        let base = try await runL1(delayMs: 0)
        let delayed = try await runL1(delayMs: 12)
        print("W1-B4 L1：不延后 \(String(format: "%.3f", base)) ms，延后 12 ms \(String(format: "%.3f", delayed)) ms（多 \(String(format: "%.3f", delayed - base))）")
        XCTAssertEqual(delayed - base, 10, accuracy: 2, "L1 含延后（12 ms 减去被吸收的 2 ms 假 GPU）")
    }

    /// prompt 105 交付 1 的零分配：渲染线程（不变）、完成线程（算 Lₙ、入队 / 直接派发）、派发线程（等到期、出队、调消费者）稳态 0 次 malloc。
    /// 盯的那段时间里设定值来回改（12 → 30 → 0 → 20 ms），直接派发、入队派发、slew 三条路都走到。
    func testAV_videoDelayQueueZeroAllocation() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
        let engine = makeEngine(renderer: renderer)
        let rec = TimingConsumer(name: "timing", capacity: 1024)
        engine.addConsumer(rec)
        engine.addConsumer(CountingConsumer(name: "b"))
        let slots = [LockFreeFrameSlot(capacity: 3), LockFreeFrameSlot(capacity: 3)]
        engine.registerInput(number: 1, slot: slots[0])
        engine.registerInput(number: 2, slot: slots[1])
        let t0 = HostClock.now() + HostDuration(milliseconds: 30)
        let running = EngineTests.RunFlag()
        let inputSpec = TickClockSpec(t0: t0 - HostDuration(milliseconds: 6), frameRate: .fps60)
        let producers = try (0..<2).map { i in
            try Self.startProducer(slot: slots[i], input: i + 1, spec: inputSpec, delay: HostDuration(milliseconds: 1), running: running)
        }
        engine.setVideoDelayTarget(HostDuration(milliseconds: 12))
        try await engine.start(t0: t0, lastTick: Tick(479))
        XCTAssertTrue(waitUntil(timeout: 5) { engine.counters.ticksDispatched >= 60 && rec.received >= 50 })
        let completionThread = renderer.completionThread.load(ordering: .relaxed)
        let dispatchThread = engine.videoDelayDispatchThreadPort
        let renderThread = renderer.renderThread.load(ordering: .relaxed)
        XCTAssertNotEqual(dispatchThread, 0)
        guard AllocationProbe.start(watching: completionThread, second: dispatchThread, third: renderThread) else {
            throw XCTSkip("BLOCKED-SDK：本系统没有 malloc_logger 导出符号")
        }
        let startTick = engine.counters.ticksDispatched
        for (tick, ms) in [(120.0, 30.0), (200, 0), (280, 20)] {
            _ = waitUntil(timeout: 6) { Double(engine.counters.ticksDispatched) >= tick }
            engine.setVideoDelayTarget(HostDuration(milliseconds: ms))
        }
        // 盯到第 440 拍：线程退出时 _pthread_tsd_cleanup 会 free，那不是派发路径
        XCTAssertTrue(waitUntil(timeout: 8) { engine.counters.ticksDispatched >= 440 })
        let observed = engine.counters.ticksDispatched - startTick
        let delayedDuring = engine.counters.framesDelayed
        let probe = AllocationProbe.stop()
        engine.clock!.join()
        running.stop()
        producers.forEach { $0.join() }
        renderer.waitForCompletion()
        await engine.stop()
        print("W1-B4 零分配：盯 \(observed) 拍，经延迟队列 \(delayedDuring) 帧；完成线程 malloc \(probe.allocations) / free \(probe.deallocations)，派发线程 malloc \(probe.secondAllocations)，渲染线程 malloc \(probe.thirdAllocations)")
        XCTAssertGreaterThanOrEqual(observed, 300)
        XCTAssertGreaterThan(delayedDuring, 100, "延迟队列那条路走到了")
        XCTAssertEqual(probe.allocations, 0, "完成线程（算 Lₙ / 入队 / 直接派发）稳态内有 malloc")
        XCTAssertEqual(probe.deallocations, 0, "完成线程稳态内有 free")
        XCTAssertEqual(probe.secondAllocations, 0, "派发线程（等到期 / 出队 / 调消费者）稳态内有 malloc")
        XCTAssertEqual(probe.thirdAllocations, 0, "渲染线程稳态内有 malloc")
        XCTAssertEqual(rec.duplicates + rec.outOfOrder + rec.ptsRegressions, 0)
        XCTAssertEqual(engine.counters.missedRender, 0)
        XCTAssertEqual(engine.counters.videoDelayOverflow, 0)
    }
}

extension VideoDelayTests {
    /// 真线程生产者（同 EngineTests.startProducer）：帧 k 的 pts = 输入时钟第 k 拍，pts + delay 到达。
    static func startProducer(slot: any FrameSlot & Sendable, input: Int, spec: TickClockSpec, delay: HostDuration,
                              running: EngineTests.RunFlag) throws -> NativeThread {
        let period = UInt32(clamping: spec.duration(ofTicks: 1).ticks)
        let config = NativeThreadConfig(name: "producer-av-\(input)", qos: QOS_CLASS_USER_INTERACTIVE,
                                        timeConstraint: .init(period: period, computation: period / 10, constraint: period / 2))
        let t = NativeThread(config: config) {
            var k: Int64 = 0
            while running.value.load(ordering: .acquiring) {
                let pts = spec.time(of: Tick(k))
                mach_wait_until((pts + delay).ticks)
                slot.push(TestFrames.frame(input: input, sequence: UInt64(k), pts: pts, ingress: HostClock.now()))
                k += 1
            }
        }
        try t.start()
        return t
    }
}

/// 记每拍的派发时刻 / tickTime / program.pts / gpuEnd / 派发线程。预分配的原子数组，consume 零分配（零分配用例里它在派发线程上跑）。
final class TimingConsumer: FrameConsumer, @unchecked Sendable {
    struct Entry {
        var tickTime: HostTime
        var pts: HostTime
        var gpuEnd: HostTime
        var dispatched: HostTime
        var thread: UInt32
    }
    let consumerName: String
    let capacity: Int
    private let dispatched: UnsafeMutablePointer<Atomic<UInt64>>
    private let tickTimes: UnsafeMutablePointer<Atomic<UInt64>>
    private let ptss: UnsafeMutablePointer<Atomic<UInt64>>
    private let gpuEnds: UnsafeMutablePointer<Atomic<UInt64>>
    private let threads: UnsafeMutablePointer<Atomic<UInt32>>
    private let receivedValue = Atomic<UInt64>(0)
    private let duplicatesValue = Atomic<UInt64>(0)
    private let outOfOrderValue = Atomic<UInt64>(0)
    private let ptsRegressionsValue = Atomic<UInt64>(0)
    private let lastTick = Atomic<Int64>(Int64.min)
    private let lastTickTime = Atomic<UInt64>(0)

    init(name: String, capacity: Int) {
        consumerName = name
        self.capacity = capacity
        dispatched = .allocate(capacity: capacity)
        tickTimes = .allocate(capacity: capacity)
        ptss = .allocate(capacity: capacity)
        gpuEnds = .allocate(capacity: capacity)
        threads = .allocate(capacity: capacity)
        for i in 0..<capacity {
            (dispatched + i).initialize(to: Atomic(0))
            (tickTimes + i).initialize(to: Atomic(0))
            (ptss + i).initialize(to: Atomic(0))
            (gpuEnds + i).initialize(to: Atomic(0))
            (threads + i).initialize(to: Atomic(0))
        }
    }
    deinit {
        dispatched.deinitialize(count: capacity); dispatched.deallocate()
        tickTimes.deinitialize(count: capacity); tickTimes.deallocate()
        ptss.deinitialize(count: capacity); ptss.deallocate()
        gpuEnds.deinitialize(count: capacity); gpuEnds.deallocate()
        threads.deinitialize(count: capacity); threads.deallocate()
    }

    func consume(_ frame: RenderedFrame) {
        let now = HostClock.now()
        receivedValue.add(1, ordering: .relaxed)
        let prev = lastTick.exchange(frame.tick.rawValue, ordering: .relaxed)
        if frame.tick.rawValue <= prev { outOfOrderValue.add(1, ordering: .relaxed) }
        let prevTime = lastTickTime.exchange(frame.tickTime.ticks, ordering: .relaxed)
        if frame.tickTime.ticks <= prevTime { ptsRegressionsValue.add(1, ordering: .relaxed) }
        let i = Int(frame.tick.rawValue)
        guard i >= 0 && i < capacity else { return }
        if (dispatched + i).pointee.load(ordering: .relaxed) != 0 { duplicatesValue.add(1, ordering: .relaxed) }
        (tickTimes + i).pointee.store(frame.tickTime.ticks, ordering: .relaxed)
        (ptss + i).pointee.store(frame.program.pts.ticks, ordering: .relaxed)
        (gpuEnds + i).pointee.store(frame.gpuEnd.ticks, ordering: .relaxed)
        (threads + i).pointee.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        (dispatched + i).pointee.store(now.ticks, ordering: .releasing)
    }

    var received: UInt64 { receivedValue.load(ordering: .acquiring) }
    var duplicates: UInt64 { duplicatesValue.load(ordering: .acquiring) }
    var outOfOrder: UInt64 { outOfOrderValue.load(ordering: .acquiring) }
    var ptsRegressions: UInt64 { ptsRegressionsValue.load(ordering: .acquiring) }

    func entry(_ tick: Int) -> Entry? {
        guard tick >= 0 && tick < capacity else { return nil }
        let d = (dispatched + tick).pointee.load(ordering: .acquiring)
        guard d != 0 else { return nil }
        return Entry(tickTime: HostTime(ticks: (tickTimes + tick).pointee.load(ordering: .relaxed)),
                     pts: HostTime(ticks: (ptss + tick).pointee.load(ordering: .relaxed)),
                     gpuEnd: HostTime(ticks: (gpuEnds + tick).pointee.load(ordering: .relaxed)),
                     dispatched: HostTime(ticks: d),
                     thread: (threads + tick).pointee.load(ordering: .relaxed))
    }
}
