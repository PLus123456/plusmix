import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// A6 表的准确度（测试标准 §1 A6、§4：响度 ±0.1 LU，真峰值按 EBU Tech 3341 容差 +0.2 / −0.4 dB）。
/// 信号全部代码生成（EBU Tech 3341 v3 / Tech 3342 v3 的合成用例；节目素材用例 7、8 和 3342 的 5–8 需要文件，不在这里）。
/// 读数走混音器 Master 总线的表（立体声输入 → Master，增益 0 dB、声像居中 = 原样通过）。
final class MeterTests: XCTestCase {

    /// 分段电平的正弦（每段：dBFS 峰值、秒数），立体声两路相同。
    struct Segment { let dbfs: Double; let seconds: Double }

    /// 跑一段信号，返回 Master 的表读数与总线的表最大真峰值。
    func runThroughMaster(_ segments: [Segment], hz: Double = 1000, phaseDegrees: Double = 0,
                          channels: Int = 2) -> BusMeter {
        let rig = OfflineRig()
        var boundaries = [Int64]()   // 每段起始样本
        var acc: Int64 = 0
        for s in segments { boundaries.append(acc); acc += Int64((s.seconds * 48_000).rounded()) }
        let total = acc
        let amps = segments.map { pow(10, $0.dbfs / 20) }
        let phase = phaseDegrees * Double.pi / 180
        rig.addSource(slot: 0, channels: channels, generator: { _, start, n, buf in
            for i in 0..<n {
                let s = start + Int64(i)
                var seg = 0
                while seg + 1 < boundaries.count && s >= boundaries[seg + 1] { seg += 1 }
                let a = s < total ? amps[seg] : 0
                buf[i] = Float(a * sin(2 * Double.pi * hz * Double(s) / 48_000 + phase))
            }
        })
        // 就绪那一刻起，信号从"现在该到的样本"开始；先跑到信号结束（多跑 2 块吃掉环延迟）
        let blocks = Int(total / 256) + 2
        rig.run(blocks: blocks)
        return rig.mixer.meters[.master]
    }

    // MARK: EBU Tech 3341 —— 响度

