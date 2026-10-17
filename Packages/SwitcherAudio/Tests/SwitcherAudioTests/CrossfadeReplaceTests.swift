import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// W1-B5（prompt 120，D10）：替换淡变 `SW_CMD_CROSSFADE_REPLACE`（`AudioMixer.crossfade(..., replacing: true)`）的实时侧口径。
/// Auto 中途按 Cut：长淡变还在走，集成层在 Cut 那一拍的对齐时刻排一条 1 块的短淡。要求：
///   1. 短淡起点之前长淡变照走（逐样本仍在 cos / sin 上）——默认语义在命令应用时就把长淡变撤了，afv 会向转场前的目标（旧 PGM 1、旧 PVW 0）
///      平滑回去，起点再跳回来；
///   2. 起点从当时的增益接着走（起点那一块里起点之前的几个样本按块首的值保持，不跳变），走满那一刻起 from 严格 0、to 严格 1；
///   3. 同槽位上还没开始的淡变在应用时就取消（同默认语义）。
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

    /// 同槽位上还没开始的替换淡变，被更新的那条在应用时取消：只有后一条在走，前一条的起点那里长淡变照走、不起短淡。
    func testD10_pendingReplaceIsCancelledByANewerOne() {
        let rig = makeDCPair()
        let base = rig.driver.blockIndex
        let long = point(rig, aheadBlocks: 5, sample: 100, base: base)
        let dur = 24_000
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: dur, startHostTime: long.time)
        var l = [Float]()
        rig.run(blocks: 40) { b in l.append(contentsOf: b.bus(.master).left) }
        let first = point(rig, aheadBlocks: 6, sample: 10, base: base)
        let second = point(rig, aheadBlocks: 12, sample: 30, base: base)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: first.time, replacing: true)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: second.time, replacing: true)
        rig.run(blocks: 30) { b in l.append(contentsOf: b.bus(.master).left) }
        // 第一条的起点之后（到第二条起点所在块之前）仍是长淡变
        let secondBlock = (second.index / 256) * 256
        for i in stride(from: first.index, to: secondBlock, by: 53) {
            let e = Double.pi / 2 * Double(i - long.index) / Double(dur)
            XCTAssertEqual(Double(l[i]), cos(e), accuracy: 2e-6, "样本 \(i)：被取消的那条不该起短淡")
        }
        for i in (second.index + 256)..<l.count { XCTAssertEqual(l[i], 0, "样本 \(i)") }
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }
}
