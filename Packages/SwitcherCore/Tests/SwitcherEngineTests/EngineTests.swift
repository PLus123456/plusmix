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

    /// V4 退回单：引擎走带到达余量的挑帧。真线程生产者 60 fps +1%（每 100 拍穿越一次相位边界）、到达 = pts + U[0.03, 3] ms，
    /// 600 拍：快输入 reuse 恰好 0，drop = 设计内（帧数 − 拍数），无迟到帧。
    func testV4_engine_driftingInputWithArrivalJitter_designInOnly() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        let engine = makeEngine(renderer: renderer)
        let slot = LockFreeFrameSlot(capacity: 3)
        engine.registerInput(number: 1, slot: slot)
        let t0 = HostClock.now() + HostDuration(milliseconds: 50)
        let inputSpec = TickClockSpec(t0: t0 - HostDuration(milliseconds: 5), frameDuration: Rational(1000, 60_600))
        let running = Atomic<Bool>(true)
        let period = UInt32(clamping: inputSpec.duration(ofTicks: 1).ticks)
        let config = NativeThreadConfig(name: "producer-drift", qos: QOS_CLASS_USER_INTERACTIVE,
                                        timeConstraint: .init(period: period, computation: period / 10, constraint: period / 2))
        let lastPushed = Atomic<Int64>(-1)
        let producer = NativeThread(config: config) {
            var k: Int64 = 0
            var rng: UInt64 = 0x1234_5678
            while running.load(ordering: .acquiring) {
                let pts = inputSpec.time(of: Tick(k))
                rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                let delay = HostDuration(nanoseconds: 30_000 + Int64(rng % 2_970_000))
                mach_wait_until((pts + delay).ticks)
                slot.push(TestFrames.frame(sequence: UInt64(k), pts: pts, ingress: HostClock.now()))
                lastPushed.store(k, ordering: .releasing)
                k += 1
            }
        }
        try producer.start()
        try await engine.start(t0: t0, lastTick: Tick(599))
        engine.clock!.join()
        running.store(false, ordering: .releasing)
        producer.join()
        renderer.waitForCompletion()
        await engine.stop()
        let st = slot.stats
        let pacing = engine.pacingStats(forInput: 1)!
        XCTAssertTrue(pacing.initialized)
        XCTAssertEqual(pacing.lateFrames, 0, "余量盖住 3 ms 抖动，没有迟到帧")
        XCTAssertEqual(st.reused, 0, "快输入：任何 reuse 都是设计外")
        // 设计内 drop = 最后一拍合格的帧数 − 返回过帧的拍数
        let lastTick = engine.clock!.spec.time(of: Tick(599))
        let eligibleFrames = inputSpec.tick(at: lastTick - pacing.margin).rawValue + 1
        XCTAssertEqual(Int64(st.dropped), eligibleFrames - Int64(st.consumed), "drop 恰好等于设计内值")
        XCTAssertEqual(Int(st.dropped), 6, accuracy: 1, "+1% 每 100 拍丢 1 帧")
        XCTAssertLessThan(pacing.margin.milliseconds, 8)
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

    // MARK: L1 统计（提案 005 引擎侧）

    /// 生产者开关（Atomic 不可拷贝，装进类里给闭包捕获）。
    final class RunFlag: @unchecked Sendable {
        let value = Atomic<Bool>(true)
        func stop() { value.store(false, ordering: .releasing) }
    }

    /// 起一个真线程生产者：帧 k 的 pts = 输入时钟第 k 拍，pts + delay 到达，ingress = HostClock.now()。
    func startProducer(slot: any FrameSlot & Sendable, input: Int, spec: TickClockSpec, delay: HostDuration, running: RunFlag) throws -> NativeThread {
        let period = UInt32(clamping: spec.duration(ofTicks: 1).ticks)
        let config = NativeThreadConfig(name: "producer-l1-\(input)", qos: QOS_CLASS_USER_INTERACTIVE,
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

    /// 提案 005：per_input[n].latency_ms / latency_max_ms 由引擎算（GPU 完成回调取 now，减该拍所用新帧的 ingressTime）。
    /// 与 W2-A 的参考实现（ReferenceLatencySlot + ReferenceLatencyConsumer，同一运行内、同一批帧）比：平均差 ≤ 0.2 ms；
    /// 30 进 60 只算新帧（样本数 ≈ 帧数，不是拍数）；引擎起来（t0）之前进槽的帧不算。
    func testL1_stats_perInputLatency_matchesW2AReference_within0_2ms() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 2))
        let engine = makeEngine(renderer: renderer)
        let t0 = HostClock.now() + HostDuration(milliseconds: 50)
        let tickSpec = TickClockSpec(t0: t0, frameRate: .fps60)
        // 输入 1：30 fps，d ≈ 1 ms；输入 2：60 fps，d ≈ 3 ms（两路都相位提前 8 ms）
        let slot1 = ReferenceLatencySlot(inner: LockFreeFrameSlot(capacity: 3), spec: tickSpec)
        let slot2 = ReferenceLatencySlot(inner: LockFreeFrameSlot(capacity: 3), spec: tickSpec)
        engine.registerInput(number: 1, slot: slot1)
        engine.registerInput(number: 2, slot: slot2)
        let reference = ReferenceLatencyConsumer(slots: [(1, slot1), (2, slot2)], t0: t0)
        engine.addConsumer(reference)                       // 第一个消费者：consume 入口 = 编码器入口
        engine.addConsumer(CountingConsumer(name: "b"))
        let running = RunFlag()
        let p1 = try startProducer(slot: slot1, input: 1, spec: TickClockSpec(t0: t0 - HostDuration(milliseconds: 8), frameRate: .fps30),
                                   delay: HostDuration(milliseconds: 1), running: running)
        let p2 = try startProducer(slot: slot2, input: 2, spec: TickClockSpec(t0: t0 - HostDuration(milliseconds: 8), frameRate: .fps60),
                                   delay: HostDuration(milliseconds: 3), running: running)
        try await engine.start(t0: t0, lastTick: Tick(599))
        engine.clock!.join()
        running.stop()
        p1.join(); p2.join()
        renderer.waitForCompletion()
        let stats = engine.makeStats()                      // 第一行：窗口 = 自启动以来
        await engine.stop()
        for number in [1, 2] {
            let ref = reference.stats(forInput: number)!
            let mine = stats.perInput[number]!
            print("L1 输入 \(number)：引擎 avg \(String(format: "%.3f", mine.latencyMs)) / max \(String(format: "%.3f", mine.latencyMaxMs)) ms；参考 avg \(String(format: "%.3f", ref.meanMs)) / max \(String(format: "%.3f", ref.maxMs)) ms，样本 \(ref.samples)，重复拍 \(ref.reusedTicks)")
            XCTAssertGreaterThan(ref.samples, 200, "输入 \(number)")
            XCTAssertEqual(mine.latencyMs, ref.meanMs, accuracy: 0.2, "输入 \(number)：窗口平均与 W2-A 参考实现差 ≤ 0.2 ms")
            XCTAssertEqual(mine.latencyMaxMs, ref.maxMs, accuracy: 1.0, "输入 \(number)：最大值同一批样本（参考的 now 晚几微秒，允许 1 ms）")
            XCTAssertGreaterThan(mine.latencyMs, 2, "输入 \(number)：≥ 假 GPU 2 ms")
            XCTAssertLessThan(mine.latencyMs, 30, "输入 \(number)")
        }
        // 30 进 60：只算新帧 → 样本 ≈ 300（不是 600），重复拍 ≈ 300
        let r1 = reference.stats(forInput: 1)!
        XCTAssertEqual(r1.samples, 300, accuracy: 3)
        XCTAssertEqual(r1.reusedTicks, 300, accuracy: 3)
        XCTAssertEqual(reference.stats(forInput: 2)!.samples, 600, accuracy: 3)
        XCTAssertEqual(engine.counters.slowConsumeCalls, 0)
    }

    /// 窗口语义：每行只算上一行以来的样本；没有样本的窗口 latency_ms / latency_max_ms = 0；最大值读后清零。
    func testL1_stats_windowResetsPerRow_zeroWhenNoSamples() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        let engine = makeEngine(renderer: renderer)
        let slot = LockFreeFrameSlot(capacity: 3)
        engine.registerInput(number: 3, slot: slot)
        let t0 = HostClock.now() + HostDuration(milliseconds: 50)
        let running = RunFlag()
        let producer = try startProducer(slot: slot, input: 3, spec: TickClockSpec(t0: t0 - HostDuration(milliseconds: 8), frameRate: .fps30),
                                         delay: HostDuration(milliseconds: 1), running: running)
        try await engine.start(t0: t0, lastTick: Tick(239))
        engine.clock!.join()
        running.stop()
        producer.join()
        renderer.waitForCompletion()
        let row1 = engine.makeStats()
        XCTAssertGreaterThan(row1.perInput[3]!.latencyMs, 0)
        XCTAssertGreaterThanOrEqual(row1.perInput[3]!.latencyMaxMs, row1.perInput[3]!.latencyMs)
        let row2 = engine.makeStats()                        // 第二行：没有新完成的帧
        XCTAssertEqual(row2.perInput[3]!.latencyMs, 0, "窗口内没有样本写 0")
        XCTAssertEqual(row2.perInput[3]!.latencyMaxMs, 0)
        await engine.stop()
        let line = try row1.jsonLine()
        XCTAssertTrue(line.contains("\"latency_ms\""), "字段进 stats.jsonl")
        XCTAssertEqual(try Stats.parse(line: line), row1)
    }

    /// 可选第 6 条：组装方可按输入给 PacingOptions（例如自由跑的源把余量关掉）；不给的仍用引擎默认。
    func testW1B_engine_registerInput_perInputPacingOptions() async throws {
        let renderer = FakeRenderer(gpuDelay: HostDuration(milliseconds: 1))
        var options = EngineOptions()
        options.pacing.initialFloor = HostDuration(milliseconds: 6)
        let engine = Engine(stateMachine: StateMachine(initialState: ReducerTests.baseState()), renderer: renderer, maxInputs: 8, options: options)
        let a = LockFreeFrameSlot(capacity: 3), b = LockFreeFrameSlot(capacity: 3), c = LockFreeFrameSlot(capacity: 3)
        var custom = PacingOptions()
        custom.initialFloor = HostDuration(milliseconds: 12)
        var off = PacingOptions()
        off.enabled = false
        engine.registerInput(number: 1, slot: a)                       // 引擎默认：下限 6 ms
        engine.registerInput(number: 2, slot: b, pacing: custom)       // 这一路：下限 12 ms（maxRaise / programFrame 仍由引擎按节目帧率填）
        engine.registerInput(number: 3, slot: c, pacing: off)          // 这一路：关掉
        let t0 = HostClock.now() + HostDuration(milliseconds: 30)
        // 相位提前 20 ms（> 12 ms 的下限）：第 0 拍上第一帧已合格，不触发"起流出画"的降余量
        let spec = TickClockSpec(t0: t0 - HostDuration(milliseconds: 20), frameRate: .fps60)
        let running = RunFlag()
        let producers = try [(a, 1), (b, 2), (c, 3)].map { try startProducer(slot: $0.0, input: $0.1, spec: spec, delay: HostDuration(milliseconds: 1), running: running) }
        try await engine.start(t0: t0, lastTick: Tick(29))          // 0.5 s：热身（1 块 = 1 s）未结束，初值还在
        engine.clock!.join()
        running.stop()
        producers.forEach { $0.join() }
        renderer.waitForCompletion()
        await engine.stop()
        // 三路 d ≈ 1 ms（> 0）：初值 = max(下限, d₀ + 1 ms) = 下限；上限 ≈ 1 + 16.7 + 1 ms 不压它
        XCTAssertEqual(engine.pacingStats(forInput: 1)!.margin.milliseconds, 6, accuracy: 0.5)
        XCTAssertEqual(engine.pacingStats(forInput: 2)!.margin.milliseconds, 12, accuracy: 0.5)
        XCTAssertFalse(engine.pacingStats(forInput: 3)!.enabled)
        XCTAssertEqual(c.stats.reused, 0)
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
