import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// A2 的机理层：合成源 click 在 host 整秒（= 闪光拍点）；经混音器（环年龄 + 对齐延迟）到 Master 消费者流后，
/// 按"块 PTS = 块首 host time − 对齐延迟"的时间轴，click 必须回到整秒。这里量的是引擎内部的偏移；文件级的 A2（录制 + frameprobe）见报告。
final class AlignmentTests: XCTestCase {

    func testA2_offline_clickInMasterLandsOnSourceTime_afterAlignment() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let cap = try rig.capture(.master)
        await rig.run(seconds: 6)
        let st = rig.engine.status
        let in1 = try XCTUnwrap(st.inputs.first { $0.number == 1 })
        XCTAssertTrue(in1.primed && in1.aligned, "\(in1)")
        // 年龄 = 目标 512 + P/2 128 + hf 47 + chunk/2 16 + 相位 [0, 256)
        XCTAssertGreaterThanOrEqual(in1.ageSetpointFrames, 700)
        XCTAssertLessThan(in1.ageSetpointFrames, 960)
        XCTAssertEqual(in1.alignmentDelayFrames, 2048 - Int(in1.ageSetpointFrames.rounded()))
        XCTAssertEqual(in1.residualFrames, 0)
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        XCTAssertGreaterThanOrEqual(offsets.count, 4, "\(offsets)")
        for o in offsets {
            XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "第 \(o.second) 秒的 click 偏 \(o.offsetMs) ms（≤ 1 样本 0.021 ms 算对齐）")
        }
        XCTAssertEqual(cap.gaps.count, 0, "PTS 按块连续")
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(st.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// 生产者块不同（256 / 1024）的两路：年龄不同，对齐延迟不同，click 都回到整秒；PTS 与用哪一路无关。
    func testA2_offline_differentProducerBlocks_bothAlignToTheSameTimeline() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        // 输入 1：P = 256 只送 A 总线；输入 2：P = 1024 只送 B 总线；Master 同时收两路
        try rig.addSource(number: 1, producerBlock: 256)
        try rig.addSource(number: 2, producerBlock: 1024)
        var s1 = InputSettings(); s1.audio.routing = BusRouting(master: true, busA: true)
        var s2 = InputSettings(); s2.audio.routing = BusRouting(master: true, busB: true)
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s1))
        _ = await rig.sm.apply(.setInputSettings(input: 2, settings: s2))
        let capA = try rig.capture(.bus(.busA))
        let capB = try rig.capture(.bus(.busB))
        await rig.run(seconds: 6)
        let st = rig.engine.status
        let a = try XCTUnwrap(st.inputs.first { $0.number == 1 }), b = try XCTUnwrap(st.inputs.first { $0.number == 2 })
        XCTAssertTrue(a.aligned && b.aligned)
        XCTAssertGreaterThan(b.ageSetpointFrames, a.ageSetpointFrames + 300, "P = 1024 的年龄多出 P/2 + 目标差")
        XCTAssertEqual(a.alignmentDelayFrames + Int(a.ageSetpointFrames.rounded()), 2048)
        XCTAssertEqual(b.alignmentDelayFrames + Int(b.ageSetpointFrames.rounded()), 2048)
        for cap in [capA, capB] {
            let offsets = cap.clickOffsetsMs(t0: rig.t0)
            XCTAssertGreaterThanOrEqual(offsets.count, 3)
            for o in offsets { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "\(o)") }
        }
        await rig.shutdown()
    }

    /// 源时钟 +100 ppm：估计器把年龄钉在设定点，对齐不随时间漂（60 s）。
    func testA3_offline_driftingSource_plus100ppm_staysAligned() async throws {
        let seconds = IT.seconds("SW_AUDIO_A3_SECONDS", default: 60)
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, driftPpm: 100)
        let cap = try rig.capture(.master)
        await rig.run(seconds: seconds)
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        XCTAssertGreaterThanOrEqual(Double(offsets.count), seconds - 2)
        // 前 10 s 估计器还在收敛（W1-D：±100 ppm 10 s 收敛到 ±5 ppm），之后 ≤ 0.1 ms
        let settled = offsets.filter { $0.second > 12 }
        let maxAbs = settled.map { abs($0.offsetMs) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxAbs, 0.1, "稳态最大偏差 \(maxAbs) ms：\(settled.suffix(5))")
        let xs = settled.map { Double($0.second) }, ys = settled.map(\.offsetMs)
        let n = Double(xs.count); let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<xs.count { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
        let slope = sxx > 0 ? sxy / sxx : 0
        // 60 s 的拟合分辨不了 1 ms / 8 h（click 定位 ±1 样本的噪声给斜率的 σ ≈ 3.6 ms / 8 h）；这里按 A3 阈值判，长跑见报告
        XCTAssertLessThanOrEqual(abs(slope * 8 * 3600), 16, "斜率换算 8 小时 \(slope * 8 * 3600) ms")
        let in1 = try XCTUnwrap(rig.engine.status.inputs.first { $0.number == 1 })
        XCTAssertEqual(in1.ratioPpm, -100, accuracy: 5)
        await rig.shutdown()
    }

    /// 用户延迟补偿叠在对齐延迟之上：100 ms → click 晚 100 ms，PTS 不变。
    func testAlignment_userDelayCompensationAddsOnTop_ptsUnchanged() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        var s = InputSettings(); s.audio.delayMs = 100
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s))
        let cap = try rig.capture(.master)
        await rig.run(seconds: 5)
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        XCTAssertGreaterThanOrEqual(offsets.count, 3)
        for o in offsets { XCTAssertEqual(o.offsetMs, -100, accuracy: 0.05, "\(o)") }
        let in1 = try XCTUnwrap(rig.engine.status.inputs.first { $0.number == 1 })
        XCTAssertEqual(in1.userDelayMs, 100)
        XCTAssertEqual(rig.engine.programPTS(forBlockHostTime: rig.t0), rig.t0 - rig.engine.alignmentDuration)
        await rig.shutdown()
    }

    /// 对齐延迟设得比年龄小（512 帧）：补不齐，residual 报出来，click 晚 residual。
    func testAlignment_residualWhenAgeExceedsAlignment() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false)) { $0.alignmentFrames = 512 }
        try rig.addSource(number: 1)
        let cap = try rig.capture(.master)
        await rig.run(seconds: 5)
        let in1 = try XCTUnwrap(rig.engine.status.inputs.first { $0.number == 1 })
        XCTAssertEqual(in1.alignmentDelayFrames, 0)
        XCTAssertGreaterThan(in1.residualFrames, 150)
        let expectedMs = -Double(in1.residualFrames) / 48
        for o in cap.clickOffsetsMs(t0: rig.t0) { XCTAssertEqual(o.offsetMs, expectedMs, accuracy: 0.05, "\(o)") }
        await rig.shutdown()
    }

    /// 输入在对齐之前是静音的；就绪 + 对齐后才放音，且第一声不是硬起（增益 3 ms 平滑）。
    func testAlignment_inputIsMutedUntilAligned() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        // 纯正弦，没有 click，便于看电平
        try rig.addSource(number: 1) { _, start, n, buf in
            for i in 0..<n { buf[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(start + Int64(i)) / 48_000)) }
        }
        var blockPeaks: [Float] = []
        rig.afterBlock = { b in blockPeaks.append(b.bus(.master).left.reduce(0) { max($0, abs($1)) }) }
        await rig.run(seconds: 1)
        // 前几块静音（环在填），随后从 0 平滑上来，最后稳定在 0.5 × 0.707
        XCTAssertEqual(blockPeaks[0], 0)
        let firstAudible = try XCTUnwrap(blockPeaks.firstIndex { $0 > 0.001 })
        XCTAssertGreaterThanOrEqual(firstAudible, 2, "至少要等到环填满就绪：\(blockPeaks.prefix(8))")
        XCTAssertLessThan(blockPeaks[firstAudible], 0.35, "第一块不是满电平硬起（3 ms 平滑）：\(blockPeaks[firstAudible])")
        XCTAssertEqual(Double(blockPeaks.last!), 0.5 / sqrt(2), accuracy: 0.01)
        await rig.shutdown()
    }
}
