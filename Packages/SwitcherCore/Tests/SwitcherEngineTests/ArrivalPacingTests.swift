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
        /// 每拍的余量上限 / 窗口最小到达延迟（host tick）。
        var caps: [Int64]
        var windowMins: [Int64]
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
        options.maxRaise = tickSpec.duration(ofTicks: 1)           // 引擎注册时按节目帧率填的三个值
        options.initialFloor = tickSpec.duration(ofTicks: 1) / 4
        options.programFrame = tickSpec.duration(ofTicks: 1)
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
        var caps: [Int64] = []
        var windowMins: [Int64] = []
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
            caps.append(ps.marginCap.ticks)
            windowMins.append(ps.windowMinLatency.ticks)
            lateFrames.append(ps.lateFrames)
            initialized.append(ps.initialized)
            tickTimes.append(ideal)
        }
        return Run(stats: slot.stats, pacing: slot.pacingStats, returned: returned, margins: margins, caps: caps, windowMins: windowMins,
                   lateFrames: lateFrames, initialized: initialized, tickTimes: tickTimes, inputSpec: inputSpec)
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
        // W1-B2 起初值 = max(下限, d₀ + 1 ms)，d ≤ 3 ms 的源初值就是下限 4.17 ms，稳态目标 3 + 1 + 0.15 × 3 ≈ 4.45 在滞回内，不需要收敛
        XCTAssertEqual(run.pacing.margin.milliseconds, 1000.0 / 60 / 4, accuracy: 0.01, "初值 = 节目 1/4 帧下限，稳态目标在滞回内")
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

    // MARK: L1：高延迟源（摄像头：d ≈ 55 ms 固定管线延迟 + 几 ms 抖动；问题单 W2A-w1-core-arrival-pacing-vs-camera-latency）

    /// 模拟摄像头：d = U[52, 58] ms，第一帧最慢（d₀ = 75 ms，相机管线的起流特征）。可选一个孤立尖峰（第 spikeFrame 帧 d = 100 ms）。
    /// 60 fps 的"摄像头"带 +33 ppm 漂移（自由跑的相机时钟）。和节目时钟严格锁相、pts 恰好落在拍点上的 60 fps 源，余量降过一个
    /// 拍点边界必然让两帧同时合格（一次 drop），零代价规则会让余量卡在边界上方 41 ns（多付一拍延迟，见报告 §5）；
    /// 30 fps 源隔拍才有帧，总有一拍没有帧卡在边界上，不受影响。
    static let camera60 = Rational(1000, 60_002)

    func simulateCamera(inputPeriod: Rational, ticks: Int, seed: UInt64 = 1, spikeFrame: Int64? = nil,
                        spikeExtra: HostDuration = HostDuration(milliseconds: 45)) -> Run {
        var extra: [Int64: HostDuration] = [0: HostDuration(milliseconds: 20)]
        if let k = spikeFrame { extra[k] = spikeExtra }
        return simulate(inputPeriod: inputPeriod, ticks: ticks, seed: seed, arrivalNs: (52_000_000, 58_000_000), extraLatency: extra)
    }

    /// 每拍：余量 ≤ 上限，上限 = 窗口最小 + 一个节目帧 + 保护带（保护带 ≤ 1 + 0.15 × 6 ms：可覆盖跨度不超过 52–58）。
    func assertMarginWithinCap(_ run: Run, from start: Int, file: StaticString = #filePath, line: UInt = #line) {
        for n in start..<run.margins.count where run.initialized[n] {
            let cap = HostDuration(ticks: run.caps[n]).milliseconds
            let windowMin = HostDuration(ticks: run.windowMins[n]).milliseconds
            XCTAssertLessThanOrEqual(HostDuration(ticks: run.margins[n]).milliseconds, cap + 0.001, "第 \(n) 拍余量超过上限", file: file, line: line)
            XCTAssertLessThanOrEqual(cap, windowMin + programFrameMs + 1 + 0.15 * 6 + 0.05, "第 \(n) 拍上限不是 d_min + 1 帧 + 保护带", file: file, line: line)
            XCTAssertGreaterThanOrEqual(windowMin, 52 - 0.001, "第 \(n) 拍窗口最小值", file: file, line: line)
        }
    }

    /// 60 fps 节目下的一帧（ms）。
    var programFrameMs: Double { 1000.0 / 60 }
    /// 裁定第 3 条的稳态上限：d_min + 一个节目帧 + 保护带（保护带 = 1 ms + 15% × 抖动跨度 6 ms）。
    var cameraMarginBoundMs: Double { 52 + programFrameMs + 1 + 0.15 * 6 }

    /// 起流后 `latest(forTick:)` 返回 nil 的拍数（槽里已有帧之后不得返回 nil）。
    func nilTicksAfterFirstFrame(_ run: Run) -> Int {
        zip(run.returned, run.initialized).filter { $0.0 < 0 && $0.1 }.count
    }

    /// 帧号序列里的"跳过"（相邻返回值差 > 1）：返回 (从, 到) 列表。
    func skips(_ run: Run) -> [(Int64, Int64)] {
        var out: [(Int64, Int64)] = []
        var last: Int64 = -1
        for s in run.returned where s >= 0 {
            if last >= 0, s > last + 1 { out.append((last, s)) }
            last = s
        }
        return out
    }

    /// 30 fps 摄像头进 60 fps：起流不黑（nil 拍 = 0）、第一帧慢不把余量顶飞、稳态余量 ≤ d_min + 1 帧 + 保护带、无迟到、V4 设计内。
    func testL1_highLatencySource_30into60_noNilAfterFirstFrame_marginWithinBound() {
        let run = simulateCamera(inputPeriod: Rational(1, 30), ticks: 2_400)
        XCTAssertEqual(nilTicksAfterFirstFrame(run), 0, "槽里有帧时不得返回 nil")
        XCTAssertEqual(run.pacing.lateFrames, 0, "余量盖住 52–58 ms 的抖动，没有迟到帧")
        XCTAssertEqual(run.stats.dropped, 0)
        XCTAssertEqual(run.stats.reused * 2, run.stats.consumed, accuracy: 2, "30 进 60 仍是精确 50%")
        // 第一帧 d₀ = 75：初值 = 75 + 1 ms（不再 × 2），随后被动态上限压到 d_min + 1 帧 + 保护带 以内（热身期也生效）
        let firstMargin = run.margins.first { $0 > 0 }.map { HostDuration(ticks: $0).milliseconds } ?? 0
        XCTAssertEqual(firstMargin, 76, accuracy: 0.5, "初值 = d₀ + 保护带（1 ms）")
        assertMarginWithinCap(run, from: 1)
        XCTAssertLessThanOrEqual(HostDuration(ticks: run.margins[2_399]).milliseconds, cameraMarginBoundMs + 0.05)
        // 稳态（热身 2 s 之后）：余量 ≈ 窗口最大 58 + 保护带 1.9 ± 滞回 1
        for n in 300..<run.margins.count {
            XCTAssertLessThanOrEqual(HostDuration(ticks: run.margins[n]).milliseconds, 58 + 1.9 + 1.05, "第 \(n) 拍余量没收敛到 d_max + 保护带")
            XCTAssertGreaterThanOrEqual(HostDuration(ticks: run.margins[n]).milliseconds, 58, "第 \(n) 拍余量低于 d_max，会迟到")
        }
        assertMatchesReference(run)
    }

    /// 60 fps 同延迟源：同样的断言。快 33 ppm 的源每 30000 拍设计内丢 1 帧；余量往下减时落在拍点边界上方 41 ns，
    /// 下一帧被漂移带过边界，那次设计内的 drop 提前发生（总数不变），所以 dropped ≤ 1 且逐拍与参考模型精确一致。
    func testL1_highLatencySource_60into60_noNilAfterFirstFrame_marginWithinBound() {
        let run = simulateCamera(inputPeriod: Self.camera60, ticks: 2_400, seed: 4)
        XCTAssertEqual(nilTicksAfterFirstFrame(run), 0)
        XCTAssertEqual(run.pacing.lateFrames, 0)
        XCTAssertLessThanOrEqual(run.stats.dropped, 1, "快源的设计内 drop 最多提前一次")
        XCTAssertEqual(run.stats.reused, 0, "快源：没有 reuse")
        assertMarginWithinCap(run, from: 1)
        XCTAssertLessThanOrEqual(HostDuration(ticks: run.margins[2_399]).milliseconds, cameraMarginBoundMs + 0.05)
        for n in 300..<run.margins.count {
            XCTAssertLessThanOrEqual(HostDuration(ticks: run.margins[n]).milliseconds, 58 + 1.9 + 1.05, "第 \(n) 拍")
            XCTAssertGreaterThanOrEqual(HostDuration(ticks: run.margins[n]).milliseconds, 58, "第 \(n) 拍")
        }
        assertMatchesReference(run)
    }

    /// 每帧连续被返回的拍数（帧号 → 拍数）。
    func runLengths(_ run: Run) -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for s in run.returned where s >= 0 { out[s, default: 0] += 1 }
        return out
    }

    /// 孤立尖峰（第 600 帧 d = 75 ms，比稳态余量晚 < 1 拍）：恰好一次迟到 = 那一拍多重复一次上一帧（30 进 60 的节奏 2-2 变成 3-1：
    /// 前一帧 3 拍、尖峰帧 1 拍，reuse 总数不变），不丢帧，余量抬高不超过上限、16 s 内回落。
    func testL1_highLatencySource_30into60_isolatedSpikeWithinOneTick_costsOneReuse_noDrop() {
        let spike = simulateCamera(inputPeriod: Rational(1, 30), ticks: 2_400, spikeFrame: 600, spikeExtra: HostDuration(milliseconds: 20))
        let base = simulateCamera(inputPeriod: Rational(1, 30), ticks: 2_400)
        XCTAssertEqual(spike.pacing.lateFrames, 1)
        XCTAssertEqual(spike.stats.dropped, 0, "晚 < 1 拍的帧不丢")
        XCTAssertTrue(skips(spike).isEmpty, "帧号只能重复或 +1")
        let lengths = runLengths(spike)
        XCTAssertEqual(lengths[599], 3, "尖峰帧迟到那一拍重复上一帧：599 被返回 3 拍")
        // 迟到把余量抬高（盖住 75 ms）= 相位后移，600 / 601 之一少占 1 拍（3-1-2 或 3-2-1），之后回到 2-2
        XCTAssertEqual((lengths[600] ?? 0) + (lengths[601] ?? 0), 3, "600 与 601 合计 3 拍（其中一帧只占 1 拍）")
        XCTAssertEqual(lengths[602], 2)
        XCTAssertEqual(lengths[598], 2)
        XCTAssertEqual(Int(spike.stats.reused) - Int(base.stats.reused), 0, "3-1 代替 2-2：reuse 总数不变")
        let detect = spike.lateFrames.firstIndex { $0 == 1 }!
        XCTAssertEqual(spike.returned[detect], 600, "检测那一拍返回迟到的帧本身")
        let peak = spike.margins[detect..<min(detect + 30, spike.margins.count)].max()!
        XCTAssertLessThanOrEqual(HostDuration(ticks: peak).milliseconds, cameraMarginBoundMs + 0.05, "尖峰不许把余量抬过上限")
        XCTAssertLessThanOrEqual(HostDuration(ticks: spike.margins[detect + 960]).milliseconds, 58 + 1.9 + 1.05, "16 s 内回落")
        XCTAssertEqual(nilTicksAfterFirstFrame(spike), 0)
    }

    /// 孤立 100 ms 尖峰（第 600 帧，比稳态余量晚 2.4–3 拍）：一次迟到；前一帧多重复（尖峰晚几拍就多几次）；余量抬到上限即止、
    /// 不再抬、16 s 内回落；除尖峰帧自己外没有帧被跳过（尖峰帧晚到 ≥ 2 拍时按文件头注释被跳过，≤ 1 drop；30 fps 源 33 ms 的帧距
    /// 装不下 45 ms 的迟到，"一次 dup 不丢帧"只对晚 < 1 拍的尖峰成立，见报告）。
    func testL1_highLatencySource_30into60_isolated100msSpike_oneLateEvent_atMostSpikeFrameDropped_marginRecovers() {
        for seed: UInt64 in [1, 2, 3] {
            let spike = simulateCamera(inputPeriod: Rational(1, 30), ticks: 2_400, seed: seed, spikeFrame: 600)
            let base = simulateCamera(inputPeriod: Rational(1, 30), ticks: 2_400, seed: seed)
            XCTAssertEqual(spike.pacing.lateFrames, 1, "种子 \(seed)")
            XCTAssertLessThanOrEqual(spike.stats.dropped, 1, "种子 \(seed)：最多丢尖峰帧自己")
            let sk = skips(spike)
            XCTAssertLessThanOrEqual(sk.count, 1, "种子 \(seed)")
            if let s = sk.first { XCTAssertEqual(s.0, 599, "种子 \(seed)"); XCTAssertEqual(s.1, 601, "种子 \(seed)：跳过的只能是尖峰帧") }
            XCTAssertLessThanOrEqual(Int(spike.stats.reused) - Int(base.stats.reused), 3, "种子 \(seed)：晚 ≤ 3 拍 → 多 ≤ 3 次 reuse")
            XCTAssertGreaterThanOrEqual(Int(spike.stats.reused) - Int(base.stats.reused), 0, "种子 \(seed)")
            let detect = spike.lateFrames.firstIndex { $0 == 1 }!
            let peak = spike.margins[detect..<min(detect + 60, spike.margins.count)].max()!
            XCTAssertLessThanOrEqual(HostDuration(ticks: peak).milliseconds, cameraMarginBoundMs + 0.05, "种子 \(seed)：尖峰不许把余量抬过上限")
            XCTAssertLessThanOrEqual(HostDuration(ticks: spike.margins[detect + 960]).milliseconds, 58 + 1.9 + 1.05, "种子 \(seed)：16 s 内回落")
            XCTAssertEqual(nilTicksAfterFirstFrame(spike), 0, "种子 \(seed)")
        }
    }

    /// 60 fps 同延迟源的 100 ms 尖峰：一次迟到、余量封在上限、回落；尖峰帧晚 2.4–3 拍 → 它被跳过，余量回落时再把快源的
    /// 设计内 drop 提前一次（见上一个用例）→ 比无尖峰的基线最多多 2 个 drop，且都在尖峰帧附近；其余不丢。
    func testL1_highLatencySource_60into60_isolated100msSpike_oneLateEvent_marginRecovers() {
        let spike = simulateCamera(inputPeriod: Self.camera60, ticks: 2_400, seed: 4, spikeFrame: 1200)
        let base = simulateCamera(inputPeriod: Self.camera60, ticks: 2_400, seed: 4)
        XCTAssertEqual(spike.pacing.lateFrames, 1)
        XCTAssertLessThanOrEqual(Int(spike.stats.dropped) - Int(base.stats.dropped), 2, "尖峰帧自己 + 提前的一次设计内 drop")
        let baseSkips = Set(skips(base).map { $0.0 })
        for s in skips(spike) where !baseSkips.contains(s.0) {
            XCTAssertTrue((1199...1210).contains(s.0), "尖峰之外不许多丢帧，实际 \(s)")
        }
        XCTAssertLessThanOrEqual(Int(spike.stats.reused) - Int(base.stats.reused), 3)
        let detect = spike.lateFrames.firstIndex { $0 == 1 }!
        let peak = spike.margins[detect..<min(detect + 60, spike.margins.count)].max()!
        XCTAssertLessThanOrEqual(HostDuration(ticks: peak).milliseconds, cameraMarginBoundMs + 0.05)
        XCTAssertLessThanOrEqual(HostDuration(ticks: spike.margins[detect + 960]).milliseconds, 58 + 1.9 + 1.05, "16 s 内回落")
        XCTAssertEqual(nilTicksAfterFirstFrame(spike), 0)
    }

    /// 估计器窗口按时间定长（8 × 1 s）：尖峰只影响 ≤ 8 s（prompt 的要求是 ≤ 16 s）；30 fps 和 60 fps 源的回落时间相同
    /// （不再是 8 × 60 帧 = 16 s / 8 s）。
    func testL1_estimatorWindow_timeBased_spikeLeavesWithin16s_sameForBothRates() {
        for (period, seed) in [(Rational(1, 30), UInt64(1)), (Self.camera60, UInt64(4))] {
            let spike = simulateCamera(inputPeriod: period, ticks: 2_400, seed: seed, spikeFrame: period == Rational(1, 30) ? 600 : 1200)
            let detect = spike.lateFrames.firstIndex { $0 == 1 }!
            // 回落 = 第一次回到 ≤ d_max + 保护带 + 滞回
            let bound = HostDuration(milliseconds: 58 + 1.9 + 1.05).ticks
            let back = (detect..<spike.margins.count).first { spike.margins[$0] <= bound }
            XCTAssertNotNil(back)
            if let back { XCTAssertLessThanOrEqual(back - detect, 480, "\(period)：尖峰后 \(back - detect) 拍才回落（8 × 1 s 窗口应 ≤ 8 s = 480 拍）") }
        }
    }

    /// 相机起流：前 7 帧 d = 92 / 57 / 73 / 71 / 70 / 71 / 62 ms（2026-09-19 内置相机 clocks 实测），之后 54 ± 1。这些帧超过
    /// d_min + 一帧 的不计入可覆盖最大值（每块最大 8 个样本），起流块在窗口有两个完整块后（2 s）作废：3 s 后余量 ≤ 55 + 保护带 + 滞回。
    func testL1_cameraStartupTransient_doesNotPinMargin_forWholeWindow() {
        let startup: [Int64: HostDuration] = [0: HostDuration(milliseconds: 38), 2: HostDuration(milliseconds: 19), 3: HostDuration(milliseconds: 17),
                                              4: HostDuration(milliseconds: 16), 5: HostDuration(milliseconds: 17), 6: HostDuration(milliseconds: 8)]
        let run = simulate(inputPeriod: Rational(1, 30), ticks: 1_200, seed: 8, arrivalNs: (53_000_000, 55_000_000), extraLatency: startup)
        XCTAssertEqual(nilTicksAfterFirstFrame(run), 0)
        XCTAssertEqual(run.pacing.lateFrames, 0)
        XCTAssertEqual(run.stats.dropped, 0)
        let ms = { (n: Int) in HostDuration(ticks: run.margins[n]).milliseconds }
        XCTAssertLessThanOrEqual(ms(70), 53 + programFrameMs + 1 + 0.15 * 20 + 0.1, "热身期：余量 ≤ 上限")
        XCTAssertLessThanOrEqual(ms(100), 62 + 1 + 0.15 * 9 + 1.05, "1 s 后（热身结束）：≤ 可覆盖最大 62 + 保护带 + 滞回，不被 70–92 的起流帧钉住")
        XCTAssertLessThanOrEqual(ms(190), 55 + 1 + 0.15 * 2 + 1.05, "3 s 后（起流块作废）：≤ 稳态 55 + 保护带 + 滞回")
        for n in 190..<1_200 { XCTAssertLessThanOrEqual(ms(n), 55 + 1 + 0.15 * 2 + 1.05, "第 \(n) 拍") }
        assertMatchesReference(run)
    }

    /// 饿死保护（裁定第 2 条）：保护带故意设成 100 ms，30 fps、d = 5 ms 的源每帧要等 100 ms 才合格，候选表（3 格）装不下；
    /// 没有保护时第 4 帧到达会挤掉从未返回的最旧帧。有保护：表满且没有合格帧的那一拍把余量降到让最旧帧恰好合格 → 0 drop、不返回 nil。
    func testL1_starvationGuard_fullTableNoEligible_lowersMarginInsteadOfDropping() {
        let run = simulate(inputPeriod: Rational(1, 30), ticks: 1_200, seed: 6, arrivalNs: (5_000_000, 5_001_000)) { o in
            var o = o
            o.guardAbsolute = HostDuration(milliseconds: 100)
            return o
        }
        XCTAssertEqual(run.stats.dropped, 0, "表满时降余量代替挤掉")
        XCTAssertEqual(nilTicksAfterFirstFrame(run), 0)
        XCTAssertGreaterThanOrEqual(run.pacing.starvationRescues, 1)
        XCTAssertTrue(skips(run).isEmpty, "帧号只能重复或 +1")
    }

    /// 槽里有帧就不返回 nil：第一帧到达 0.5 ms 前那一拍（按余量 d₀ + 1 ms 它还不合格）也要出画——余量降到让它恰好合格。
    func testL1_neverNilWhenSlotHasFrames_firstFrameArrivingJustBeforeTick() {
        let slot = LockFreeFrameSlot(capacity: 3)
        var o = PacingOptions()
        o.programFrame = HostDuration(milliseconds: 1000.0 / 60)
        o.maxRaise = o.programFrame
        o.initialFloor = HostDuration(milliseconds: 1000.0 / 60 / 4)
        slot.configurePacing(o)
        let tick = HostTime(ticks: 1_000_000_000)
        let ingress = tick - HostDuration(milliseconds: 0.5)
        let pts = ingress - HostDuration(milliseconds: 55)      // d₀ = 55 ms → 初值 56 ms → pts > tick − 56，本不合格
        slot.push(TestFrames.frame(sequence: 1, pts: pts, ingress: ingress))
        let f = slot.latest(forTick: tick)
        XCTAssertEqual(f?.sequence, 1, "槽里有帧时不得返回 nil")
        XCTAssertEqual(slot.pacingStats.margin.milliseconds, 55.5, accuracy: 0.01, "余量降到让它此刻恰好合格")
        XCTAssertEqual(slot.pacingStats.starvationRescues, 1)
        XCTAssertEqual(slot.stats.dropped, 0)
    }

    /// 保护带的比例部分按抖动跨度算（裁定第 4 条）：d = 55 ± 3 → 保护带 = 1 + 0.15 × 6 = 1.9 ms（不是 1 + 0.15 × 58 = 9.7）。
    func testL1_guardBand_relativePartUsesJitterSpan_notAbsoluteLatency() {
        let run = simulateCamera(inputPeriod: Rational(1, 30), ticks: 2_400)
        let steady = HostDuration(ticks: run.margins[2_399]).milliseconds
        XCTAssertEqual(steady, run.pacing.windowMaxLatency.milliseconds + 1.9, accuracy: 1.1, "稳态余量 = 窗口最大 + 1 ms + 15% × 跨度（± 滞回）")
        XCTAssertLessThan(steady, 58 + 5, "按 d_max 绝对值算保护带会到 ~68 ms")
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
