import XCTest
import SwitcherContracts
@testable import SwitcherTestKit

/// frameprobe 分析算法（纯函数）对手工构造序列的结果。测试 ID 对应测试标准 V4–V7、A2–A4。
final class FrameAnalysisTests: XCTestCase {
    /// 造一段"节目输出"：每帧 (输入 ID, 帧号, 灰度, 闪光)。
    private func frames(_ spec: [(id: Int?, n: UInt32?, gray: Double, flash: Bool)], fps: Double = 60) -> [ProbeFrame] {
        spec.enumerated().map { i, s in
            ProbeFrame(index: i, ptsSeconds: Double(i) / fps, frameNumber: s.n, inputID: s.id, genTimeMs: s.n.map { $0 * 16 }, flash: s.flash, gray: s.gray)
        }
    }

    // MARK: V4 / V5

    func testV4_stats_30fpsSourceIn60fpsProgram_isDesignInternal() {
        // 600 帧节目，输入 1（30 fps）每帧重复两次：0,0,1,1,2,2…
        var spec: [(Int?, UInt32?, Double, Bool)] = []
        for i in 0..<600 { spec.append((1, UInt32(i / 2), 128, false)) }
        let r = FrameAnalysis.stats(frames: frames(spec), programFps: 60, inputFps: [1: 30])
        XCTAssertEqual(r.totalFrames, 600)
        XCTAssertEqual(r.expectedFrames, 600)
        XCTAssertEqual(r.frameCountDelta, 0, "V5")
        let s = r.inputs[0]
        XCTAssertEqual(s.frames, 600); XCTAssertEqual(s.uniqueFrames, 300); XCTAssertEqual(s.duplicateFrames, 300)
        XCTAssertEqual(s.duplicateRatio, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.designDuplicateRatio!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.excessDuplicateRatio!, 0, accuracy: 1e-9)
        XCTAssertEqual(s.duplicateRuns.count, 200, "maxEvents 默认 200 截断"); XCTAssertTrue(r.truncated)
        XCTAssertEqual(s.duplicateRuns[0], FrameAnalysis.DuplicateRun(index: 0, length: 2, frameNumber: 0))
        XCTAssertEqual(s.passV4, true)
    }

    func testV4_stats_dropEvery20_reports5pct() {
        // 60 fps 源在 60 fps 节目里，每 20 帧丢 1（帧号 19、39、… 缺）
        var spec: [(Int?, UInt32?, Double, Bool)] = []
        for n in 0..<600 where n % 20 != 19 { spec.append((2, UInt32(n), 128, false)) }
        let r = FrameAnalysis.stats(frames: frames(spec), programFps: 60, inputFps: [2: 60])
        let s = r.inputs[0]
        XCTAssertEqual(s.frames, 570); XCTAssertEqual(s.droppedFrames, 29, "最后一帧 599 后面的缺口看不见")
        XCTAssertEqual(s.dropRatio, 29.0 / 599.0, accuracy: 1e-9)
        XCTAssertEqual(s.dropGaps.first, FrameAnalysis.DropGap(index: 19, from: 18, to: 20, missing: 1))
        XCTAssertEqual(s.designDropRatio!, 0, accuracy: 1e-9)
        XCTAssertEqual(s.excessDropRatio!, 29.0 / 599.0, accuracy: 1e-9)
        XCTAssertEqual(s.passV4, false)
        XCTAssertEqual(r.frameCountDelta, 0, "节目本身没少帧")
    }

    func testV4_stats_wrapAround28bitIsNotADrop() {
        let top = TestPattern.dataMask
        let spec: [(Int?, UInt32?, Double, Bool)] = [(1, top - 1, 128, false), (1, top, 128, false), (1, 0, 128, false), (1, 1, 128, false), (1, 3, 128, false)]
        let s = FrameAnalysis.stats(frames: frames(spec), programFps: 60).inputs[0]
        XCTAssertEqual(s.droppedFrames, 1); XCTAssertEqual(s.backwardJumps, 0); XCTAssertEqual(s.uniqueFrames, 5)
    }

