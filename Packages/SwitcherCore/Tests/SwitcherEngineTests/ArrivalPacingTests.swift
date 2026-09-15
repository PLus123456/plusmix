import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// V4 退回单 G2-w1-core-phase-crossing-dup-drop：带到达抖动的漂移输入，帧到达相位穿过拍点边界时不许出成串 dup + drop。
/// 事件驱动的确定性模拟（固定种子）：第 k 帧 pts = 输入时钟第 k 拍，到达 = pts + U[30 µs, 3 ms]；渲染线程第 n 拍在
/// t_n + U[0, 50 µs] 调 `latest(forTick: t_n)`。参考值由"当拍余量下 pts ≤ t_n − L_n 的最新帧"精确算出，逐拍比对帧号。
final class ArrivalPacingTests: XCTestCase {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// [lo, hi) 均匀分布的纳秒数。
        mutating func nanoseconds(_ lo: Int64, _ hi: Int64) -> Int64 {
            lo + Int64(next() % UInt64(hi - lo))
        }
    }

    struct Run {
        var stats: FrameSlotStats
        var pacing: PacingStats
        /// 每拍返回的帧号（-1 = nil）。
        var returned: [Int64]
        /// 每拍挑帧时用的余量（host tick）。
        var margins: [Int64]
        /// 每拍结束时的累计迟到帧数。
        var lateFrames: [UInt64]
        /// 每拍结束时余量是否已初始化（第一帧到达之前为 false）。
        var initialized: [Bool]
        /// 每拍的理想时刻。
        var tickTimes: [HostTime]
        var inputSpec: TickClockSpec
    }

    /// 跑一次模拟。arrivalNs：到达延迟的均匀区间（纳秒）；extraLatency：某些帧额外晚到的量（模拟迟到）。
    func simulate(inputPeriod: Rational, ticks: Int, seed: UInt64 = 1, arrivalNs: (Int64, Int64) = (30_000, 3_000_000),
                  extraLatency: [Int64: HostDuration] = [:], inputOffset: HostDuration = .zero,
                  configure: (PacingOptions) -> PacingOptions = { $0 }) -> Run {
        let tb = HostClock.timebase
        let t0 = HostTime(ticks: 100_000_000)
        let tickSpec = TickClockSpec(t0: t0, frameRate: .fps60)
        let inputSpec = TickClockSpec(t0: t0 + inputOffset, frameDuration: inputPeriod)
        let slot = LockFreeFrameSlot(capacity: 3)
        var options = PacingOptions()
        options.maxRaise = tickSpec.duration(ofTicks: 1)           // 引擎注册时按节目帧率填的两个值
        options.initialFloor = tickSpec.duration(ofTicks: 1) / 4
        slot.configurePacing(configure(options))
        var rng = SplitMix64(state: seed)
        // 预生成到达时刻：帧 k 的到达 = pts + U[lo, hi] (+ extra)
        var nextFrame: Int64 = 0
        var pendingArrival: (k: Int64, pts: HostTime, arrival: HostTime)? = nil
        func nextArrival() -> (k: Int64, pts: HostTime, arrival: HostTime) {
            let k = nextFrame
            nextFrame += 1
            let pts = inputSpec.time(of: Tick(k), timebase: tb)
            var arrival = pts + HostDuration(nanoseconds: rng.nanoseconds(arrivalNs.0, arrivalNs.1))
            if let extra = extraLatency[k] { arrival = arrival + extra }
            return (k, pts, arrival)
        }
        pendingArrival = nextArrival()
        var returned: [Int64] = []
        var margins: [Int64] = []
        var lateFrames: [UInt64] = []
        var initialized: [Bool] = []
        var tickTimes: [HostTime] = []
        returned.reserveCapacity(ticks); margins.reserveCapacity(ticks); tickTimes.reserveCapacity(ticks); lateFrames.reserveCapacity(ticks)
        for n in 0..<ticks {
            let ideal = tickSpec.time(of: Tick(Int64(n)), timebase: tb)
            let callTime = ideal + HostDuration(nanoseconds: rng.nanoseconds(0, 50_000))
            // 到达时刻 ≤ 调用时刻的帧全部 push（按到达顺序）
            while let p = pendingArrival, p.arrival <= callTime {
                slot.push(TestFrames.frame(sequence: UInt64(p.k), pts: p.pts, ingress: p.arrival))
                pendingArrival = nextArrival()
            }
            let f = slot.latest(forTick: ideal)
            returned.append(f.map { Int64($0.sequence) } ?? -1)
            let ps = slot.pacingStats
            margins.append(ps.margin.ticks)
            lateFrames.append(ps.lateFrames)
            initialized.append(ps.initialized)
            tickTimes.append(ideal)
        }
        return Run(stats: slot.stats, pacing: slot.pacingStats, returned: returned, margins: margins, lateFrames: lateFrames,
                   initialized: initialized, tickTimes: tickTimes, inputSpec: inputSpec)
    }

    /// 参考模型：第 n 拍在余量 L_n 下合格的最新帧号（pts ≤ t_n − L_n），没有为 -1。
    func referenceEligible(_ run: Run) -> [Int64] {
        let tb = HostClock.timebase
        return (0..<run.returned.count).map { n in
            guard run.initialized[n] else { return -1 }   // 第一帧还没到，余量未定
            let limit = run.tickTimes[n] - HostDuration(ticks: run.margins[n])
            guard limit >= run.inputSpec.t0 else { return -1 }
            return run.inputSpec.tick(at: limit, timebase: tb).rawValue
        }
    }

    /// 由参考帧号序列得出设计内的 reuse / drop 数。
    func designIn(_ eligible: [Int64]) -> (reused: Int, dropped: Int) {
        var reused = 0, dropped = 0
        var last: Int64 = -1
        for e in eligible {
            guard e >= 0 else { continue }
            if last >= 0 {
                if e == last { reused += 1 } else if e > last + 1 { dropped += Int(e - last - 1) }
            }
            last = e
        }
        return (reused, dropped)
    }

    func assertMatchesReference(_ run: Run, label: String = #function, file: StaticString = #filePath, line: UInt = #line) {
        let eligible = referenceEligible(run)
        print("V4 \(label): ticks \(run.returned.count) reused \(run.stats.reused) dropped \(run.stats.dropped) late \(run.pacing.lateFrames) "
              + "margin \(String(format: "%.2f", run.pacing.margin.milliseconds)) ms raises \(run.pacing.raises) decreases \(run.pacing.decreases)")
        XCTAssertEqual(run.returned, eligible, "逐拍返回的帧必须恰好是当拍余量下合格的最新帧", file: file, line: line)
        let d = designIn(eligible)
        XCTAssertEqual(Int(run.stats.reused), d.reused, "reused 与参考模型", file: file, line: line)
        XCTAssertEqual(Int(run.stats.dropped), d.dropped, "dropped 与参考模型", file: file, line: line)
        XCTAssertEqual(run.pacing.lateFrames, 0, "余量足够时不该有迟到帧", file: file, line: line)
    }

    // MARK: 漂移 + 到达抖动：设计内值精确

    /// 59.94 进 60，12000 拍 = 12 次相位穿越：每 1000 拍 1 次 reuse，drop 恰好 0。
    func testV4_5994Into60_withArrivalJitter_reusePer1000_dropZero() {
        let run = simulate(inputPeriod: Rational(1001, 60_000), ticks: 12_000)
        assertMatchesReference(run)
        XCTAssertEqual(run.stats.dropped, 0, "输入慢于节目：任何 drop 都是设计外")
        XCTAssertEqual(Int(run.stats.reused), 12, accuracy: 1, "每 1000 拍重复 1 次（边界 ± 1）")
        XCTAssertGreaterThanOrEqual(run.pacing.decreases, 1, "初始余量应已经收敛下来")
        XCTAssertLessThan(run.pacing.margin.milliseconds, 8, "稳态余量 ≈ 最大到达延迟 3 ms + 保护带")
    }

    /// 60 +100 ppm 进 60，60000 拍 = 6 次穿越：每 10000 拍 1 次 drop，reuse 恰好 0。
    func testV4_60fpsPlus100ppmInto60_withArrivalJitter_dropPer10000_reuseZero() {
        let run = simulate(inputPeriod: Rational(1000, 60_006), ticks: 60_000)
        assertMatchesReference(run)
        XCTAssertEqual(run.stats.reused, 0, "输入快于节目：任何 reuse 都是设计外")
        XCTAssertEqual(Int(run.stats.dropped), 6, accuracy: 1)
    }

    /// 60 −100 ppm 进 60（G2 场景的 6 号输入）：每 10000 拍 1 次 reuse，drop 0。
    func testV4_60fpsMinus100ppmInto60_withArrivalJitter_reusePer10000_dropZero() {
        let run = simulate(inputPeriod: Rational(1000, 59_994), ticks: 60_000, seed: 7)
        assertMatchesReference(run)
        XCTAssertEqual(run.stats.dropped, 0)
        XCTAssertEqual(Int(run.stats.reused), 6, accuracy: 1)
    }

    /// 更大的漂移缩短穿越周期：+1000 ppm 每 1000 拍穿越一次，12000 拍 12 次；三个种子。
    func testV4_plus1000ppm_withArrivalJitter_manyCrossings() {
        for seed: UInt64 in [3, 11, 19] {
            let run = simulate(inputPeriod: Rational(1000, 60_060), ticks: 12_000, seed: seed)
            assertMatchesReference(run)
            XCTAssertEqual(run.stats.reused, 0, "种子 \(seed)")
            XCTAssertEqual(Int(run.stats.dropped), 12, accuracy: 1, "种子 \(seed)")
        }
    }

    /// 相位锁定的 60 fps（提前 8.33 ms，G2 的默认）加 ±3 ms 到达抖动：0 reuse 0 drop。
    func testV4_phaseLocked60_withLeadAndJitter_noEvents() {
        let run = simulate(inputPeriod: Rational(1, 60), ticks: 6_000, seed: 5, arrivalNs: (-3_000_000, 3_000_000),
                           inputOffset: -HostDuration(milliseconds: 1000.0 / 60 / 2))
        assertMatchesReference(run)
        XCTAssertEqual(run.stats.reused, 0)
        XCTAssertEqual(run.stats.dropped, 0)
    }

    /// 30 fps 进 60 带抖动：仍是精确 50%。
    func testV4_30fpsInto60_withArrivalJitter_stillExactly50Percent() {
        let run = simulate(inputPeriod: Rational(1, 30), ticks: 6_000, seed: 9)
        assertMatchesReference(run)
        XCTAssertEqual(run.stats.dropped, 0)
        XCTAssertEqual(run.stats.reused * 2, run.stats.consumed, accuracy: 2)
    }

    // MARK: 余量的变化不许制造事件

    /// 余量收敛过程（初始值 → 稳态）只在"带内无候选帧"的拍改：把初始余量下限抬到 20 ms（超过一个输入帧），
    /// 逼它分多次减到 ~4.5 ms，慢输入全程 drop 仍为 0、快输入全程 reuse 仍为 0。
    func testV4_marginDecreaseNeverCausesDrop() {
        let slow = simulate(inputPeriod: Rational(1001, 60_000), ticks: 12_000, seed: 21) { o in
            var o = o
            o.initialFloor = HostDuration(milliseconds: 20)
            return o
        }
        assertMatchesReference(slow)
        XCTAssertEqual(slow.stats.dropped, 0)
        XCTAssertGreaterThanOrEqual(slow.pacing.decreases, 2, "20 ms → ~4.5 ms 至少分两步（每步不能把候选帧带进合格区）")
        XCTAssertLessThan(slow.pacing.margin.milliseconds, 8)
        XCTAssertGreaterThan(slow.margins[10], slow.margins[11_999], "初始 20 ms，末尾已收敛")
        let fast = simulate(inputPeriod: Rational(1000, 60_060), ticks: 12_000, seed: 22) { o in
            var o = o
            o.initialFloor = HostDuration(milliseconds: 20)
            return o
        }
        assertMatchesReference(fast)
        XCTAssertEqual(fast.stats.reused, 0)
        XCTAssertGreaterThanOrEqual(fast.pacing.decreases, 2)
    }

    /// 到达延迟中途变大（0.03–3 ms → 3–6 ms）：余量在带空的拍主动抬高，快输入全程 reuse 仍为 0、无迟到。
    func testV4_marginIncreaseOnGrowingLatency_noReuseOnFastInput() {
        // 用 extraLatency 给第 4000 帧之后每帧加 3 ms
        var extra: [Int64: HostDuration] = [:]
        for k in 4000..<12_500 { extra[Int64(k)] = HostDuration(milliseconds: 3) }
        let run = simulate(inputPeriod: Rational(1000, 60_060), ticks: 12_000, seed: 33, extraLatency: extra)
        XCTAssertEqual(run.stats.reused, 0, "抬高余量只在带空时做，不制造 reuse")
        XCTAssertLessThanOrEqual(run.pacing.lateFrames, 1, "延迟突变最多迟到 1 帧")
        XCTAssertGreaterThan(run.pacing.margin.milliseconds, 6)
    }

    // MARK: 迟到帧：只花一次躲不掉的 reuse，不丢帧

    /// 到达延迟恒定 30 µs（余量收敛到 ~1 ms），第 3500 帧晚到 20 ms（超过它的合格拍）：那一拍重复上一帧，
    /// 下一拍把它返回（不跳过），余量抬高（封顶一个节目帧）；离群点滑出窗口后余量收回。
    func testV4_lateFrame_costsExactlyOneReuse_noDrop_thenMarginCovers() {
        let late: [Int64: HostDuration] = [3500: HostDuration(milliseconds: 20)]
        let run = simulate(inputPeriod: Rational(1001, 60_000), ticks: 6_000, seed: 2, arrivalNs: (30_000, 30_001), extraLatency: late)
        let baseline = simulate(inputPeriod: Rational(1001, 60_000), ticks: 6_000, seed: 2, arrivalNs: (30_000, 30_001))
        XCTAssertEqual(run.stats.dropped, 0, "迟到帧不能被跳过")
        XCTAssertEqual(run.pacing.lateFrames, 1)
        XCTAssertEqual(baseline.pacing.lateFrames, 0)
        // 第 3500 帧的合格拍在 3503–3506 附近：这个窗口里 run 恰好多一次 reuse（baseline 的设计内 reuse 在 ~3003、~4004）
        func reuses(_ r: Run, _ range: ClosedRange<Int>) -> Int {
            range.reduce(0) { $0 + (r.returned[$1] >= 0 && r.returned[$1] == r.returned[$1 - 1] ? 1 : 0) }
        }
        XCTAssertEqual(reuses(baseline, 3495...3515), 0)
        XCTAssertEqual(reuses(run, 3495...3515), 1, "只多一次躲不掉的 reuse")
        // 帧号序列：只能重复或 +1（没有跳过）
        var last: Int64 = -1
        for s in run.returned where s >= 0 {
            XCTAssertTrue(s == last || s == last + 1, "帧号只能重复或 +1，实际 \(last) → \(s)")
            last = s
        }
        // 检测到迟到的那一拍：余量抬高，且单次 ≤ 一个节目帧（封顶）
        let detect = run.lateFrames.firstIndex { $0 == 1 }!
        XCTAssertTrue((3500...3510).contains(detect), "迟到在第 3500 帧的合格拍之后一拍被检测到，实际 \(detect)")
        let cap = HostDuration(milliseconds: 1000.0 / 60).ticks
        XCTAssertGreaterThan(run.margins[detect], run.margins[detect - 1], "迟到后余量抬高")
        XCTAssertLessThanOrEqual(run.margins[detect] - run.margins[detect - 1], cap, "单次抬高 ≤ 一个节目帧")
        XCTAssertEqual(run.returned[detect], 3500, "检测那一拍返回迟到的帧本身，不跳过")
        XCTAssertLessThan(run.pacing.margin.milliseconds, 3, "离群点滑出 8 块窗口后余量收回（3500 帧 + 480 帧 < 6000 拍）")
        XCTAssertEqual(run.stats.dropped, 0)
    }

    /// 迟到超过两拍（坏时间戳 / 卡顿 40 ms）：抬高封顶一个节目帧，这帧被跳过，最多 1 drop；余量不被顶飞、之后收回。
    func testV4_veryLateFrame_raiseIsCapped_atMostOneDrop() {
        let late: [Int64: HostDuration] = [3500: HostDuration(milliseconds: 40)]
        let run = simulate(inputPeriod: Rational(1001, 60_000), ticks: 6_000, seed: 2, arrivalNs: (30_000, 30_001), extraLatency: late)
        XCTAssertEqual(run.pacing.lateFrames, 1)
        XCTAssertLessThanOrEqual(run.stats.dropped, 1)
        let detect = run.lateFrames.firstIndex { $0 == 1 }!
        let cap = HostDuration(milliseconds: 1000.0 / 60).ticks
        XCTAssertEqual(run.margins[detect] - run.margins[detect - 1], cap, "晚到 40 ms：抬高被封顶在一个节目帧")
        XCTAssertLessThan(run.pacing.margin.milliseconds, 3, "之后收回")
    }

    // MARK: 契约入口不变

    func testV4_contractLatest_isUnpaced_andBothEntriesShareState() {
        let slot = LockFreeFrameSlot(capacity: 3)
        slot.push(TestFrames.frame(sequence: 1, pts: HostTime(ticks: 1000), ingress: HostTime(ticks: 1100)))
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(ticks: 1000))?.sequence, 1, "契约入口：pts ≤ time 即返回，不带余量")
        XCTAssertFalse(slot.pacingStats.initialized, "契约入口不参与余量估计")
        slot.push(TestFrames.frame(sequence: 2, pts: HostTime(ticks: 2000), ingress: HostTime(ticks: 2100)))
        XCTAssertEqual(slot.latest(forTick: HostTime(ticks: 2000))?.sequence, 1, "引擎入口：2000 − 余量 < 2000，帧 2 还不合格，重复帧 1")
        XCTAssertTrue(slot.pacingStats.initialized)
        XCTAssertEqual(slot.latest(forTick: HostTime(ticks: 2000) + slot.pacingStats.margin)?.sequence, 2)
    }
}