    func testA6_3341_case1_minus23LUFS_MSI() {
        let m = runThroughMaster([Segment(dbfs: -23, seconds: 20)])
        XCTAssertEqual(m.momentaryLUFS, -23.0, accuracy: 0.1, "M")
        XCTAssertEqual(m.shortTermLUFS, -23.0, accuracy: 0.1, "S")
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 0.1, "I")
        print("[A6] 3341-1 M=\(m.momentaryLUFS) S=\(m.shortTermLUFS) I=\(m.integratedLUFS)")
    }

    func testA6_3341_case2_minus33LUFS_MSI() {
        let m = runThroughMaster([Segment(dbfs: -33, seconds: 20)])
        XCTAssertEqual(m.momentaryLUFS, -33.0, accuracy: 0.1, "M")
        XCTAssertEqual(m.shortTermLUFS, -33.0, accuracy: 0.1, "S")
        XCTAssertEqual(m.integratedLUFS, -33.0, accuracy: 0.1, "I")
        print("[A6] 3341-2 M=\(m.momentaryLUFS) S=\(m.shortTermLUFS) I=\(m.integratedLUFS)")
    }

    /// −36 (10 s) / −23 (60 s) / −36 (10 s)：相对门限把 −36 的段滤掉，I = −23.0。
    func testA6_3341_case3_integratedWithRelativeGate() {
        let m = runThroughMaster([Segment(dbfs: -36, seconds: 10), Segment(dbfs: -23, seconds: 60), Segment(dbfs: -36, seconds: 10)])
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 0.1, "I")
        print("[A6] 3341-3 I=\(m.integratedLUFS)")
    }

    /// −72 / −36 / −23 (60 s) / −36 / −72：绝对门限 + 相对门限，I = −23.0。
    func testA6_3341_case4_integratedWithAbsoluteAndRelativeGate() {
        let m = runThroughMaster([Segment(dbfs: -72, seconds: 10), Segment(dbfs: -36, seconds: 10), Segment(dbfs: -23, seconds: 60),
                                  Segment(dbfs: -36, seconds: 10), Segment(dbfs: -72, seconds: 10)])
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 0.1, "I")
        print("[A6] 3341-4 I=\(m.integratedLUFS)")
    }

    /// −26 (20 s) / −20 (20.1 s) / −26 (20 s)：能量平均，I = −23.0。
    func testA6_3341_case5_integratedEnergyAverage() {
        let m = runThroughMaster([Segment(dbfs: -26, seconds: 20), Segment(dbfs: -20, seconds: 20.1), Segment(dbfs: -26, seconds: 20)])
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 0.1, "I")
        print("[A6] 3341-5 I=\(m.integratedLUFS)")
    }

    /// 用例 6（5.1：L/R −28、C −24、LFE −30（不计）、Ls/Rs −30 dBFS → −23.0 LUFS）：总线是立体声，用同一算法的
    /// LoudnessMeter（离线分析用）验证多声道加权与环绕声道的 +1.5 dB。
    func testA6_3341_case6_surround51_viaLoudnessMeter() {
        let meter = LoudnessMeter(channelCount: 6)
        let levels: [Double] = [-28, -28, -24, -30, -30, -30]   // L R C LFE Ls Rs
        let n = 48_000 * 20
        let block = 4800
        var planes = [[Float]](repeating: [Float](repeating: 0, count: block), count: 6)
        var s = 0
        while s < n {
            for c in 0..<6 {
                let a = pow(10, levels[c] / 20)
                for i in 0..<block { planes[c][i] = Float(a * sin(2 * Double.pi * 1000 * Double(s + i) / 48_000)) }
            }
            meter.add(planes: planes)
            s += block
        }
        XCTAssertEqual(meter.integrated, -23.0, accuracy: 0.1)
        XCTAssertEqual(meter.momentary, -23.0, accuracy: 0.1)
        XCTAssertEqual(meter.shortTerm, -23.0, accuracy: 0.1)
        print("[A6] 3341-6 (5.1) I=\(meter.integrated) M=\(meter.momentary) S=\(meter.shortTerm)")
    }

    // MARK: EBU Tech 3341 —— 真峰值（容差 +0.2 / −0.4 dB）

    func checkTruePeak(dbtp: Double, phase: Double, file: StaticString = #filePath, line: UInt = #line) {
        let m = runThroughMaster([Segment(dbfs: dbtp, seconds: 20)], hz: 997, phaseDegrees: phase)
        let tp = 20 * log10(Double(m.truePeakMax.max()!))
        XCTAssertLessThanOrEqual(tp, dbtp + 0.2, "真峰值 \(dbtp) dBTP 相位 \(phase)° 读数 \(tp) 超上限", file: file, line: line)
        XCTAssertGreaterThanOrEqual(tp, dbtp - 0.4, "真峰值 \(dbtp) dBTP 相位 \(phase)° 读数 \(tp) 低于下限", file: file, line: line)
        let sp = 20 * log10(Double(m.peakMax.max()!))
        print("[A6] 真峰值 标称 \(dbtp) dBTP 相位 \(phase)°: 读数 \(String(format: "%.3f", tp)) dBTP（采样峰值 \(String(format: "%.3f", sp)) dBFS）")
    }

    func testA6_3341_truePeak_minus6dBTP_fourPhases() {
        for phase in [0.0, 45.0, 60.0, 67.5] { checkTruePeak(dbtp: -6.0, phase: phase) }
    }

    /// prompt 指定：+0.5 dBTP 的 997 Hz 正弦（float 里超过满幅），读数按 3341 容差。
    func testA6_3341_truePeak_plus0dot5dBTP() {
        checkTruePeak(dbtp: 0.5, phase: 0)
        checkTruePeak(dbtp: 0.5, phase: 45)
    }

    func testA6_3341_truePeak_0dBTP_and_minus0dot5dBTP() {
        checkTruePeak(dbtp: 0.0, phase: 0)
        checkTruePeak(dbtp: -0.5, phase: 60)
    }

    // MARK: EBU Tech 3342 —— LRA（容差 ±1 LU）

    func testA6_3342_case1_LRA10LU() {
        let m = runThroughMaster([Segment(dbfs: -20, seconds: 20), Segment(dbfs: -30, seconds: 20)])
        XCTAssertEqual(m.loudnessRangeLU, 10, accuracy: 1)
        print("[A6] 3342-1 LRA=\(m.loudnessRangeLU)")
    }
    func testA6_3342_case2_LRA5LU() {
        let m = runThroughMaster([Segment(dbfs: -20, seconds: 20), Segment(dbfs: -15, seconds: 20)])
        XCTAssertEqual(m.loudnessRangeLU, 5, accuracy: 1)
        print("[A6] 3342-2 LRA=\(m.loudnessRangeLU)")
    }
    func testA6_3342_case3_LRA20LU() {
        let m = runThroughMaster([Segment(dbfs: -40, seconds: 20), Segment(dbfs: -20, seconds: 20)])
        XCTAssertEqual(m.loudnessRangeLU, 20, accuracy: 1)
        print("[A6] 3342-3 LRA=\(m.loudnessRangeLU)")
    }
    func testA6_3342_case4_LRA15LU() {
        let m = runThroughMaster([Segment(dbfs: -50, seconds: 20), Segment(dbfs: -35, seconds: 60), Segment(dbfs: -20, seconds: 60),
                                  Segment(dbfs: -35, seconds: 60), Segment(dbfs: -50, seconds: 20)])
        XCTAssertEqual(m.loudnessRangeLU, 15, accuracy: 1)
        print("[A6] 3342-4 LRA=\(m.loudnessRangeLU)")
    }

    // MARK: 表的其他约定

    /// 采样峰值 = 本块 |x| 最大；峰值保持 = 自复位以来最大；输入表是推子后的。
    /// 用 bypass 重采样（单样本脉冲经 sinc 会被限带，峰值只剩中心抽头 ≈ 0.93）。
    func testMeter_peakAndHoldAndInputMeter() {
        let rig = OfflineRig()
        rig.addSource(slot: 0, resampling: .bypass, generator: { _, start, n, buf in
            for i in 0..<n { buf[i] = (start + Int64(i)) == 30_000 ? 0.8 : 0.1 }
        })
        rig.mixer.setPan(slot: 0, -1)
        rig.mixer.setGain(slot: 0, dB: -6)
        rig.run(blocks: 60)           // 就绪 + 增益 / 声像平滑到位（声像每块走 30%，到 1e-4 要 ~30 块；脉冲在第 ~117 块）
        rig.mixer.resetMeters()       // 清掉平滑过程中的保持值
        rig.run(blocks: 140)
        let m = rig.mixer.meters
        XCTAssertEqual(Double(m[.master].peakMax[0]), 0.8 * pow(10, -6.0 / 20), accuracy: 1e-3)
        XCTAssertEqual(Double(m[.master].peak[0]), 0.1 * pow(10, -6.0 / 20), accuracy: 1e-3, "本块峰值")
        XCTAssertEqual(Double(m.inputs[0].peakMax[0]), 0.8 * pow(10, -6.0 / 20), accuracy: 1e-3, "输入表推子后")
        XCTAssertEqual(Double(m[.master].peakMax[1]), 0, accuracy: 1e-6, "右声道无信号")
        rig.mixer.resetMeters()
        rig.run(blocks: 2)
        XCTAssertEqual(Double(rig.mixer.meters[.master].peakMax[0]), 0.1 * pow(10, -6.0 / 20), accuracy: 1e-3, "复位后重新保持")
    }
}