    func testV5_stats_missingOutputFramesShowInDelta() {
        // 100 帧 pts 却跨了 110 帧的时长（中间有 10 帧没写出来）
        var f: [ProbeFrame] = []
        for i in 0..<100 { f.append(ProbeFrame(index: i, ptsSeconds: Double(i < 50 ? i : i + 10) / 60, frameNumber: UInt32(i), inputID: 1, genTimeMs: 0, flash: false, gray: 128)) }
        let r = FrameAnalysis.stats(frames: f, programFps: 60)
        XCTAssertEqual(r.expectedFrames, 110); XCTAssertEqual(r.frameCountDelta, -10)
        XCTAssertEqual(r.undecodableFrames, 0); XCTAssertEqual(r.unidentifiedFrames, 0)
    }

    // MARK: V6

    func testV6_switches_cleanCutAndMixedCutDistinguished() {
        var spec: [(Int?, UInt32?, Double, Bool)] = []
        for n in 0..<10 { spec.append((0, UInt32(n), 64, false)) }
        for n in 0..<10 { spec.append((1, UInt32(n), 192, false)) }   // 干净 Cut 在 index 10
        spec.append((nil, nil, 128, false))                            // index 20：混合帧
        for n in 0..<5 { spec.append((0, UInt32(n), 64, false)) }     // index 21 起回 A
        spec.append((1, 0, 192, false))                                // index 26：Cut 到 B
        spec.append((1, 1, 130, false))                                // index 27：Cut 后一帧混合
        spec.append((1, 2, 192, false))
        let r = FrameAnalysis.switches(frames: frames(spec), startTick: 1000)
        XCTAssertEqual(r.nominalGrays, [.init(inputID: 0, gray: 64), .init(inputID: 1, gray: 192)])
        XCTAssertEqual(r.switches.map(\.kind), ["start", "cut", "transition", "cut"])
        let cut1 = r.switches[1]
        XCTAssertEqual(cut1.index, 10); XCTAssertEqual(cut1.tick, 1010); XCTAssertEqual(cut1.from, 0); XCTAssertEqual(cut1.to, 1)
        XCTAssertTrue(cut1.cleanCut)
        let tr = r.switches[2]
        XCTAssertEqual(tr.index, 21); XCTAssertEqual(tr.lastFromIndex, 19); XCTAssertEqual(tr.betweenFrames, 1)
        XCTAssertTrue(tr.mixedBefore)
        let cut2 = r.switches[3]
        XCTAssertEqual(cut2.index, 26); XCTAssertFalse(cut2.mixedAt); XCTAssertTrue(cut2.mixedAfter); XCTAssertFalse(cut2.cleanCut)
        XCTAssertFalse(r.allCutsClean)
    }

    // MARK: V7

    func testV7_fade_linearRampHasZeroDeviation() {
        // A(64) 10 帧，30 拍 Fade：29 个混合帧 progress k/30，然后 B(192)
        var spec: [(Int?, UInt32?, Double, Bool)] = []
        for n in 0..<10 { spec.append((0, UInt32(n), 64, false)) }
        for k in 1...29 { spec.append((nil, nil, 64 + 128 * Double(k) / 30, false)) }
        for n in 0..<10 { spec.append((1, UInt32(n), 192, false)) }
        let r = FrameAnalysis.fade(frames: frames(spec), startTick: 3000)
        XCTAssertEqual(r.fades.count, 1)
        let f = r.fades[0]
        XCTAssertEqual(f.startIndex, 10); XCTAssertEqual(f.endIndex, 38); XCTAssertEqual(f.mixedFrames, 29)
        XCTAssertEqual(f.durationTicks, 30); XCTAssertEqual(f.direction, "A→B"); XCTAssertEqual(f.startTick, 3010)
        XCTAssertEqual(f.maxDeviationFrames, 0, accuracy: 1e-9)
        XCTAssertTrue(f.monotonic); XCTAssertTrue(f.passV7); XCTAssertTrue(r.allPassV7)
        XCTAssertEqual(f.samples[14].expectedProgress, 0.5, accuracy: 1e-9)
    }

