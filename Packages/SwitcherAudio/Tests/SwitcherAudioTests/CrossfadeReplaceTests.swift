import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// W1-B5（prompt 120，D10）：替换淡变 `SW_CMD_CROSSFADE_REPLACE`（`AudioMixer.crossfade(..., replacing: true)`）的实时侧口径。
/// Auto 中途按 Cut：长淡变还在走，集成层在 Cut 那一拍的对齐时刻排一条 1 块的短淡。要求：
///   1. 短淡起点之前长淡变照走（逐样本仍在 cos / sin 上）——默认语义在命令应用时就把长淡变撤了，afv 会向转场前的目标（旧 PGM 1、旧 PVW 0）
///      平滑回去，起点再跳回来；
///   2. 起点从当时的增益接着走（起点那一块里起点之前的几个样本按块首的值保持，不跳变），走满那一刻起 from 严格 0、to 严格 1；
///   3. 同槽位上还没开始的淡变：起点比新的一条早的照走、到新的一条起点再被接管（W1-D4，裁定 #17：Cut / Auto 起点也用替换语义，
///      隔不到 ~60 ms 的两次切换前一条通常还没开始）；起点不早于新的一条的在应用时取消（最新的命令说了算）。
/// 两路直流 1.0：A 全左、B 全右，左右声道各看一路的 AFV 增益（同 MixerTapAndAgeTests）。
final class CrossfadeReplaceTests: XCTestCase {
    let tpf = 1e9 / 48_000

