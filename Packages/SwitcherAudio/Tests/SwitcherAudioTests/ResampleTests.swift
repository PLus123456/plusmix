import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// 重采样对齐（prompt 测试第 3 条）：输入 48000 × (1 ± 100 ppm) 各跑 5 分钟，无欠载无溢出，环占用稳定在设定点 ±1 块；
/// 估计器收敛时间打印进日志（写进报告）。
final class ResampleTests: XCTestCase {

    struct RunResult {
        var underruns: UInt64 = 0
        var overruns: UInt64 = 0
        var reprimes: UInt64 = 0
        var finalRatio = 0.0
        var convergenceSeconds = 0.0
        var occMin = Int.max, occMax = 0
        var occMean = 0.0
        var ageMin = Double.infinity, ageMax = -Double.infinity
        var ratioMin = 2.0, ratioMax = 0.0
        var rmsMin = 1.0, rmsMax = 0.0
    }

    /// 跑 seconds 秒，收敛评估从 settleSeconds 起。
    func run(driftPpm: Double, seconds: Double, settleSeconds: Double, producerBlock: Int = 256, targetFrames: Int = 0) -> RunResult {
        let rig = OfflineRig()
        rig.addSource(slot: 0, driftPpm: driftPpm, producerBlock: producerBlock, targetFrames: targetFrames)
        rig.mixer.setPan(slot: 0, -1)
        let blocks = Int(seconds * 48_000 / 256)
        let target = targetFrames > 0 ? targetFrames : 512
        var res = RunResult()
        var ratios = [Double]()        // 每秒一个
        var occSum = 0.0, occN = 0.0
        var blockRms = 0.0
        var secRms = [Double]()
        rig.run(blocks: blocks) { b in
            let st = rig.mixer.stats.inputs[0]
            let t = Double(b.index + 1) * 256 / 48_000
            if b.index % 187 == 0 { ratios.append(st.ratio) }
            let l = b.bus(.master).left
            var e = 0.0
            for v in l { e += Double(v) * Double(v) }
            blockRms += e
            if b.index % 187 == 186 { secRms.append((blockRms / (187 * 256)).squareRoot()); blockRms = 0 }
            if t >= settleSeconds {
                let occ = Int(st.occupancyFrames)
                res.occMin = min(res.occMin, occ); res.occMax = max(res.occMax, occ)
                occSum += Double(occ); occN += 1
                res.ageMin = min(res.ageMin, st.ageFrames); res.ageMax = max(res.ageMax, st.ageFrames)
                res.ratioMin = min(res.ratioMin, st.ratio); res.ratioMax = max(res.ratioMax, st.ratio)
            }
        }
        let st = rig.mixer.stats.inputs[0]
        res.underruns = st.underrunBlocks
        res.overruns = rig.sources[0]!.ring.stats.overruns
        res.reprimes = st.reprimes
        res.finalRatio = st.ratio
        res.occMean = occSum / max(occN, 1)
        // 收敛：最后一次 |ratio − final| > 5 ppm 的时刻之后
        var conv = 0.0
        for (i, r) in ratios.enumerated() where abs(r - res.finalRatio) > 5e-6 { conv = Double(i + 1) * 187 * 256 / 48_000 }
        res.convergenceSeconds = conv
        let body = secRms.dropFirst(2)
        res.rmsMin = body.min() ?? 0; res.rmsMax = body.max() ?? 0
        print("[resample] drift=\(driftPpm) ppm target=\(target): underruns=\(res.underruns) overruns=\(res.overruns) reprimes=\(res.reprimes) " +
              "ratio final=\(String(format: "%.7f", res.finalRatio)) (期望 \(String(format: "%.7f", 1 / (1 + driftPpm / 1e6)))) " +
              "range[\(String(format: "%.7f", res.ratioMin)), \(String(format: "%.7f", res.ratioMax))] 收敛 \(res.convergenceSeconds) s; " +
              "占用 min/mean/max = \(res.occMin)/\(String(format: "%.1f", res.occMean))/\(res.occMax) 帧, 年龄 [\(String(format: "%.1f", res.ageMin)), \(String(format: "%.1f", res.ageMax))] " +
              "设定点 \(String(format: "%.1f", st.ageSetpoint)); 每秒 RMS [\(String(format: "%.5f", res.rmsMin)), \(String(format: "%.5f", res.rmsMax))]")
        return res
    }