    func testV7_fade_twoFrameLagFailsThreshold_andReverseDirection() {
        // B→A，30 拍，命令在拍 4（index 4 是最后一个纯 B 帧），但曲线整体滞后 2 帧：第 k 个混合帧 progress = max(0, k−2)/30
        var spec: [(Int?, UInt32?, Double, Bool)] = []
        for n in 0..<5 { spec.append((1, UInt32(n), 192, false)) }
        for k in 1...29 { spec.append((nil, nil, 192 - 128 * Double(max(0, k - 2)) / 30, false)) }
        for n in 0..<5 { spec.append((0, UInt32(n), 64, false)) }
        // 指定模式：看得见滞后
        let r = FrameAnalysis.fade(frames: frames(spec), durationTicks: 30, at: 4)
        let f = r.fades[0]
        XCTAssertEqual(f.direction, "B→A"); XCTAssertEqual(f.startIndex, 5); XCTAssertEqual(f.endIndex, 33); XCTAssertEqual(f.durationTicks, 30)
        XCTAssertEqual(f.maxDeviationFrames, 2, accuracy: 1e-9)
        XCTAssertFalse(f.passV7); XCTAssertFalse(r.allPassV7)
        // 自动模式：头两帧是纯 B，run 从第 3 个起共 27 帧，形状仍是线性 → 看不见滞后（文档写明）
        let auto = FrameAnalysis.fade(frames: frames(spec), durationTicks: 30)
        XCTAssertEqual(auto.fades[0].mixedFrames, 27); XCTAssertEqual(auto.fades[0].startIndex, 7)
        XCTAssertEqual(auto.fades[0].maxDeviationFrames, 0, accuracy: 1e-9)
        // 自动且不给 D：按 27 + 1 = 28 推断，k/30 对 k/28 的最大偏差 = 27 × (1 − 28/30) = 1.8 帧
        let r2 = FrameAnalysis.fade(frames: frames(spec))
        XCTAssertEqual(r2.fades[0].durationTicks, 28)
        XCTAssertEqual(r2.fades[0].maxDeviationFrames, 1.8, accuracy: 0.01)
    }

    func testV7_fade_explicitModeAlsoCatchesNonLinearCurve() {
        // A→B，命令在拍 9，D = 30，曲线是 ease（k/D 的平方）
        var spec: [(Int?, UInt32?, Double, Bool)] = []
        for n in 0..<10 { spec.append((0, UInt32(n), 64, false)) }
        for k in 1...29 { let p = pow(Double(k) / 30, 2); spec.append((nil, nil, 64 + 128 * p, false)) }
        for n in 0..<10 { spec.append((1, UInt32(n), 192, false)) }
        let r = FrameAnalysis.fade(frames: frames(spec), durationTicks: 30, at: 9)
        // 最大偏差在 k = 15：15 − 30 × 0.25 = 7.5 帧
        XCTAssertEqual(r.fades[0].maxDeviationFrames, 7.5, accuracy: 1e-9)
        XCTAssertTrue(r.fades[0].monotonic); XCTAssertFalse(r.fades[0].passV7)
    }

    // MARK: A2 / A3

