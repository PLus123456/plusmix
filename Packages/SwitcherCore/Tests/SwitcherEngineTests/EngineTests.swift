import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 引擎骨架：时钟 → 快照 → 挑帧 → 渲染器 → 完成回调 → 消费者 → Stats。假渲染器 + 假消费者实跑。
final class EngineTests: XCTestCase {
    func makeEngine(renderer: FakeRenderer, maxInputs: Int = 8) -> Engine {
        let sm = StateMachine(initialState: ReducerTests.baseState())
        return Engine(stateMachine: sm, renderer: renderer, maxInputs: maxInputs)
    }

    /// 10 秒（600 拍）：V5 帧计数 = 600 ± 0；两个消费者各收到 600 帧，顺序无重复。
    func testV5_fakeRendererAndConsumers_10s_frameCount600Exact() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
        let engine = makeEngine(renderer: renderer)
        let a = CountingConsumer(name: "a"), b = CountingConsumer(name: "b")
        engine.addConsumer(a)
        engine.addConsumer(b)
        let slot = LockFreeFrameSlot(capacity: 3)
        engine.registerInput(number: 1, slot: slot)
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 20), lastTick: Tick(599))
        engine.clock!.join()
        renderer.waitForCompletion()
        await engine.stop()
        let c = engine.counters
        XCTAssertEqual(c.ticksDispatched, 600)
        XCTAssertEqual(c.missedRender, 0, "假渲染器瞬间返回，不该跳拍")
        XCTAssertEqual(c.framesSubmitted, 600)
        XCTAssertEqual(c.framesCompleted, 600, "V5：600 拍 = 600 帧，± 0")
        XCTAssertEqual(a.received.load(ordering: .acquiring), 600)
        XCTAssertEqual(b.received.load(ordering: .acquiring), 600)
        XCTAssertEqual(a.outOfOrder.load(ordering: .acquiring), 0)
        XCTAssertEqual(b.outOfOrder.load(ordering: .acquiring), 0)
        XCTAssertEqual(c.snapshotStale, 0, "状态机每拍都赶在渲染线程前面")
        XCTAssertLessThanOrEqual(engine.clock!.jitter.percentile(0.99)!.milliseconds, 4)
    }

    /// 一个慢消费者（每帧 50 ms、队列深 2）不影响其他消费者：快消费者仍收到 600，渲染线程不跳拍。
    func testV5_slowConsumerDoesNotAffectOthers() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        let engine = makeEngine(renderer: renderer)
        let fast = CountingConsumer(name: "fast")
        let slow = SlowConsumer(name: "slow")
        try slow.start()
        engine.addConsumer(slow)
        engine.addConsumer(fast)
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 20), lastTick: Tick(599))
        engine.clock!.join()
        renderer.waitForCompletion()
        await engine.stop()
        slow.stop()
        let c = engine.counters
        XCTAssertEqual(c.framesCompleted, 600)
        XCTAssertEqual(c.missedRender, 0, "慢消费者不许拖渲染线程")
        XCTAssertEqual(fast.received.load(ordering: .acquiring), 600, "快消费者一帧不少")
        XCTAssertEqual(slow.inner.stats.received, 600, "慢消费者的 consume 也每帧被调（立即返回）")
        XCTAssertLessThan(slow.processedCount, 300, "慢消费者自己处理不过来")
        XCTAssertEqual(slow.inner.stats.received, slow.inner.stats.processed + slow.inner.stats.dropped + slow.inner.stats.pending, "慢了丢自己的")
        XCTAssertGreaterThan(slow.inner.stats.dropped, 0)
        XCTAssertEqual(engine.counters.slowConsumeCalls, 0, "没有 consume 超过 1 ms")
    }

    /// 渲染器返回 .skipped 也算 missed_render（T3）；完成帧数相应减少。
    func testV2_rendererSkipVerdictCountsAsMissedRender() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1), skipEvery: 10)
        let engine = makeEngine(renderer: renderer)
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 20), lastTick: Tick(599))
        engine.clock!.join()
        renderer.waitForCompletion()
        await engine.stop()
        let c = engine.counters
        XCTAssertEqual(c.ticksDispatched, 600)
        XCTAssertEqual(c.missedRender, 60)
        XCTAssertEqual(c.framesCompleted, 540)
        XCTAssertEqual(c.framesSubmitted + c.missedRender, 600)
    }

    /// 挑帧用拍点时刻：30 fps 输入进 60 fps 引擎，渲染器每拍拿到的帧序号两两重复，槽统计 reused = consumed / 2。
    func testW1B_engine_picksFramesAtTickTime_30into60() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        let engine = makeEngine(renderer: renderer)
        let slot = LockFreeFrameSlot(capacity: 3)
        engine.registerInput(number: 1, slot: slot)
        let t0 = HostClock.now() + HostDuration(milliseconds: 50)
        // 输入相位比拍点早 8 ms：帧 k 的 pts = t_2k − 8 ms，pts + 1 ms 到达，留足非实时唤醒的余量
        let inputSpec = TickClockSpec(t0: t0 - HostDuration(milliseconds: 8), frameRate: .fps30)
        let running = Atomic<Bool>(true)
        let period = UInt32(clamping: inputSpec.duration(ofTicks: 1).ticks)
        let producerConfig = NativeThreadConfig(name: "producer30", qos: QOS_CLASS_USER_INTERACTIVE,
                                                timeConstraint: .init(period: period, computation: period / 10, constraint: period / 2))
        let producer = NativeThread(config: producerConfig) {
            var k: Int64 = 0
            while running.load(ordering: .acquiring) {
                let pts = inputSpec.time(of: Tick(k))
                mach_wait_until((pts + HostDuration(milliseconds: 1)).ticks)
                slot.push(TestFrames.frame(sequence: UInt64(k), pts: pts, ingress: HostClock.now()))
                k += 1
            }
        }
        try producer.start()
        try await engine.start(t0: t0, lastTick: Tick(299))
        engine.clock!.join()
        running.store(false, ordering: .releasing)
        producer.join()
        renderer.waitForCompletion()
        await engine.stop()
        let seqs = (0..<300).map { renderer.input1Sequence[$0] }
        XCTAssertFalse(seqs.contains(-1), "每拍都有帧")
        // 每帧恰好用两拍；序号单调不减
        var runs: [Int] = []
        var last = seqs[0], len = 1
        for s in seqs.dropFirst() {
            XCTAssertGreaterThanOrEqual(s, last)
            if s == last { len += 1 } else { runs.append(len); last = s; len = 1 }
        }
        XCTAssertEqual(Set(runs), [2], "30 进 60：每帧连续用两拍（首尾不计）")
        let st = slot.stats
        XCTAssertEqual(st.consumed, 300)
        XCTAssertEqual(st.reused * 2, st.consumed, accuracy: 2)
        XCTAssertEqual(st.dropped, 0)
    }

    /// Stats 一行：字段来自引擎计数（铁律 4），能编成 jsonl。
    func testW1B_engine_statsRow() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
        let engine = makeEngine(renderer: renderer)
        let slot = LockFreeFrameSlot(capacity: 3)
        engine.registerInput(number: 2, slot: slot)
        engine.encoderStatsProvider = { [Stats.EncoderEntry(skipped: 3, bitrate: 6_000_000)] }
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 20), lastTick: Tick(119))
        engine.clock!.join()
        renderer.waitForCompletion()
        let stats = engine.makeStats()
        // 第二个窗口：只推 2 帧（容量 3，不挤），窗口 1 s → fps ≈ 2
        let windowStart = HostClock.now()
        for k in 0..<2 { slot.push(TestFrames.frame(input: 2, sequence: UInt64(k), pts: HostClock.now())) }
        usleep(1_000_000)
        let stats2 = engine.makeStats()
        let windowSeconds = (HostClock.now() - windowStart).seconds
        await engine.stop()
        XCTAssertEqual(stats.tick, Tick(119))
        XCTAssertEqual(stats.missedRender, 0)
        XCTAssertEqual(stats.renderMs, 2, accuracy: 1.5, "假 GPU 2 ms 完成")
        XCTAssertLessThan(stats.jitterMs, 4)
        XCTAssertEqual(stats.perInput[2]?.fps, 0, "第一个窗口里这路没推帧")
        XCTAssertEqual(stats2.perInput[2]?.fps ?? 0, 2 / windowSeconds, accuracy: 0.2)
        XCTAssertEqual(stats2.perInput[2]?.dup, 0)
        XCTAssertEqual(stats2.perInput[2]?.drop, 0)
        XCTAssertEqual(stats2.renderMs, 0, "第二个窗口内没有新完成的帧")
        XCTAssertEqual(stats.encoder, [Stats.EncoderEntry(skipped: 3, bitrate: 6_000_000)])
        XCTAssertEqual(stats.audio, Stats.AudioCounters(dropouts: 0, underruns: 0))
        XCTAssertGreaterThan(stats.rssMb, 1)
        XCTAssertGreaterThanOrEqual(stats.cpuPct, 0)
        XCTAssertGreaterThan(stats.ts, 1_700_000_000)
        let line = try stats.jsonLine()
        XCTAssertEqual(try Stats.parse(line: line), stats)
    }

    /// 渲染路径零分配（设计方案 §3.2）：用 malloc_logger 钩子盯渲染线程与 GPU 完成线程，稳态 3 秒内 malloc 次数必须为 0。
    /// 路径覆盖：时钟等待 → 抖动记录 → 快照借用 → requestPrepare → 两路帧槽 latest → 假渲染器 → 完成回调派发给两个消费者。
    func testW1B_renderPath_zeroAllocationsInSteadyState() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
        let engine = makeEngine(renderer: renderer)
        engine.addConsumer(CountingConsumer(name: "a"))
        engine.addConsumer(CountingConsumer(name: "b"))
        let slots = [LockFreeFrameSlot(capacity: 3), LockFreeFrameSlot(capacity: 3)]
        engine.registerInput(number: 1, slot: slots[0])
        engine.registerInput(number: 2, slot: slots[1])
        let t0 = HostClock.now() + HostDuration(milliseconds: 20)
        let running = Atomic<Bool>(true)
        // 两路 60 fps 生产者，让每拍都有新帧进槽（retain / release 有，malloc 不该有）
        let inputSpec = TickClockSpec(t0: t0 - HostDuration(milliseconds: 6), frameRate: .fps60)
        let producers = try (0..<2).map { i -> NativeThread in
            let slot = slots[i]
            let t = NativeThread(config: NativeThreadConfig(name: "producer\(i)", qos: QOS_CLASS_USER_INITIATED)) {
                var k: Int64 = 0
                while running.load(ordering: .acquiring) {
                    let pts = inputSpec.time(of: Tick(k))
                    mach_wait_until((pts + HostDuration(milliseconds: 1)).ticks)
                    slot.push(TestFrames.frame(input: i + 1, sequence: UInt64(k), pts: pts, ingress: HostClock.now()))
                    k += 1
                }
            }
            try t.start()
            return t
        }
        try await engine.start(t0: t0, lastTick: Tick(299))
        // 预热 60 拍（首次路径允许惰性初始化），再盯 3 秒
        XCTAssertTrue(waitUntil(timeout: 5) { engine.counters.ticksDispatched >= 60 })
        let renderThread = renderer.renderThread.load(ordering: .relaxed)
        let completionThread = renderer.completionThread.load(ordering: .relaxed)
        XCTAssertNotEqual(renderThread, 0)
        guard AllocationProbe.start(watching: renderThread, second: completionThread) else {
            throw XCTSkip("BLOCKED-SDK：本系统没有 malloc_logger 导出符号")
        }
        let startTick = engine.counters.ticksDispatched
        // 盯到第 280 拍就停探针：线程退出时的 _pthread_tsd_cleanup 会 free 一次，那不是渲染路径
        XCTAssertTrue(waitUntil(timeout: 6) { engine.counters.ticksDispatched >= 280 })
        let endTick = engine.counters.ticksDispatched
        let probe = AllocationProbe.stop()
        engine.clock!.join()
        running.store(false, ordering: .releasing)
        producers.forEach { $0.join() }
        renderer.waitForCompletion()
        await engine.stop()
        let observedTicks = endTick - startTick
        XCTAssertGreaterThanOrEqual(observedTicks, 200)
        XCTAssertEqual(probe.allocations, 0, "渲染线程稳态 \(observedTicks) 拍内有 malloc")
        XCTAssertEqual(probe.deallocations, 0, "渲染线程稳态 \(observedTicks) 拍内有 free")
        XCTAssertEqual(probe.secondAllocations, 0, "GPU 完成线程（派发路径）稳态内有 malloc")
        XCTAssertEqual(engine.counters.missedRender, 0)
        XCTAssertEqual(engine.counters.snapshotStale, 0)
    }

    /// 动态增删输入：渲染线程读的输入表是不可变对象，换表走原子指针。
    func testW1B_engine_registerInputWhileRunning() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        let engine = makeEngine(renderer: renderer)
        try await engine.start(t0: HostClock.now() + HostDuration(milliseconds: 20), lastTick: Tick(179))
        let slot = LockFreeFrameSlot(capacity: 3)
        usleep(500_000)
        engine.registerInput(number: 1, slot: slot)
        slot.push(TestFrames.frame(sequence: 77, pts: HostClock.now()))
        usleep(500_000)
        engine.unregisterInput(number: 1)
        engine.clock!.join()
        renderer.waitForCompletion()
        await engine.stop()
        let seqs = (0..<180).map { renderer.input1Sequence[$0] }
        XCTAssertTrue(seqs.contains(77), "注册后渲染器看到了这路的帧")
        XCTAssertEqual(seqs.last, -1, "注销后表里为空")
        XCTAssertEqual(seqs.first, -1)
    }
}