    func check(_ r: RunResult, driftPpm: Double, target: Int = 512) {
        XCTAssertEqual(r.underruns, 0, "无欠载")
        XCTAssertEqual(r.overruns, 0, "无溢出")
        XCTAssertEqual(r.reprimes, 1, "只就绪一次（没有掉出再填）")
        XCTAssertEqual(r.finalRatio, 1 / (1 + driftPpm / 1e6), accuracy: 5e-6, "比率收敛到 1/(1+drift) ±5 ppm")
        XCTAssertGreaterThanOrEqual(r.occMin, target - 256, "占用不低于设定点 − 1 块")
        XCTAssertLessThanOrEqual(r.occMax, target + 256, "占用不高于设定点 + 1 块")
        XCTAssertLessThan(r.ratioMax - r.ratioMin, 20e-6, "收敛后比率抖动 < 20 ppm")
        // 输出连续（每秒 RMS 恒定：−20 dBFS 正弦 + click，居中 −3 dB）
        XCTAssertEqual(r.rmsMax / max(r.rmsMin, 1e-9), 1.0, accuracy: 0.02, "输出电平全程稳定")
    }

    func testResample_plus100ppm_5min_ringStaysAtSetpoint() {
        let secs = T.seconds("SW_AUDIO_RESAMPLE_SECONDS", default: 300)
        let r = run(driftPpm: 100, seconds: secs, settleSeconds: min(90, secs / 3))
        check(r, driftPpm: 100)
    }

    func testResample_minus100ppm_5min_ringStaysAtSetpoint() {
        let secs = T.seconds("SW_AUDIO_RESAMPLE_SECONDS", default: 300)
        let r = run(driftPpm: -100, seconds: secs, settleSeconds: min(90, secs / 3))
        check(r, driftPpm: -100)
    }

    /// 生产者块 480（某些设备 10 ms 一块）与 1024：设定点跟着生产者块走，仍无欠载。
    func testResample_otherProducerBlockSizes() {
        for pb in [128, 480, 1024] {
            let r = run(driftPpm: 60, seconds: 60, settleSeconds: 30, producerBlock: pb, targetFrames: pb <= 512 ? 0 : 2048)
            XCTAssertEqual(r.underruns, 0, "生产者块 \(pb) 无欠载")
            XCTAssertEqual(r.overruns, 0, "生产者块 \(pb) 无溢出")
            XCTAssertEqual(r.finalRatio, 1 / (1 + 60e-6), accuracy: 10e-6, "生产者块 \(pb) 比率")
        }
    }

    /// 无漂移时比率停在 1.0 ± 2 ppm，占用不漂。
    func testResample_zeroDriftRatioStaysAtUnity() {
        let r = run(driftPpm: 0, seconds: 60, settleSeconds: 30)
        check(r, driftPpm: 0)
        XCTAssertEqual(r.finalRatio, 1.0, accuracy: 2e-6)
    }

    /// 源停 2 s 再回来：回到未就绪、静音输出，之后重新就绪，不欠载爆音。
    func testResample_sourceStallRecovers() {
        let rig = OfflineRig()
        let src = rig.addSource(slot: 0)
        rig.mixer.setPan(slot: 0, -1)
        rig.run(blocks: 1000)
        XCTAssertTrue(rig.mixer.stats.inputs[0].primed)
        // 停：不喂 2 s（375 块）
        rig.driver.run(blocks: 375)
        let st1 = rig.mixer.stats.inputs[0]
        XCTAssertFalse(st1.primed, "源停 1 s 后应回到未就绪")
        XCTAssertLessThanOrEqual(st1.underrunBlocks, 200, "停摆前最多欠载约 190 块（1 s 判定窗）就不再计")
        // 回来：源从"现在"继续（跳过停摆期间的样本，像设备重连）
        var silentBlocks = 0
        rig.run(blocks: 1) { b in if T.peak(Array(b.bus(.master).left)) == 0 { silentBlocks += 1 } }
        _ = src
        rig.run(blocks: 2000)
        let st2 = rig.mixer.stats.inputs[0]
        XCTAssertTrue(st2.primed, "源回来后重新就绪")
        XCTAssertEqual(st2.reprimes, 2)
        let out = rig.collect(blocks: 50, bus: .master)
        XCTAssertGreaterThan(T.db(T.rms(out.left)), -30, "恢复后有声")
    }
}