    func testA2_av_offsetSignAndStats() {
        // 闪光在 k + 0.002 s（视频晚 2 ms = 音频超前 → +2 ms），click 在 k s；30 fps 源在 60 fps 节目里闪光帧连着两帧
        var f: [ProbeFrame] = []
        var idx = 0
        for k in 0..<10 {
            for j in 0..<60 {
                let flash = j == 0 || j == 1
                f.append(ProbeFrame(index: idx, ptsSeconds: Double(k) + Double(j) / 60 + 0.002, frameNumber: UInt32(idx / 2), inputID: 1,
                                    genTimeMs: UInt32((Double(k) + Double(j) / 60) * 1000), flash: flash, gray: 128))
                idx += 1
            }
        }
        let clicks = (0..<10).map { ClickEvent(sampleIndex: Int64($0) * 48000, timeSeconds: Double($0), peak: 1) }
        let r = FrameAnalysis.av(frames: f, clicks: clicks)
        XCTAssertEqual(r.flashCount, 10, "连续两帧闪光只算一个事件"); XCTAssertEqual(r.matchedCount, 10)
        XCTAssertEqual(r.meanMs, 2, accuracy: 1e-6); XCTAssertEqual(r.stdMs, 0, accuracy: 1e-6)
        XCTAssertEqual(r.maxAbsMs, 2, accuracy: 1e-6); XCTAssertEqual(r.slopeMsPerSecond, 0, accuracy: 1e-9)
        XCTAssertEqual(r.passA2, true)
    }

    func testA3_av_driftShowsAsSlope() {
        // click 比闪光每秒晚 0.1 ms（音频时钟慢 100 ppm）：offset = −0.1 × k ms
        var f: [ProbeFrame] = []
        for k in 0..<100 {
            f.append(ProbeFrame(index: 2 * k, ptsSeconds: Double(k), frameNumber: UInt32(k), inputID: 1, genTimeMs: UInt32(k * 1000), flash: true, gray: 128))
            f.append(ProbeFrame(index: 2 * k + 1, ptsSeconds: Double(k) + 0.5, frameNumber: UInt32(k), inputID: 1, genTimeMs: UInt32(k * 1000 + 500), flash: false, gray: 128))
        }
        let clicks = (0..<100).map { ClickEvent(sampleIndex: 0, timeSeconds: Double($0) * (1 + 1e-4), peak: 1) }
        let r = FrameAnalysis.av(frames: f, clicks: clicks)
        XCTAssertEqual(r.slopeMsPerSecond, -0.1, accuracy: 1e-6)
        XCTAssertEqual(r.spanSeconds, 99, accuracy: 1e-9)
        XCTAssertEqual(r.driftOverSpanMs, -9.9, accuracy: 1e-6)
        XCTAssertEqual(r.maxAbsMs, 9.9, accuracy: 1e-6)
        XCTAssertEqual(r.passA2, true)
    }

