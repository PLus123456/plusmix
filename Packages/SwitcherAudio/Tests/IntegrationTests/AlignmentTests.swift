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
        // W1-D2：年龄由混音器按目标就绪 = 目标 512 + P/2 128 + hf 47 + chunk/2 16 + P 256 = 959（确定值，不再带 [0, 256) 的相位）；
        // 对齐延迟线 = 2048 − 959 = 1089，也是确定的
        XCTAssertEqual(in1.targetAgeFrames, 959)
        XCTAssertEqual(in1.ageSetpointFrames, 959, accuracy: 1.0)
        XCTAssertEqual(in1.alignmentDelayFrames, 2048 - Int(in1.ageSetpointFrames.rounded()))
        XCTAssertEqual(in1.alignmentDelayFrames, 1089, accuracy: 1)
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
        // P = 1024：确定年龄 1280 + 512 + 63 + 1024 = 2879 超过对齐延迟，集成层把目标压到 2048（能对齐的最大值）；
        // 混音器等生产者相位转到"最新数据够新"的那一块再就绪，年龄正好 2048、延迟线 0（W2-E 时靠相位碰运气才有残差 0）
        XCTAssertEqual(a.targetAgeFrames, 959); XCTAssertEqual(b.targetAgeFrames, 2048)
        XCTAssertEqual(a.ageSetpointFrames, 959, accuracy: 1.0)
        XCTAssertEqual(b.ageSetpointFrames, 2048, accuracy: 1.0, "P = 1024 的年龄 = 对齐延迟")
        XCTAssertEqual(a.alignmentDelayFrames + Int(a.ageSetpointFrames.rounded()), 2048)
        XCTAssertEqual(b.alignmentDelayFrames + Int(b.ageSetpointFrames.rounded()), 2048)
        XCTAssertEqual(b.residualFrames, 0)
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
        // 目标年龄被压到 512，低于混音器的安全下限（703 + 相位），按下限就绪，残差报出来
        XCTAssertEqual(in1.targetAgeFrames, 512)
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

    // MARK: W1-D2 就绪年龄确定、耳机不走对齐

    /// 10 次重新注册（源相对块网格的相位各不同）：就绪年龄都 = 目标（959）± 1 帧，对齐延迟线都 = 1089，
    /// 残差（年龄 + 延迟线 − 对齐延迟）= 0；W2-E 时年龄带 [0, 256) 的随机相位，延迟线每次不同。
    func testAlignment_readyAgeIsDeterministic_10reprimes_residualZero() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        _ = try rig.capture(.master)
        await rig.run(seconds: 1)
        var ages: [Double] = [], delays: [Int] = []
        for k in 0..<10 {
            let phase = HostDuration(ticks: Int64((Double(k * 23) * rig.engine.mixer.hostTicksPerFrame).rounded()))
            try rig.addSource(number: 2, sourceT0: rig.driver.nextBlockHostTime + phase) { _, start, n, buf in
                for i in 0..<n { buf[i] = 0.3 * Float(sin(2 * Double.pi * 1500 * Double(start + Int64(i)) / 48_000)) }
            }
            await rig.run(blocks: 40)
            let st = try XCTUnwrap(rig.engine.status.inputs.first { $0.number == 2 })
            XCTAssertTrue(st.primed && st.aligned, "第 \(k) 次：\(st)")
            XCTAssertEqual(st.targetAgeFrames, 959)
            XCTAssertEqual(st.ageSetpointFrames, Double(st.targetAgeFrames), accuracy: 1.0, "第 \(k) 次就绪年龄")
            XCTAssertEqual(Int(st.ageSetpointFrames.rounded()) + st.alignmentDelayFrames - st.residualFrames, 2048, "第 \(k) 次残差")
            ages.append(st.ageSetpointFrames); delays.append(st.alignmentDelayFrames)
            rig.engine.unregisterInput(number: 2, now: rig.driver.nextBlockHostTime)
            await rig.run(blocks: 8)
            rig.sources.removeValue(forKey: 2)
            XCTAssertNil(rig.engine.slot(forInput: 2))
        }
        XCTAssertLessThanOrEqual(ages.max()! - ages.min()!, 1.0, "10 次就绪年龄极差 ≤ 1 帧：\(ages)")
        XCTAssertEqual(Set(delays).count, 1, "对齐延迟线每次相同：\(delays)")
        print("[age] 10 次重就绪年龄 \(ages.map { String(format: "%.2f", $0) })，延迟线 \(delays)")
        let st = rig.engine.status
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(st.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// 耳机总线默认取延迟线之前的信号：同一路 click 在耳机流里比 Master 早"对齐延迟线"那么多（1089 帧 = 22.7 ms），Master 仍回到整秒；
    /// `monitorPoint = .postDelayLine` 时耳机与 Master 同刻。监听延迟因此只剩环年龄（959 帧 = 20 ms，可用 hints 调小）+ 设备。
    func testMonitor_headphonesBypassAlignmentDelayLineByDefault() async throws {
        for point in [MonitorPoint.preDelayLine, .postDelayLine] {
            let rig = try await EngineRig(state: States.fourInputs(afv: false)) { $0.monitorPoint = point }
            try rig.addSource(number: 1)
            var s = InputSettings(); s.audio.routing = BusRouting(master: true, headphones: true)
            _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s))
            let master = try rig.capture(.master), hp = try rig.capture(.bus(.headphones))
            await rig.run(seconds: 5)
            let in1 = try XCTUnwrap(rig.engine.status.inputs.first { $0.number == 1 })
            XCTAssertEqual(in1.alignmentDelayFrames, 1089, accuracy: 1)
            let expectedHP = point == .preDelayLine ? Double(in1.alignmentDelayFrames) / 48 : 0     // 音频超前为正
            let mo = master.clickOffsetsMs(t0: rig.t0), ho = hp.clickOffsetsMs(t0: rig.t0)
            XCTAssertGreaterThanOrEqual(mo.count, 3); XCTAssertGreaterThanOrEqual(ho.count, 3)
            for o in mo { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "\(point) Master \(o)") }
            for o in ho { XCTAssertEqual(o.offsetMs, expectedHP, accuracy: 0.05, "\(point) 耳机 \(o)") }
            XCTAssertEqual(rig.engine.status.monitorPoint, point)
            await rig.shutdown()
        }
    }
}
