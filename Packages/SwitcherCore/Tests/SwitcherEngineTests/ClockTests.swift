import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 节目时钟：拍点数学（V5 的前提）、唤醒抖动（V3）、跳拍计数（V2）。
/// V3 / V2 两条是实跑（30 s + 10 s），阈值是这台机器上的目标档（p99 ≤ 1 ms）；"必须"档 4 ms 也一并断言。
final class ClockTests: XCTestCase {
    /// 59.94 fps 一小时（216000 拍）拍点数学无漂：时钟用的 deadline 恒等于独立算的 ⌊n·1001/60000 s⌋，
    /// 相邻间隔只取 ⌊T⌋ / ⌈T⌉ 两种，不做浮点累加。
    func testV5_tickMath_5994_oneHourNoDrift() {
        let tb = MachTimebase(numer: 125, denom: 3) // Apple Silicon 24 MHz
        let t0 = HostTime(ticks: 1_000_000_000)
        let spec = TickClockSpec(t0: t0, frameRate: .fps5994)
        let clock = ProgramClock(spec: spec)
        var previous = t0
        var intervals = Set<Int64>()
        for n in 0...216_000 {
            let tick = Tick(Int64(n))
            // 独立参考：n × 1001 × 1e9 × denom / (60000 × numer)，128 位一次乘除
            let reference = Int128(t0.ticks) + Int128(n) * 1001 * 1_000_000_000 * Int128(tb.denom) / (60_000 * Int128(tb.numer))
            let deadline = clock.deadline(for: tick, timebase: tb)
            XCTAssertEqual(Int128(deadline.ticks), reference, "第 \(n) 拍")
            if n > 0 { intervals.insert((deadline - previous).ticks) }
            previous = deadline
        }
        // 1001/60000 s = 400400 host tick 整
        XCTAssertEqual(intervals, [400_400])
        XCTAssertEqual((clock.deadline(for: Tick(216_000), timebase: tb) - t0).ticks, 86_486_400_000, "一小时 = 3603.6 s 整")
        // 逆运算严格互逆
        for n in stride(from: 0, through: 216_000, by: 977) {
            let t = clock.deadline(for: Tick(Int64(n)), timebase: tb)
            XCTAssertEqual(spec.tick(at: t, timebase: tb), Tick(Int64(n)))
            XCTAssertEqual(spec.tick(at: t - HostDuration(ticks: 1), timebase: tb), Tick(Int64(n - 1)))
        }
    }

