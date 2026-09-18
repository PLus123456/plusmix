import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// W1-D2（prompt 46）：混音器收口 —— 淡变收帧数并精确收尾、就绪年龄可指定、耳机取延迟线前 / 后、输入 tap 的"推子后 AFV 前"来源。
/// 全部离线驱动（确定时序）；每个用例对应 W2-E 退回单 3-1…3-5 的一条。
final class MixerTapAndAgeTests: XCTestCase {
    let tpf = 1e9 / 48_000

    /// 两路直流 1.0：A 全左、B 全右（左右声道各看一路），B 的 AFV 先关；跑到就绪、增益平滑到位。
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

    /// 起点 = 第 (当前 + 5) 块的第 100 个样本。
    func fadeStart(_ rig: OfflineRig, sampleInBlock: Int = 100) -> (start: HostTime, block: Int) {
        let block = rig.driver.blockIndex + 5
        let t = HostTime(ticks: rig.driver.hostTime(ofBlock: block).ticks + UInt64((Double(sampleInBlock) * tpf).rounded()))
        return (t, block)
    }

    // MARK: 3-1 / 3-2 淡变收帧数、终点精确、终值不被覆盖

    /// 时长 24000 帧（500 ms，= 93.75 块，不是块的整数倍）：曲线到最后一个样本都按 cos / sin；从 s0 + dur 起 from 严格 0、to 满，
    /// 包括终点所在块剩下的样本和之后的块（旧实现：整块量化 + 终值被最后一个曲线样本覆盖后再 3 ms 平滑到 0）。
    func testAFV_crossfadeDurationInFrames_endsOnTheExactFrame_finalGainsNotOverwritten() {
        let rig = makeDCPair()
        let (start, startBlock) = fadeStart(rig)
        let dur = 24_000
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: dur, startHostTime: start)
        var l = [Float](), r = [Float]()
        let base = rig.driver.blockIndex
        rig.run(blocks: 120) { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        let s0 = (startBlock - base) * 256 + 100
        // 起点前一个样本不动（直流经 sinc 的增益 1 − 1.2e-7）
        XCTAssertEqual(Double(l[s0 - 1]), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Double(r[s0 - 1]), 0.0, accuracy: 1e-6)
        // 曲线：s0 + k 处 = cos / sin(π/2 · k / dur)，一直判到最后一个样本（k = dur − 1，from 增益 6.5e-5 = −84 dB）
        for k in [64, 640, 2048, 12_000, 20_000, 23_000, 23_900, 23_990, 23_999] {
            let e = Double.pi / 2 * Double(k) / Double(dur)
            XCTAssertEqual(Double(l[s0 + k]), cos(e), accuracy: 2e-6, "from s0+\(k)")
            XCTAssertEqual(Double(r[s0 + k]), sin(e), accuracy: 2e-6, "to s0+\(k)")
        }
        // 终点：s0 + dur 起严格 0 / 满，连续查 3000 个样本（终点块剩下的 156 个 + 后面 11 块）
        for i in (s0 + dur)..<(s0 + dur + 3000) {
            XCTAssertEqual(l[i], 0, "from 在 s0+dur+\(i - s0 - dur) 应严格为 0")
            XCTAssertEqual(Double(r[i]), 1.0, accuracy: 2e-7, "to 在 s0+dur+\(i - s0 - dur) 应满")
        }
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// Cut = 1 块短淡（256 帧）从块中间起：跨两块；第二块里淡完之后的样本与之后所有块 from 路严格 0（旧实现留 −44 dB、τ 3 ms 的尾巴）。
    func testAFV_cutFadeOfOneBlock_fromPathIsExactlyZeroAfterTheFade() {
        let rig = makeDCPair()
        let (start, startBlock) = fadeStart(rig, sampleInBlock: 100)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 256, startHostTime: start)
        var l = [Float](), r = [Float]()
        let base = rig.driver.blockIndex
        rig.run(blocks: 20) { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        let s0 = (startBlock - base) * 256 + 100
        XCTAssertEqual(Double(l[s0 + 128]), cos(Double.pi / 4), accuracy: 2e-6, "中点 −3 dB")
        for i in (s0 + 256)..<l.count {
            XCTAssertEqual(l[i], 0, "样本 \(i)（终点后 \(i - s0 - 256)）from 应严格 0")
            XCTAssertEqual(Double(r[i]), 1.0, accuracy: 2e-7)
        }
        // 整块口径：终点所在块（第 startBlock + 1 块）之后的每一块 RMS 都严格 0
        let endBlock = (s0 + 256 - 1) / 256
        for b in (endBlock + 1)..<(l.count / 256) {
            let blk = l[(b * 256)..<((b + 1) * 256)]
            XCTAssertEqual(blk.reduce(0) { $0 + abs($1) }, 0, "第 \(b) 块")
        }
    }

    /// 时长 < 1 帧钳到 1 帧；`durationBlocks:` 只是 块 × blockFrames 的便利写法，与帧数版本逐样本一致。
    func testAFV_durationBlocksIsBlocksTimesBlockFrames() {
        var outFrames = [Float](), outBlocks = [Float]()
        for useBlocks in [false, true] {
            let rig = makeDCPair()
            let (start, _) = fadeStart(rig)
            if useBlocks { rig.mixer.crossfade(from: 0, to: 1, durationBlocks: 40, startHostTime: start) }
            else { rig.mixer.crossfade(from: 0, to: 1, durationFrames: 40 * 256, startHostTime: start) }
            var l = [Float]()
            rig.run(blocks: 60) { b in l.append(contentsOf: b.bus(.master).left) }
            if useBlocks { outBlocks = l } else { outFrames = l }
        }
        XCTAssertEqual(outFrames, outBlocks)
    }

    // MARK: 3-3 就绪年龄可指定

    /// 目标年龄 1200 帧：源相对块网格的相位取 10 种（0…225 帧），就绪年龄都 = 1200 ± 1 帧；不指定时（旧规则）年龄随相位散开 ≈ 一个生产者块。
    func testAlignment_targetAge_readyAgeEqualsTargetAcrossTenPhases() {
        let target = 1200
        var withTarget = [Double](), legacy = [Double]()
        for k in 0..<10 {
            let phase = HostDuration(ticks: Int64((Double(k * 25) * tpf).rounded()))
            for useTarget in [true, false] {
                let rig = OfflineRig()
                rig.addSource(slot: 0, targetAgeFrames: useTarget ? target : 0, sourceT0: rig.t0 + phase)
                rig.run(blocks: 60)
                let st = rig.mixer.stats.inputs[0]
                XCTAssertTrue(st.primed, "相位 \(k * 25) 帧应已就绪")
                XCTAssertEqual(st.reprimes, 1)
                XCTAssertEqual(st.underrunBlocks, 0)
                if useTarget { withTarget.append(st.ageSetpoint) } else { legacy.append(st.ageSetpoint) }
            }
        }
        for a in withTarget { XCTAssertEqual(a, Double(target), accuracy: 1.0, "指定目标年龄：\(withTarget)") }
        let spread = legacy.max()! - legacy.min()!
        print("[age] 目标 \(target)：10 种相位的就绪年龄 \(withTarget.map { String(format: "%.2f", $0) })；不指定时 \(legacy.map { String(format: "%.1f", $0) })（极差 \(String(format: "%.1f", spread))）")
        XCTAssertGreaterThan(spread, 100, "旧规则的年龄应随相位散开（否则对照无意义）")
    }

    /// 目标年龄小于安全下限（旧规则的 back + 生产者块）时按下限就绪（年龄 ≥ 目标），不欠载；`deterministicAgeFrames` 给的就是这个下限。
    func testAlignment_targetAge_belowSafeMinimumIsClampedWithoutUnderrun() {
        let rig = OfflineRig()
        let minAge = rig.mixer.deterministicAgeFrames(targetFrames: 0, producerBlockFrames: 256, resampled: true)
        XCTAssertEqual(minAge, 512 + 128 + 47 + 16 + 256, "target 2 块 + P/2 + hf + chunk/2 + P")
        rig.addSource(slot: 0, targetAgeFrames: 300, sourceT0: rig.t0 + HostDuration(ticks: Int64((100 * tpf).rounded())))
        rig.run(blocks: 2000)
        let st = rig.mixer.stats.inputs[0]
        XCTAssertTrue(st.primed)
        XCTAssertEqual(st.underrunBlocks, 0)
        XCTAssertEqual(st.reprimes, 1)
        XCTAssertGreaterThanOrEqual(st.ageSetpoint, 300)
        XCTAssertLessThanOrEqual(st.ageSetpoint, Double(minAge) + 1)
        // 目标 = 下限：精确命中
        let rig2 = OfflineRig()
        rig2.addSource(slot: 0, targetAgeFrames: minAge, sourceT0: rig2.t0 + HostDuration(ticks: Int64((100 * tpf).rounded())))
        rig2.run(blocks: 2000)
        XCTAssertEqual(rig2.mixer.stats.inputs[0].ageSetpoint, Double(minAge), accuracy: 1.0)
        XCTAssertEqual(rig2.mixer.stats.inputs[0].underrunBlocks, 0)
    }

    /// 源停 2 s 再回来（环里先是旧数据、再一次涌入停摆期间的块、再是当前数据）：重新就绪时年龄仍 = 目标 ± 1 帧，之后不欠载、有声。
    /// 指定目标年龄时不许拿陈旧数据凑数：等当前数据攒够再就绪；环被陈旧数据填满时先腾位置（否则生产者写不进、永远就绪不了）。
    func testAlignment_targetAge_reprimeAfterStallReturnsToTarget() {
        let target = 1200
        let rig = OfflineRig()
        let src = rig.addSource(slot: 0, targetAgeFrames: target)
        rig.mixer.setPan(slot: 0, -1)
        rig.run(blocks: 1000)
        XCTAssertEqual(rig.mixer.stats.inputs[0].ageSetpoint, Double(target), accuracy: 1.0)
        var reprimes: UInt64 = 1
        for round in 1...3 {
            rig.driver.run(blocks: 375)           // 停 2 s
            XCTAssertFalse(rig.mixer.stats.inputs[0].primed, "第 \(round) 轮停摆后应回到未就绪")
            let before = rig.mixer.stats.inputs[0]
            rig.run(blocks: 1500)                 // 回来：先涌入 375 块（环装不下的丢掉），之后按时交付
            let st = rig.mixer.stats.inputs[0]
            reprimes += 1
            XCTAssertTrue(st.primed, "第 \(round) 轮回来后应重新就绪")
            XCTAssertEqual(st.reprimes, reprimes)
            XCTAssertEqual(st.ageSetpoint, Double(target), accuracy: 1.0, "第 \(round) 轮重新就绪的年龄")
            XCTAssertEqual(st.underrunBlocks, before.underrunBlocks, "重新就绪后不欠载")
            let out = rig.collect(blocks: 50, bus: .master)
            XCTAssertGreaterThan(T.db(T.rms(out.left)), -30, "恢复后有声")
        }
        XCTAssertGreaterThan(src.ring.stats.overruns, 0, "涌入的块装不下会被丢（生产者侧计数）")
    }

    // MARK: 3-4 耳机取延迟线前 / 后

    /// 延迟补偿 100 ms 的输入路由到 Master + 耳机：默认耳机取延迟线前（click 比 Master 早 4800 样本）；
    /// `setMonitorPoint(.postDelayLine)` 后与 Master 同刻。独听 PFL / AFL 同样遵守。
    func testMonitor_headphonesTakePreDelayLineSignalByDefault_postDelayLineWhenSelected() {
        func clickPositions(point: MonitorPoint?, solo: Bool, mode: MonitorMode) -> (master: Int, headphones: Int) {
            let rig = OfflineRig()
            rig.addSource(slot: 0, resampling: .locked, generator: { _, start, n, buf in
                for i in 0..<n { let s = start + Int64(i); buf[i] = (s >= 20_000 && s < 20_048) ? 1 : 0 }
            })
            rig.mixer.setPan(slot: 0, -1)
            rig.mixer.setRouting(slot: 0, BusRouting(master: true, headphones: true))
            rig.mixer.setDelay(slot: 0, milliseconds: 100)
            rig.mixer.setSolo(slot: 0, solo)
            rig.mixer.setMonitorMode(mode)
            if let p = point { rig.mixer.setMonitorPoint(p) }
            var m = [Float](), h = [Float]()
            rig.run(blocks: 400) { b in m.append(contentsOf: b.bus(.master).left); h.append(contentsOf: b.bus(.headphones).left) }
            return (m.firstIndex { $0 > 0.5 } ?? -1, h.firstIndex { $0 > 0.5 } ?? -1)
        }
        let d = clickPositions(point: nil, solo: false, mode: .afl)
        XCTAssertGreaterThan(d.headphones, 0)
        XCTAssertEqual(d.master - d.headphones, 4800, "默认：耳机不经延迟线，比 Master 早 100 ms")
        let post = clickPositions(point: .postDelayLine, solo: false, mode: .afl)
        XCTAssertEqual(post.master - post.headphones, 0, "延迟线后：与 Master 同刻")
        XCTAssertEqual(post.master, d.master, "Master 不受监听点影响")
        for mode in [MonitorMode.afl, .pfl] {
            let s = clickPositions(point: .preDelayLine, solo: true, mode: mode)
            XCTAssertEqual(s.master - s.headphones, 4800, "独听 \(mode) 延迟线前")
            let s2 = clickPositions(point: .postDelayLine, solo: true, mode: mode)
            XCTAssertEqual(s2.master - s2.headphones, 0, "独听 \(mode) 延迟线后")
        }
    }

    /// 监听点不改电平：AFL 推子后（含增益 / AFV / 声像）、PFL 推子前，与路由矩阵用例同一组期望值。
    func testMonitor_monitorPointDoesNotChangeLevels() {
        for point in [MonitorPoint.preDelayLine, .postDelayLine] {
            for mode in [MonitorMode.afl, .pfl] {
                let rig = OfflineRig()
                rig.addSource(slot: 0, generator: { _, start, n, buf in
                    for i in 0..<n { buf[i] = 0.1 * Float(sin(2 * Double.pi * 1000 * Double(start + Int64(i)) / 48_000)) }
                })
                rig.mixer.setRouting(slot: 0, BusRouting(master: true, headphones: true))
                rig.mixer.setGain(slot: 0, dB: -6)
                rig.mixer.setSolo(slot: 0, true)
                rig.mixer.setMonitorMode(mode)
                rig.mixer.setMonitorPoint(point)
                rig.mixer.setDelay(slot: 0, milliseconds: 37)
                rig.run(blocks: 100)
                let hp = rig.collect(blocks: 100, bus: .headphones)
                let expected = mode == .pfl ? T.db(0.1 / sqrt(2.0)) : T.db(0.1 / sqrt(2.0) * pow(10, -6.0 / 20) / sqrt(2.0))
                XCTAssertEqual(T.db(T.rms(hp.left)), expected, accuracy: 0.05, "\(point) \(mode) L")
                XCTAssertEqual(T.db(T.rms(hp.right)), expected, accuracy: 0.05, "\(point) \(mode) R")
            }
        }
    }

    // MARK: 3-5 输入 tap：推子后、AFV 前

    /// AFV 把这路门控到 0 时：`.input`（推子后含 AFV）的 tap 全 0；`.inputPreAFV` 仍有信号，且含推子增益（−6 dB）、声像（全左）、静音。
    func testTap_inputPreAFVTapCarriesFaderAndPanButNotTheAFVGate() {
        let rig = OfflineRig()
        rig.addSource(slot: 0, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
        rig.mixer.setPan(slot: 0, -1)
        rig.mixer.setGain(slot: 0, dB: -6)
        rig.mixer.setAFVGain(slot: 0, 0)
        let gated = rig.mixer.addTap(source: .input(slot: 0))!
        let iso = rig.mixer.addTap(source: .inputPreAFV(slot: 0))!
        rig.run(blocks: 200)
        func drain(_ t: AudioBlockTap) -> (l: [Float], r: [Float]) {
            var l = [Float](), r = [Float]()
            while let b = t.pop() { l.append(contentsOf: b.planes[0]); r.append(contentsOf: b.planes[1]) }
            return (l, r)
        }
        _ = drain(gated); _ = drain(iso)
        rig.run(blocks: 10)
        let g = drain(gated), i = drain(iso)
        XCTAssertEqual(g.l.count, 2560); XCTAssertEqual(i.l.count, 2560)
        XCTAssertEqual(T.peak(g.l), 0, "AFV 门控后的 tap 应全 0")
        XCTAssertEqual(T.peak(g.r), 0)
        XCTAssertEqual(T.db(Double(i.l[100])), -6, accuracy: 0.01, "AFV 前的 tap：推子 −6 dB、全左")
        XCTAssertEqual(Double(i.r[100]), 0, accuracy: 1e-6)
        // 静音也在 AFV 前的 tap 里
        rig.mixer.setMuted(slot: 0, true)
        rig.run(blocks: 50)
        _ = drain(iso)
        rig.run(blocks: 5)
        XCTAssertEqual(T.peak(drain(iso).l), 0, "静音后 AFV 前的 tap 也为 0")
        // 块带 host time 与序号，与总线 tap 同一口径
        rig.mixer.setMuted(slot: 0, false)
        rig.run(blocks: 50)
        _ = drain(iso)
        let idx = rig.driver.blockIndex
        rig.run(blocks: 1)
        let b = iso.pop()!
        XCTAssertEqual(b.hostTime, rig.driver.hostTime(ofBlock: idx))
        XCTAssertEqual(b.planes[0].count, 256)
        rig.mixer.removeTap(gated); rig.mixer.removeTap(iso)
        rig.run(blocks: 2)
        XCTAssertTrue(rig.mixer.waitForCommands(timeout: 0.1))
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 淡变进行中：AFV 前的 tap 电平恒定，含 AFV 的 tap 跟曲线（两者的差就是 AFV 增益）。
    func testTap_inputPreAFVTapIsFlatDuringACrossfade() {
        let rig = makeDCPair()
        let iso0 = rig.mixer.addTap(source: .inputPreAFV(slot: 0))!
        let gated0 = rig.mixer.addTap(source: .input(slot: 0))!
        let (start, startBlock) = fadeStart(rig)
        rig.mixer.crossfade(from: 0, to: 1, durationFrames: 24_000, startHostTime: start)
        let base = rig.driver.blockIndex
        var flat = [Float](), curve = [Float]()
        rig.run(blocks: 120) { _ in
            while let b = iso0.pop() { flat.append(contentsOf: b.planes[0]) }
            while let b = gated0.pop() { curve.append(contentsOf: b.planes[0]) }
        }
        XCTAssertEqual(flat.count, 120 * 256)
        let s0 = (startBlock - base) * 256 + 100
        for i in stride(from: 0, to: flat.count, by: 97) { XCTAssertEqual(Double(flat[i]), 1.0, accuracy: 1e-6, "AFV 前恒定，样本 \(i)") }
        XCTAssertEqual(Double(curve[s0 + 12_000]), cos(Double.pi / 4), accuracy: 2e-6)
        XCTAssertEqual(curve[s0 + 24_000 + 500], 0)
        rig.mixer.removeTap(iso0); rig.mixer.removeTap(gated0)
    }
}