    /// 整秒拍配对（prompt 44 交付 3）：60 fps 节目里 59.94 的路在播时闪光周期 1.001 s（契约定的），闪光相对整秒 click 每秒滞后 1 ms；
    /// 只有闪光落在整秒拍（拍号是标称帧率的倍数）上的配对进 A2 / A3 判定，全部配对另报。
    func testA2_av_onSecondPairs_exclude5994DriftAndDriveVerdict() {
        var f: [ProbeFrame] = []
        var idx = 0
        // 0–9 s：60 fps 路在播（闪光在整秒拍），10–29 s：59.94 的路在播（第 k 个闪光在 1.001 k s → 拍 ceil(60.06 k)），30–39 s 回到 60 fps 路
        for tick in 0..<(40 * 60) {
            let t = Double(tick) / 60
            let onAir5994 = (10..<30).contains(t)
            var flash = false
            if onAir5994 {
                // 59.94 的闪光帧 60k 的 pts = 1.001 k，被拍点 ≥ pts 的第一拍选中
                let k = Int((t / 1.001).rounded(.down))
                let flashTick = Int((1.001 * Double(k) * 60).rounded(.up))
                flash = tick == flashTick
            } else {
                flash = tick % 60 == 0
            }
            f.append(ProbeFrame(index: idx, ptsSeconds: t, frameNumber: UInt32(tick), inputID: onAir5994 ? 2 : 1, genTimeMs: UInt32(t * 1000), flash: flash, gray: 128))
            idx += 1
        }
        let clicks = (0..<40).map { ClickEvent(sampleIndex: Int64($0) * 48000, timeSeconds: Double($0) + 0.0005, peak: 1) } // 音频落后 0.5 ms → 偏移 −0.5 ms
        let r = FrameAnalysis.av(frames: f, clicks: clicks, frameDurationSeconds: 1.0 / 60)
        XCTAssertEqual(r.flashCount, 40)
        XCTAssertEqual(r.onSecond.count, 20, "0–9 与 30–39 s 的 20 个闪光在整秒拍上")
        XCTAssertEqual(r.offSecondCount, 20)
        XCTAssertEqual(r.onSecond.meanMs, -0.5, accuracy: 1e-6)
        XCTAssertEqual(r.onSecond.maxAbsMs, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.onSecond.slopeMsPerSecond, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(r.meanMs, 5, "全部配对的均值被 59.94 段拉偏（闪光比 click 晚 10…29 ms = 音频超前为正）")
        XCTAssertGreaterThan(r.maxAbsMs, 20)
        XCTAssertEqual(r.passA2, true, "A2 按整秒配对判：|0.5| ≤ 16.7")
        XCTAssertNotNil(r.note)
        for p in r.pairs { XCTAssertEqual(p.onSecondTick, p.tick % 60 == 0); if p.onSecondTick { XCTAssertEqual(p.offsetMs!, -0.5, accuracy: 1e-6) } }
        // 文件不从第 0 拍起（推流落盘从某个关键帧起录）：--start-tick 把拍号对上
        let shifted = f.filter { $0.index >= 37 }.map { ProbeFrame(index: $0.index - 37, ptsSeconds: $0.ptsSeconds - 37.0 / 60, frameNumber: $0.frameNumber, inputID: $0.inputID, genTimeMs: $0.genTimeMs, flash: $0.flash, gray: $0.gray) }
        let shiftedClicks = clicks.map { ClickEvent(sampleIndex: $0.sampleIndex, timeSeconds: $0.timeSeconds - 37.0 / 60, peak: 1) }
        let wrong = FrameAnalysis.av(frames: shifted, clicks: shiftedClicks, frameDurationSeconds: 1.0 / 60)
        XCTAssertEqual(wrong.onSecond.count, 0, "不知道起始拍时整秒闪光一个都对不上")
        XCTAssertNil(wrong.passA2)
        let right = FrameAnalysis.av(frames: shifted, clicks: shiftedClicks, frameDurationSeconds: 1.0 / 60, startTick: 37)
        XCTAssertEqual(right.onSecond.count, 19); XCTAssertEqual(right.passA2, true)
        // 59.94 节目：整秒拍 = 拍号是 60 的倍数（1.001 k s），click 周期也是 1.001 s
        var g: [ProbeFrame] = []
        for tick in 0..<(20 * 60) { g.append(ProbeFrame(index: tick, ptsSeconds: Double(tick) * 1.001 / 60, frameNumber: UInt32(tick), inputID: 1, genTimeMs: 0, flash: tick % 60 == 0, gray: 128)) }
        let c5994 = (0..<20).map { ClickEvent(sampleIndex: 0, timeSeconds: Double($0) * 1.001, peak: 1) }
        let r5994 = FrameAnalysis.av(frames: g, clicks: c5994, frameDurationSeconds: 1.001 / 60)
        XCTAssertEqual(r5994.onSecond.count, 20); XCTAssertEqual(r5994.offSecondCount, 0); XCTAssertEqual(r5994.onSecond.maxAbsMs, 0, accuracy: 1e-9)
        XCTAssertNil(r5994.note)
    }

    /// A1 第三项的离线口径（prompt 44 交付 4，搬自 W2-E 的 DiscontinuityDetector.analyze）：相邻样本跳变 > 0.5 满幅、按已知 click 位置 ±1 ms 排除。
    func testA1_discontinuities_excludesKnownClicks() {
        // 合成信号：1 kHz −20 dBFS + 每秒 48 个样本的 +1.0 click（TestSignal），5 s
        let sig = TestSignal(t0: HostTime(nanoseconds: 1_000_000_000))
        var samples = [Float](repeating: 0, count: 5 * 48000)
        samples.withUnsafeMutableBufferPointer { sig.render(into: $0.baseAddress!, frameCount: $0.count, startingAt: 0) }
        let clicks = ClickDetector.detect(samples: samples, sampleRate: 48000)
        XCTAssertEqual(clicks.count, 5)
        let clean = FrameAnalysis.discontinuities(samples: samples, sampleRate: 48000, startSeconds: 0, clicks: clicks)
        XCTAssertEqual(clean.count, 0, "\(clean.events)")
        XCTAssertEqual(clean.jumpsAtClicks, 9, "5 个 click 各有进 / 出两次 > 0.5 的跳变（第 0 个样本上的 click 没有进），全在 click 位置")
        XCTAssertEqual(clean.passA1, true)
        // 人为插一个 0.6 满幅的跳变（1.5 s 起整段抬高 0.6 = 一次台阶）→ 1；口径同 W2-E 的 analyze：数的是"跳变"，单个样本的毛刺是进 / 出两次
        var broken = samples
        for i in 72_000..<broken.count { broken[i] += 0.6 }
        let r = FrameAnalysis.discontinuities(samples: broken, sampleRate: 48000, startSeconds: 0, clicks: clicks)
        XCTAssertEqual(r.count, 1, "\(r.events)")
        XCTAssertEqual(r.events.first?.sampleIndex, 72_000)
        XCTAssertEqual(r.events.first?.timeSeconds ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(r.events.first?.jump ?? 0, 0.6, accuracy: 0.05)
        XCTAssertEqual(r.passA1, false)
        // 0.45 不算；click 边沿前后 1 ms 内的跳变（AAC 解码后的台阶）不算；起点偏移进时间
        var small = samples
        small[100_000] += 0.45
        XCTAssertEqual(FrameAnalysis.discontinuities(samples: small, sampleRate: 48000, startSeconds: 0, clicks: clicks).count, 0)
        var edge = samples
        edge[48_000 - 30] = 0.8   // click 起点前 30 个样本（0.6 ms）：进 / 出两次都排除
        let e = FrameAnalysis.discontinuities(samples: edge, sampleRate: 48000, startSeconds: 0.25, clicks: clicks)
        XCTAssertEqual(e.count, 0)
        XCTAssertEqual(e.jumpsAtClicks, 11)
        var far = samples
        far[48_000 - 100] = 0.8   // 2 ms 前：进 / 出两次都算
        let fr = FrameAnalysis.discontinuities(samples: far, sampleRate: 48000, startSeconds: 0.25, clicks: clicks)
        XCTAssertEqual(fr.count, 2); XCTAssertEqual(fr.events.first?.timeSeconds ?? 0, 0.25 + Double(48_000 - 100) / 48000, accuracy: 1e-9)
        XCTAssertEqual(fr.events.map(\.sampleIndex), [48_000 - 100, 48_000 - 99])
    }

    func testA2_av_noClickWithinHalfSecondIsUnmatched() {
        let f = [ProbeFrame(index: 0, ptsSeconds: 10, frameNumber: 0, inputID: 1, genTimeMs: 0, flash: true, gray: 0)]
        let r = FrameAnalysis.av(frames: f, clicks: [ClickEvent(sampleIndex: 0, timeSeconds: 0, peak: 1)])
        XCTAssertEqual(r.matchedCount, 0); XCTAssertNil(r.passA2); XCTAssertNil(r.pairs[0].offsetMs)
    }

    // MARK: A4

    func testA4_avMulti_alignsEventsByGenTime() {
        func file(offsetSeconds: Double, genOffsetMs: UInt32 = 0) -> (name: String, frames: [ProbeFrame], clicks: [ClickEvent]) {
            var f: [ProbeFrame] = []
            for k in 0..<5 {
                f.append(ProbeFrame(index: 2 * k, ptsSeconds: Double(k) + offsetSeconds, frameNumber: UInt32(k), inputID: 1,
                                    genTimeMs: UInt32(k * 1000) + genOffsetMs, flash: true, gray: 128))
                f.append(ProbeFrame(index: 2 * k + 1, ptsSeconds: Double(k) + 0.5 + offsetSeconds, frameNumber: UInt32(k), inputID: 1,
                                    genTimeMs: UInt32(k * 1000 + 500), flash: false, gray: 128))
            }
            let clicks = (0..<5).map { ClickEvent(sampleIndex: 0, timeSeconds: Double($0) + offsetSeconds + 0.001, peak: 1) }
            return ("f\(offsetSeconds)", f, clicks)
        }
        // 三个文件的时间线原点不同（0 / +5 ms / −3 ms），同一事件的 genTimeMs 相同（±1 帧内）
        let r = FrameAnalysis.avMulti(files: [file(offsetSeconds: 0), file(offsetSeconds: 0.005, genOffsetMs: 3), file(offsetSeconds: -0.003)])
        XCTAssertEqual(r.events.count, 5)
        XCTAssertEqual(r.events[0].flashTimes.count, 3)
        XCTAssertEqual(r.maxFlashSpreadMs, 8, accuracy: 1e-6)
        XCTAssertEqual(r.maxClickSpreadMs, 8, accuracy: 1e-6)
        XCTAssertEqual(r.passA4, true)
        let far = FrameAnalysis.avMulti(files: [file(offsetSeconds: 0), file(offsetSeconds: 0.02)])
        XCTAssertEqual(far.passA4, false)
    }

    func testW1A_linearFit_and_nearest() {
        let fit = FrameAnalysis.linearFit(x: [0, 1, 2, 3], y: [1, 3, 5, 7])
        XCTAssertEqual(fit.slope, 2, accuracy: 1e-12); XCTAssertEqual(fit.intercept, 1, accuracy: 1e-12)
        XCTAssertEqual(FrameAnalysis.nearest([0, 1, 2, 3], to: 1.4), 1)
        XCTAssertEqual(FrameAnalysis.nearest([0, 1, 2, 3], to: 1.6), 2)
        XCTAssertEqual(FrameAnalysis.nearest([0, 1, 2, 3], to: 9), 3)
        XCTAssertEqual(FrameAnalysis.nearest([0, 1, 2, 3], to: -9), 0)
        XCTAssertNil(FrameAnalysis.nearest([], to: 0))
    }
}

extension FrameAnalysisTests {
    /// 节目输出里某路切走再切回来，中间那段不是它的丢帧；切回来后帧号从新段起算。
    func testV4_stats_offAirGapIsNotADrop() {
        var spec: [(Int?, UInt32?, Double, Bool)] = []
        for n in 0..<10 { spec.append((0, UInt32(n), 64, false)) }        // A 0–9
        for n in 5..<15 { spec.append((1, UInt32(n), 192, false)) }       // B 上 10 帧
        spec.append((nil, nil, 128, false))                                 // 一帧读不出 ID（混合）
        for n in 20..<30 { spec.append((0, UInt32(n), 64, false)) }       // A 回来：20 起，10–19 是它不在播时的帧
        let r = FrameAnalysis.stats(frames: frames(spec), programFps: 60, inputFps: [0: 60, 1: 60])
        let a = r.inputs[0]
        XCTAssertEqual(a.frames, 20); XCTAssertEqual(a.uniqueFrames, 20); XCTAssertEqual(a.droppedFrames, 0); XCTAssertTrue(a.dropGaps.isEmpty)
        XCTAssertEqual(a.passV4, true)
        XCTAssertEqual(r.unidentifiedFrames, 1)
        // 同一段里真丢的还是要报：A 的第二段里跳过 25
        var spec2 = spec
        spec2.removeAll { $0.0 == 0 && $0.1 == 25 }
        let r2 = FrameAnalysis.stats(frames: frames(spec2), programFps: 60)
        XCTAssertEqual(r2.inputs[0].droppedFrames, 1)
        XCTAssertEqual(r2.inputs[0].dropGaps.first?.from, 24)
    }
}