    /// 实跑 30 秒（1800 拍 @ 60），每拍唤醒时刻 − 理想拍点：p99 ≤ 1 ms（本机目标），max 也打印进报告。
    func testV3_wakeJitter_30s_p99Under1ms() throws {
        final class NoopHandler: ProgramClockHandler {
            let wakes = Atomic<UInt64>(0)
            let earlyWakes = Atomic<UInt64>(0)
            func programClock(_ clock: ProgramClock, tick: Tick, ideal: HostTime, wake: HostTime) {
                wakes.add(1, ordering: .relaxed)
                if wake < ideal { earlyWakes.add(1, ordering: .relaxed) }
            }
            func programClock(_ clock: ProgramClock, didSkipTicks count: Int, upTo tick: Tick) {}
        }
        let spec = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 20), frameRate: .fps60)
        let clock = ProgramClock(spec: spec)
        let handler = NoopHandler()
        try clock.start(handler: handler, firstTick: .zero, lastTick: Tick(1799))
        clock.join()
        XCTAssertTrue(clock.isRealtime, "本机 macOS 26 上非实时线程的 mach_wait_until 会被定时器合并（探针：p99 3.7–7.2 ms），必须挂实时策略")
        XCTAssertEqual(handler.wakes.load(ordering: .acquiring), 1800)
        XCTAssertEqual(handler.earlyWakes.load(ordering: .acquiring), 0, "mach_wait_until 不会提前醒")
        XCTAssertEqual(clock.ticksSkipped, 0)
        let samples = clock.jitter.samples()
        XCTAssertEqual(samples.count, 1800)
        let p50 = clock.jitter.percentile(0.5)!.milliseconds
        let p99 = clock.jitter.percentile(0.99)!.milliseconds
        let max = samples.map(\.milliseconds).max()!
        print("V3 wake jitter over 30 s: p50 \(String(format: "%.3f", p50)) ms, p99 \(String(format: "%.3f", p99)) ms, max \(String(format: "%.3f", max)) ms")
        XCTAssertLessThanOrEqual(p99, 1.0, "本机目标档：p99 ≤ 1 ms")
        XCTAssertLessThanOrEqual(p99, 4.0, "必须档：p99 ≤ 4 ms")
    }

    /// W1-B3 交付 2：渲染线程（= 时钟线程）的调度策略从内核读回来是 time-constraint 实时（get_default = 0、period = 拍长、
    /// computation / constraint 按选项比例），不只是 thread_policy_set 返回成功。线程在跑的时候读（有界运行的最后一拍之前）。
    func testW1B3_clockThread_timeConstraintPolicyReadsBackRealtime() throws {
        final class HoldHandler: ProgramClockHandler {
            let ticks = Atomic<UInt64>(0)
            func programClock(_ clock: ProgramClock, tick: Tick, ideal: HostTime, wake: HostTime) { ticks.add(1, ordering: .relaxed) }
            func programClock(_ clock: ProgramClock, didSkipTicks count: Int, upTo tick: Tick) {}
        }
        let spec = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 20), frameRate: .fps60)
        let clock = ProgramClock(spec: spec)
        let handler = HoldHandler()
        try clock.start(handler: handler, firstTick: .zero, lastTick: Tick(119))   // 2 s
        XCTAssertTrue(waitUntil(timeout: 2) { handler.ticks.load(ordering: .acquiring) >= 10 })
        XCTAssertTrue(clock.isRealtime)
        let readback = try XCTUnwrap(clock.readBackTimeConstraint())
        let expected = clock.timeConstraint
        print("W1B3 时钟线程策略读回：default \(readback.isDefault) period \(readback.period) computation \(readback.computation) constraint \(readback.constraint)（申报 \(expected.period) / \(expected.computation) / \(expected.constraint)）")
        XCTAssertFalse(readback.isDefault, "渲染线程应是 time-constraint 实时线程")
        XCTAssertEqual(readback.period, expected.period)
        XCTAssertEqual(readback.computation, expected.computation)
        XCTAssertEqual(readback.constraint, expected.constraint)
        // 对照：普通线程读回来是默认策略
        let plain = NativeThread(config: NativeThreadConfig(name: "plain", qos: QOS_CLASS_USER_INTERACTIVE)) { Thread.sleep(forTimeInterval: 0.3) }
        try plain.start()
        let plainReadback = try XCTUnwrap(plain.readBackTimeConstraint())
        XCTAssertTrue(plainReadback.isDefault)
        plain.join()
        clock.join()
    }

    /// 假渲染耗时 30 ms（忙到 tickTime + 30 ms）：每个渲染的拍之后恰好跳过 ⌈30 / 16.67⌉ − 1 = 1 拍，
    /// 600 拍里渲染 300、跳过 300，missed_render 精确等于理论值；被渲染的拍恰好是偶数拍。
    func testV2_missedRender_30msRenderer_exactSkipCount() throws {
        final class BusyHandler: ProgramClockHandler, @unchecked Sendable {
            let busy = HostDuration(milliseconds: 30)
            var dispatched: [Int64] = []
            var skipped: [(Int, Int64)] = []
            func programClock(_ clock: ProgramClock, tick: Tick, ideal: HostTime, wake: HostTime) {
                dispatched.append(tick.rawValue)
                let until = ideal + busy
                while HostClock.now() < until {}
            }
            func programClock(_ clock: ProgramClock, didSkipTicks count: Int, upTo tick: Tick) {
                skipped.append((count, tick.rawValue))
            }
        }
        let spec = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 20), frameRate: .fps60)
        let clock = ProgramClock(spec: spec)
        let handler = BusyHandler()
        let totalTicks = 600
        try clock.start(handler: handler, firstTick: .zero, lastTick: Tick(Int64(totalTicks - 1)))
        clock.join()
        // 理论：渲染时长 R = 30 ms，拍长 P = 1000/60 ms；每个渲染拍后跳 ⌈R/P⌉ − 1 拍
        let skipPerRender = Int((30.0 / (1000.0 / 60.0)).rounded(.up)) - 1
        XCTAssertEqual(skipPerRender, 1)
        let expectedDispatched = (totalTicks + skipPerRender) / (skipPerRender + 1)
        let expectedSkipped = totalTicks - expectedDispatched
        XCTAssertEqual(handler.dispatched.count, expectedDispatched)
        XCTAssertEqual(clock.ticksDispatched, UInt64(expectedDispatched))
        XCTAssertEqual(clock.ticksSkipped, UInt64(expectedSkipped), "missed_render 必须精确等于理论跳拍数")
        XCTAssertEqual(handler.skipped.map(\.0).reduce(0, +), expectedSkipped)
        XCTAssertEqual(handler.dispatched, Array(stride(from: Int64(0), to: Int64(totalTicks), by: skipPerRender + 1)))
        XCTAssertEqual(clock.ticksDispatched + clock.ticksSkipped, UInt64(totalTicks), "每一拍要么渲染要么计入跳拍")
    }

    /// 每拍对照理想拍点，不累积误差：唤醒时刻永远 ≥ 该拍的理想时刻，且理想时刻由 spec 一次乘除得出。
    func testV3_clockDeadlinesComeFromSpecNotAccumulation() throws {
        final class Recorder: ProgramClockHandler, @unchecked Sendable {
            var ideals: [HostTime] = []
            var wakes: [HostTime] = []
            func programClock(_ clock: ProgramClock, tick: Tick, ideal: HostTime, wake: HostTime) {
                ideals.append(ideal); wakes.append(wake)
            }
            func programClock(_ clock: ProgramClock, didSkipTicks count: Int, upTo tick: Tick) {}
        }
        let spec = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 10), frameRate: .fps5994)
        let clock = ProgramClock(spec: spec)
        let rec = Recorder()
        try clock.start(handler: rec, firstTick: Tick(5), lastTick: Tick(124))
        clock.join()
        XCTAssertEqual(rec.ideals.count, 120)
        for (i, ideal) in rec.ideals.enumerated() {
            XCTAssertEqual(ideal, spec.time(of: Tick(Int64(5 + i))))
            XCTAssertGreaterThanOrEqual(rec.wakes[i], ideal)
        }
        XCTAssertEqual(clock.lastDispatchedTick, Tick(124))
    }
}