    func makeDCPair() -> OfflineRig {
        let rig = OfflineRig()
        rig.addSource(slot: 0, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
        rig.addSource(slot: 1, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
        rig.mixer.setPan(slot: 0, -1)
        rig.mixer.setPan(slot: 1, 1)
        rig.mixer.setAFVGain(slot: 1, 0)
        rig.run(blocks: 200)
        return rig
    }

    /// 第 (当前 + ahead) 块的第 sample 个样本的 host time，和它在"从当前块起收集"的样本序列里的下标。
    func point(_ rig: OfflineRig, aheadBlocks: Int, sample: Int, base: Int) -> (time: HostTime, index: Int) {
        let block = rig.driver.blockIndex + aheadBlocks
        let t = HostTime(ticks: rig.driver.hostTime(ofBlock: block).ticks + UInt64((Double(sample) * tpf).rounded()))
        return (t, (block - base) * 256 + sample)
    }

    /// 长淡变（24000 帧）走到约 40% 时排一条替换短淡（256 帧）：起点之前逐样本仍在长淡变的 cos / sin 上，起点从当时的增益起走，走满后 0 / 1 精确。
    func testD10_replaceCrossfade_oldCurveRunsUntilTheNewStart_thenShortFadeFromThere() {
        let rig = makeDCPair()
        let base = rig.driver.blockIndex
        let long = point(rig, aheadBlocks: 5, sample: 100, base: base)
        let dur = 24_000
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: dur, startHostTime: long.time)
        var l = [Float](), r = [Float]()
        let collect: (OfflineBlock) -> Void = { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        rig.run(blocks: 40, afterEach: collect)                        // 长淡变走到 ~ (40 − 5) × 256 = 8860 帧
        // 替换短淡排在 8 块之后（≈ 对齐延迟那么远），命令这一块就应用
        let short = point(rig, aheadBlocks: 8, sample: 50, base: base)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: short.time, replacing: true)
        rig.run(blocks: 30, afterEach: collect)
        let s0 = long.index, s2 = short.index
        let startBlock = (s2 / 256) * 256                              // 短淡起点所在块的块首
        // 1. 命令应用之后到起点所在块之前：逐样本仍是长淡变（旧语义这里会向 1 / 0 回弹）
        for i in stride(from: s0 + 1, to: startBlock, by: 97) {
            let e = Double.pi / 2 * Double(i - s0) / Double(dur)
            XCTAssertEqual(Double(l[i]), cos(e), accuracy: 2e-6, "样本 \(i)：短淡起点之前 from 应仍在长淡变上")
            XCTAssertEqual(Double(r[i]), sin(e), accuracy: 2e-6, "样本 \(i)：短淡起点之前 to 应仍在长淡变上")
        }
        // 2. 起点所在块：起点之前按块首的值保持（= 上一块最后一个样本），起点起 a·cos / b + (1 − b)·sin
        let a = l[startBlock - 1], b = r[startBlock - 1]
        for i in startBlock..<s2 {
            XCTAssertEqual(l[i], a, accuracy: 1e-6, "样本 \(i)：起点前保持"); XCTAssertEqual(r[i], b, accuracy: 1e-6, "样本 \(i)：起点前保持")
        }
        for k in [0, 1, 64, 128, 200, 255] {
            let e = Double.pi / 2 * Double(k) / 256
            XCTAssertEqual(Double(l[s2 + k]), Double(a) * cos(e), accuracy: 2e-6, "短淡 +\(k) from")
            XCTAssertEqual(Double(r[s2 + k]), Double(b) + (1 - Double(b)) * sin(e), accuracy: 2e-6, "短淡 +\(k) to")
        }
        // 3. 走满起：from 严格 0、to 满，一直到最后（长淡变不会在短淡之后又冒出来）
        for i in (s2 + 256)..<l.count {
            XCTAssertEqual(l[i], 0, "样本 \(i)（短淡终点后 \(i - s2 - 256)）from 应严格 0")
            XCTAssertEqual(Double(r[i]), 1.0, accuracy: 2e-7)
        }
        // 4. 全程 from 不升、to 不降（不回弹），相邻样本没有跳变
        var maxRise: Float = 0, maxFall: Float = 0, maxJump: Float = 0
        for i in (s0 + 1)..<l.count {
            maxRise = max(maxRise, l[i] - l[i - 1]); maxFall = max(maxFall, r[i - 1] - r[i])
            maxJump = max(maxJump, abs(l[i] - l[i - 1]), abs(r[i] - r[i - 1]))
        }
        XCTAssertLessThanOrEqual(maxRise, 1e-6, "from 不该回升")
        XCTAssertLessThanOrEqual(maxFall, 1e-6, "to 不该回落")
        XCTAssertLessThan(maxJump, 0.01, "1 块等幅短淡每样本最多变 π/2/256 ≈ 0.006")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 对照：默认语义没变（Cut / Auto 起点照旧用它）——命令一应用就撤掉长淡变，起点之前 from 向转场前的目标 1 回弹，
    /// 起点那一块再跳回命令应用时的值（这就是不能拿它给 Auto 中途 Cut 收口的原因）。
    func testD10_plainCrossfadeStillCancelsAtApply_contrast() {
        let rig = makeDCPair()
        let base = rig.driver.blockIndex
        let long = point(rig, aheadBlocks: 5, sample: 100, base: base)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 24_000, startHostTime: long.time)
        var l = [Float]()
        rig.run(blocks: 40) { b in l.append(contentsOf: b.bus(.master).left) }
        let short = point(rig, aheadBlocks: 8, sample: 50, base: base)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: short.time)
        rig.run(blocks: 30) { b in l.append(contentsOf: b.bus(.master).left) }
        let atCommand = l[40 * 256 - 1]
        let gapEnd = l[(short.index / 256) * 256 - 1]               // 起点所在块之前的最后一个样本
        XCTAssertGreaterThan(gapEnd, atCommand + 0.05, "默认语义：命令应用后 from 向 1 回弹（\(atCommand) → \(gapEnd)）")
        XCTAssertLessThan(l[short.index - 1], gapEnd - 0.05, "起点那一块跳回命令应用时取的值")
        XCTAssertEqual(l[short.index + 300], 0)
    }

    /// W1-D4 第 1 条（裁定 #17，Cut / Auto 起点也用替换语义之后）：同槽位上**还没开始、但起点比新的一条早**的替换淡变不在应用时撤——
    /// 它到自己的起点照走，新的一条到自己的起点再接管。两次切换隔不到 ~60 ms 时后一条的命令到这里那一刻前一条通常还没开始（起点 = 拍点 + 对齐延迟），
    /// 原来（W1-B5 的语义，也是本用例的前身 testD10_pendingReplaceIsCancelledByANewerOne）在应用时就把它撤了：前一次切换整个听不见。
    /// 这里两条同方向（长淡变 → 第一条短淡收口 → 第二条）：第一条起点之后 256 帧 from 就是 0，一直到最后（第二条接管时已是 0）。
    func testW1D4_1_pendingEarlierReplaceRunsAtItsStart_newerTakesOverAtItsOwn() {
        let rig = makeDCPair()
        let base = rig.driver.blockIndex
        let long = point(rig, aheadBlocks: 5, sample: 100, base: base)
        let dur = 24_000
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: dur, startHostTime: long.time)
        var l = [Float](), r = [Float]()
        let collect: (OfflineBlock) -> Void = { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        rig.run(blocks: 40, afterEach: collect)
        let first = point(rig, aheadBlocks: 6, sample: 10, base: base)
        let second = point(rig, aheadBlocks: 12, sample: 30, base: base)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: first.time, replacing: true)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: second.time, replacing: true)
        rig.run(blocks: 30, afterEach: collect)
        // 第一条起点所在块之前：长淡变照走
        let firstBlock = (first.index / 256) * 256
        for i in stride(from: 40 * 256, to: firstBlock, by: 37) {
            let e = Double.pi / 2 * Double(i - long.index) / Double(dur)
            XCTAssertEqual(Double(l[i]), cos(e), accuracy: 2e-6, "样本 \(i)：第一条起点之前仍在长淡变上")
        }
        // 第一条起点起短淡：从块首保持的值 a 按 a·cos 走到 0
        let a = l[firstBlock - 1]
        for k in [0, 64, 128, 255] {
            XCTAssertEqual(Double(l[first.index + k]), Double(a) * cos(Double.pi / 2 * Double(k) / 256), accuracy: 2e-6, "第一条短淡 +\(k)")
        }
        // 第一条走满起（到第二条起点、之后第二条接管）：from 严格 0、to 满
        let tail = (first.index + 256)..<l.count
        let badL = tail.filter { l[$0] != 0 }, badR = tail.filter { abs(Double(r[$0]) - 1) > 2e-7 }
        XCTAssertEqual(badL.count, 0, "第一条走满之后 from 应严格 0（被提前撤掉的话这里还在长淡变上）：\(badL.count) 个样本不是，第一个 \(badL.first.map { "样本 \($0) = \(l[$0])" } ?? "—")")
        XCTAssertEqual(badR.count, 0, "第一条走满之后 to 应满：\(badR.count) 个样本不是")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 对照：起点**不早于**新的一条的、还没开始的同槽位淡变，新的一条应用时就撤掉（最新的命令说了算；引擎只会在"开 AFV 时补的跟随淡变"
    /// 起点落在过去时碰到）。这里旧的一条起点更晚、方向相反：留着它的话起点处 L / R 会对调；撤掉之后只有新的一条（from 已是 0、to 已是 1，不变）。
    func testW1D4_1_pendingLaterReplaceIsSupersededByANewerOne() {
        let rig = makeDCPair()
        let base = rig.driver.blockIndex
        let later = point(rig, aheadBlocks: 12, sample: 30, base: base)
        let sooner = point(rig, aheadBlocks: 6, sample: 10, base: base)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: later.time, replacing: true)   // 旧：L → 0、R → 1
        rig.mixer.crossfade(from: 1, to: 0, durationFrames: 256, startHostTime: sooner.time, replacing: true)  // 新：L 留 1、R 留 0
        var l = [Float](), r = [Float]()
        rig.run(blocks: 30) { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        let badL = l.indices.filter { abs(Double(l[$0]) - 1) > 2e-7 }, badR = r.indices.filter { r[$0] != 0 }
        XCTAssertEqual(badL.count, 0, "被新命令盖掉的旧淡变不该在它的起点对调：L \(badL.count) 个样本不是 1，第一个 \(badL.first.map { "样本 \($0) = \(l[$0])" } ?? "—")")
        XCTAssertEqual(badR.count, 0, "R \(badR.count) 个样本不是 0")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// W1-D4 第 2 条（Auto 进行中才开 AFV）的实时侧：跟随淡变 `SW_CMD_CROSSFADE_FOLLOW`（`crossfade(..., following: true)`）。
    /// 两路门控都开着（AFV 关时的样子：L = R = 1），排一条起点在 47 块之前（约 0.25 s，转场已经走了一半）、时长 24000 帧的跟随淡变：
    ///   1. 接上那一块第一个样本 = 接上之前的增益（不跳变），之后与曲线的差按 τ 3 ms 衰减，逐样本变化不超过一阶平滑的量级；
    ///   2. 接上 50 ms 之后逐样本就是 cos / sin 的**绝对值**（不乘起点的增益 1：替换语义的普通淡变会走 1·cos / 1 + 0·sin，PVW 停在 1）；
    ///   3. 走满那一刻起 from 严格 0、to 严格 1。
    func testW1D4_2_followCrossfade_lateJoinTracksTheAbsoluteCurve_smoothJoin() {
        let rig = makeDCPair()
        rig.mixer.setAFVGain(slot: 1, 1)
        rig.run(blocks: 50)
        var l = [Float](), r = [Float]()
        let collect: (OfflineBlock) -> Void = { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        rig.run(blocks: 1, afterEach: collect)                        // 接上之前的最后一块
        let before = (l.last!, r.last!)
        l.removeAll(); r.removeAll()
        let base = rig.driver.blockIndex
        let start = point(rig, aheadBlocks: -47, sample: 0, base: base)
        let dur = 24_000
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: dur, startHostTime: start.time, following: true)
        rig.run(blocks: 90, afterEach: collect)
        let k0 = -start.index                                         // 接上那一块第一个样本在曲线上的位置（47 × 256 帧）
        func ang(_ i: Int) -> Double { Double.pi / 2 * Double(k0 + i) / Double(dur) }
        // 1. 接上不跳变：第一个样本 = 之前的增益；之后逐样本变化 ≤ 0.003（残差 ≈ 0.3 × 一阶平滑系数 0.0069 + 曲线斜率）
        XCTAssertEqual(l[0], before.0, accuracy: 1e-6, "接上那一下 from 不跳变")
        XCTAssertEqual(r[0], before.1, accuracy: 1e-6, "接上那一下 to 不跳变")
        var maxStep: Float = 0
        for i in 1..<2400 { maxStep = max(maxStep, abs(l[i] - l[i - 1]), abs(r[i] - r[i - 1])) }
        XCTAssertLessThan(maxStep, 0.003, "接上之后逐样本变化 \(maxStep)")
        // 2. 50 ms 之后：绝对的 cos / sin。迟到接上时 C 侧按 tick 差换算已走帧数、截断取整，相位可能差 1 帧（k − 1），两种都算对
        let end = dur - k0
        var maxErr = 0.0
        for i in 2400..<end {
            let e = min(abs(Double(l[i]) - cos(ang(i))), abs(Double(l[i]) - cos(ang(i - 1))))
            let f = min(abs(Double(r[i]) - sin(ang(i))), abs(Double(r[i]) - sin(ang(i - 1))))
            maxErr = max(maxErr, e, f)
        }
        XCTAssertLessThan(maxErr, 2e-6, "接上 50 ms 后应在曲线上（最大差 \(maxErr)）")
        // 3. 走满（同样留 1 帧相位）：from 严格 0、to 满（R 声道稳态本来就是 1 ± 2e-7，同本文件其它用例）
        let tail = (end + 1)..<l.count
        XCTAssertGreaterThan(tail.count, 5_000)
        XCTAssertEqual(tail.filter { l[$0] != 0 }.count, 0, "走满之后 from 严格 0")
        XCTAssertEqual(tail.filter { abs(Double(r[$0]) - 1) > 2e-7 }.count, 0, "走满之后 to 满")
        print("W1-D4 跟随淡变（混音器）：接上前 \(before.0) / \(before.1) → 第一个样本 \(l[0]) / \(r[0])，接上后逐样本最大变化 \(maxStep)，50 ms 后与 cos / sin 最大差 \(maxErr)")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 第 1 条的另一种相位（连按两下 Cut、第二条命令到时第一条正在走）：反方向的替换淡变不撤正在走的那条，第一条照走到第二条的起点，
    /// 第二条从那一刻的增益接着走回去。默认语义在这里会撤掉第一条、afv 向转场前的目标回弹约 60 ms、起点再跳回（testD10_plainCrossfadeStillCancelsAtApply_contrast）。
    func testW1D4_1_reverseReplaceWhileTheFirstIsRunning_noRebound() {
        let rig = makeDCPair()
        let base = rig.driver.blockIndex
        let first = point(rig, aheadBlocks: 5, sample: 100, base: base)
        let dur = 4_800
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: dur, startHostTime: first.time, replacing: true)
        var l = [Float](), r = [Float]()
        let collect: (OfflineBlock) -> Void = { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        rig.run(blocks: 11, afterEach: collect)                       // 第一条走到约 30%
        let back = point(rig, aheadBlocks: 5, sample: 70, base: base) // 第一条约 57% 处切回
        rig.mixer.crossfade(from: 1, to: 0, durationFrames: 256, startHostTime: back.time, replacing: true)
        rig.run(blocks: 20, afterEach: collect)
        let backBlock = (back.index / 256) * 256
        // 起点所在块之前：逐样本仍在第一条上（不回弹）
        for i in stride(from: first.index, to: backBlock, by: 29) {
            let e = Double.pi / 2 * Double(i - first.index) / Double(dur)
            XCTAssertEqual(Double(l[i]), cos(e), accuracy: 2e-6, "样本 \(i)：L 应仍在第一条的 cos 上")
            XCTAssertEqual(Double(r[i]), sin(e), accuracy: 2e-6, "样本 \(i)：R 应仍在第一条的 sin 上")
        }
        // 第二条：from = R（从 b 起 b·cos → 0），to = L（从 a 起 a + (1 − a)·sin → 1）
        let a = l[backBlock - 1], b = r[backBlock - 1]
        for k in [0, 1, 64, 128, 255] {
            let e = Double.pi / 2 * Double(k) / 256
            XCTAssertEqual(Double(r[back.index + k]), Double(b) * cos(e), accuracy: 2e-6, "第二条 +\(k) from（R）")
            XCTAssertEqual(Double(l[back.index + k]), Double(a) + (1 - Double(a)) * sin(e), accuracy: 2e-6, "第二条 +\(k) to（L）")
        }
        let tail = (back.index + 256)..<l.count
        XCTAssertEqual(tail.filter { r[$0] != 0 }.count, 0, "第二条走满之后 R 应严格 0")
        XCTAssertEqual(tail.filter { abs(Double(l[$0]) - 1) > 2e-7 }.count, 0, "第二条走满之后 L 应满")
        // 全程：L 在第二条起点之前不升、之后不降；相邻样本没有跳变
        var maxJump: Float = 0
        var rebound: Float = 0
        for i in (first.index + 1)..<l.count {
            if i < back.index { rebound = max(rebound, l[i] - l[i - 1]) }
            maxJump = max(maxJump, abs(l[i] - l[i - 1]), abs(r[i] - r[i - 1]))
        }
        XCTAssertLessThanOrEqual(rebound, 1e-6, "第二条起点之前 L 回弹 \(rebound)")
        XCTAssertLessThan(maxJump, 0.01)
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }
}
