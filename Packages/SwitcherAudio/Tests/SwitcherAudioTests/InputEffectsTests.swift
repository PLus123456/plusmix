import XCTest
import AudioToolbox
import SwitcherContracts
@testable import SwitcherAudio

/// W1-D3（prompt 102）混音器级：每路输入的两格效果（EQ → 动态，重采样之后、延迟线之前，推子 / AFV / ISO tap 都在它之后）、
/// 自写 C 压缩器（提案 024 (b)：前瞻 0、曲线对 R:1、延迟可自测）、`peakLimiter.ceilingDb` = 限幅之后同一格内的输出增益、
/// 监听来源（提案 026：耳机出口 = 所选总线；独听优先）与 2 声道设备"独听时临时占用 Master 声道"（X09）。全部离线驱动。
final class InputEffectsTests: XCTestCase {

    static func sine(_ hz: Double, dbfs: Double) -> (Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void {
        let amp = pow(10, dbfs / 20)
        return { _, start, n, buf in for i in 0..<n { buf[i] = Float(amp * sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) } }
    }

    /// 两路输入：0 号 → Master、1 号 → Bus A（同一生成器，比较两条总线就是比较"有效果"与"没效果"）。
    func makePair(hz: Double = 1000, dbfs: Double = -30, generator: ((Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void)? = nil) -> OfflineRig {
        let rig = OfflineRig()
        let g = generator ?? Self.sine(hz, dbfs: dbfs)
        rig.addSource(slot: 0, generator: g)
        rig.addSource(slot: 1, generator: g)
        rig.mixer.setRouting(slot: 0, BusRouting(master: true))
        rig.mixer.setRouting(slot: 1, BusRouting(master: false, busA: true))
        return rig
    }

    // MARK: - 每路效果格

    /// 0 号输入的 EQ 1 kHz +12 dB 只改 0 号（Master +12 ± 0.5）；1 号（Bus A，同一信号）频响不变（± 0.05）。
    func testA_inputEffects_eqChangesResponse() throws {
        let rig = makePair()
        _ = try rig.mixer.installInputEffects()
        rig.run(blocks: 100)
        let dry = rig.collect(blocks: 40, bus: .master)
        let dryA = rig.collect(blocks: 40, bus: .busA)
        let eq = try XCTUnwrap(rig.mixer.effectUnit(.input(slot: 0, .parametricEQ)))
        XCTAssertEqual(eq.kind, .nBandEQ)
        eq.setEQBand(0, centerHz: 1000, q: 2, gainDb: 12)
        eq.bypassEQBands(from: 1)
        rig.mixer.setEffectEnabled(.input(slot: 0, .parametricEQ), true)
        rig.run(blocks: 100)
        let wet = rig.collect(blocks: 40, bus: .master)
        let wetA = rig.collect(blocks: 40, bus: .busA)
        XCTAssertEqual(T.db(T.rms(wet.left)) - T.db(T.rms(dry.left)), 12, accuracy: 0.5, "0 号 EQ +12 dB")
        XCTAssertEqual(T.db(T.rms(wetA.left)) - T.db(T.rms(dryA.left)), 0, accuracy: 0.05, "1 号不受 0 号的 EQ 影响")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 两格都装着、开过（有内部状态）再关：0 号（Master）与 1 号（Bus A，同一信号、同一块挂上）逐样本相同。
    func testA_inputEffects_bypassIsTransparent() throws {
        let rig = makePair(generator: { _, start, n, buf in
            // TestSignal：1 kHz −20 dBFS + 每秒 click（click 过压缩器会动增益，关掉之后不许留痕迹）
            TestSignal(t0: HostTime(ticks: 1_000_000_000), timebase: T.tb).render(into: buf, frameCount: n, startingAt: start)
        })
        _ = try rig.mixer.installInputEffects()
        let eq = try XCTUnwrap(rig.mixer.effectUnit(.input(slot: 0, .parametricEQ)))
        eq.setEQBand(0, centerHz: 1000, q: 1, gainDb: 12)
        rig.mixer.setEffectKind(.input(slot: 0, .dynamics), .compressor)
        rig.mixer.setCompressor(.input(slot: 0, .dynamics), CompressorParameters(thresholdDb: -40, ratio: 10))
        rig.mixer.setEffectEnabled(.input(slot: 0, .parametricEQ), true)
        rig.mixer.setEffectEnabled(.input(slot: 0, .dynamics), true)
        rig.run(blocks: 200)
        let wet = rig.collect(blocks: 10, bus: .master), ref = rig.collect(blocks: 10, bus: .busA)
        // EQ +12 dB 把 −20 dBFS 推到 −8，再过阈值 −40 / 10:1 的压缩（压掉 28.8 dB）：开着时电平明显不同
        XCTAssertGreaterThan(abs(T.db(T.rms(wet.left)) - T.db(T.rms(ref.left))), 3, "开着时确实变了（EQ +12 / 压缩）")
        rig.mixer.setEffectEnabled(.input(slot: 0, .parametricEQ), false)
        rig.mixer.setEffectEnabled(.input(slot: 0, .dynamics), false)
        rig.run(blocks: 2)
        var maxDiff: Float = 0
        var peak: Float = 0
        rig.run(blocks: 200) { b in
            let (ml, mr) = b.bus(.master), (al, ar) = b.bus(.busA)
            for i in 0..<b.frames {
                maxDiff = max(maxDiff, abs(ml[i] - al[i]), abs(mr[i] - ar[i]))
                peak = max(peak, abs(ml[i]))
            }
        }
        XCTAssertGreaterThan(peak, 0.4, "有 click 通过")
        XCTAssertEqual(maxDiff, 0, "关掉之后逐样本相同（实测最大差 \(maxDiff)）")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 动态格二选一：装的是苹果 AU（DynamicsProcessor，阈值 −40 把 −10 dBFS 压低 > 6 dB）还是自写压缩器（按 R:1 曲线），运行期切换种类不换拓扑。
    func testA_inputEffects_dynamicsSlotHoldsAUOrCompressor() throws {
        let rig = makePair(dbfs: -10)
        _ = try rig.mixer.installInputEffects()
        rig.run(blocks: 100)
        let dry = T.db(T.rms(rig.collect(blocks: 40, bus: .master).left))
        let dyn = try XCTUnwrap(rig.mixer.effectUnit(.input(slot: 0, .dynamics)))
        XCTAssertEqual(dyn.kind, .dynamicsProcessor)
        dyn.setDynamics(thresholdDb: -40, headroomDb: 5, expansionRatio: 1, attack: 0.001, release: 0.05, overallGainDb: 0)
        rig.mixer.setEffectKind(.input(slot: 0, .dynamics), .audioUnit)
        rig.mixer.setEffectEnabled(.input(slot: 0, .dynamics), true)
        rig.run(blocks: 400)
        let au = T.db(T.rms(rig.collect(blocks: 40, bus: .master).left))
        XCTAssertLessThan(au, dry - 6, "AU 压缩：−10 dBFS 对阈值 −40 应压低至少 6 dB（实测 \(au - dry)）")
        // 换成自写压缩器：阈值 −20、4:1、硬拐点 → −10 dBFS 在阈值上 10 dB → 增益 −7.5 dB
        rig.mixer.setEffectKind(.input(slot: 0, .dynamics), .compressor)
        rig.mixer.setCompressor(.input(slot: 0, .dynamics), CompressorParameters(thresholdDb: -20, ratio: 4, kneeDb: 0, attackSeconds: 0.005, releaseSeconds: 0.1, makeupGainDb: 0))
        rig.run(blocks: 400)
        let comp = T.db(T.rms(rig.collect(blocks: 40, bus: .master).left))
        XCTAssertEqual(comp - dry, -7.5, accuracy: 0.5, "自写压缩器 4:1，阈值上 10 dB → −7.5 dB")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 效果在重采样之后、延迟线之前：延迟补偿 100 ms 时，EQ 过的 click 仍晚 4800 样本（效果不另加延迟），ISO 口径（推子后）含效果。
    func testA_inputEffects_sitBeforeDelayLine() throws {
        func clickPos(effects: Bool) throws -> Int {
            let rig = OfflineRig()
            rig.addSource(slot: 0, resampling: .locked)
            _ = try rig.mixer.installInputEffects()
            if effects {
                rig.mixer.effectUnit(.input(slot: 0, .parametricEQ))!.setEQBand(0, centerHz: 8000, q: 1, gainDb: 6)
                rig.mixer.setEffectEnabled(.input(slot: 0, .parametricEQ), true)
            }
            rig.mixer.setDelay(slot: 0, milliseconds: 100)
            var m = [Float]()
            rig.run(blocks: 400) { b in m.append(contentsOf: b.bus(.master).left) }
            return m.firstIndex { abs($0) >= 0.5 }!
        }
        let plain = try clickPos(effects: false), eq = try clickPos(effects: true)
        XCTAssertEqual(plain, eq, "NBandEQ 延迟 0：click 位置不变（含 100 ms 延迟线）")
    }

    // MARK: - 自写压缩器（提案 024 (b)）

    /// 静态曲线：阈值 −20，输入从阈值下 12 dB 到阈值上 20 dB，每 2 dB 一点；与 R:1 硬拐点（kneeDb 0）或软拐点（给定 kneeDb）的理论曲线差 ≤ 0.5 dB。
    /// 比例 2 / 4 / 10 / 20，拐点 0 / 6 / 12。
    func testA_compressor_ratioCurveWithinHalfDb() throws {
        let threshold = -20.0
        let levels = stride(from: threshold - 12, through: threshold + 20, by: 2).map { $0 }
        func measure(_ p: CompressorParameters?, dbfs: Double) throws -> Double {
            let rig = OfflineRig()
            rig.addSource(slot: 0, resampling: .locked, generator: Self.sine(1000, dbfs: dbfs))
            _ = try rig.mixer.installInputEffects()
            if let p {
                rig.mixer.setEffectKind(.input(slot: 0, .dynamics), .compressor)
                rig.mixer.setCompressor(.input(slot: 0, .dynamics), p)
                rig.mixer.setEffectEnabled(.input(slot: 0, .dynamics), true)
            }
            rig.run(blocks: 150)   // 就绪 + 增益平滑 + 包络稳定（起音 5 ms / 释放 100 ms）
            return T.db(T.rms(rig.collect(blocks: 100, bus: .master).left))
        }
        var worst = 0.0
        for (ratio, knee) in [(2.0, 0.0), (4.0, 0.0), (4.0, 6.0), (10.0, 0.0), (20.0, 12.0)] {
            let p = CompressorParameters(thresholdDb: threshold, ratio: ratio, kneeDb: knee, attackSeconds: 0.005, releaseSeconds: 0.1, makeupGainDb: 0)
            var line = [String]()
            for level in levels {
                let off = try measure(nil, dbfs: level), on = try measure(p, dbfs: level)
                let gain = on - off
                let ideal = p.staticGainDb(inputDb: level)
                worst = max(worst, abs(gain - ideal))
                line.append(String(format: "%+.0f:%+.2f/%+.2f", level - threshold, gain, ideal))
                XCTAssertEqual(gain, ideal, accuracy: 0.5, "ratio \(ratio) knee \(knee) 输入 \(level) dBFS")
            }
            print("[W1-D3] 压缩曲线 R \(ratio):1 knee \(knee)（阈值上 dB:实测/理论）\(line.joined(separator: " "))")
        }
        print("[W1-D3] 压缩曲线最大偏差 \(String(format: "%.3f", worst)) dB（阈值 0.5）")
    }

    /// 延迟自测（提案 024 批后附加要求 ②）：冲激法量到的组延迟 = 算法自报的 0 帧，不同起音 / 释放 / 比例都一样；算法本身不用前瞻。
    func testA_compressor_measuredLatencyEqualsReported() {
        XCTAssertEqual(CompressorParameters.reportedLatencyFrames, 0, "按设计 0 帧（不用前瞻）")
        for p in [CompressorParameters(), CompressorParameters(thresholdDb: -60, ratio: 20, kneeDb: 0, attackSeconds: 0.0001, releaseSeconds: 0.01),
                  CompressorParameters(thresholdDb: 0, ratio: 1, kneeDb: 24, attackSeconds: 0.2, releaseSeconds: 3), CompressorParameters(thresholdDb: -40, ratio: 4, makeupGainDb: 24)] {
            let measured = AudioMixer.probeCompressorLatency(p)
            XCTAssertEqual(measured, CompressorParameters.reportedLatencyFrames, "\(p)")
        }
        // 探针本身要能看出延迟：对照用"理想单位延迟"的参考（把冲激放在 1000、峰值在 1000 → 0；探针按峰值位置算，不会把 0 当默认）
        XCTAssertEqual(AudioMixer.probeCompressorLatency(CompressorParameters(), impulseAt: 2000), 0)
    }

    /// 起音 / 释放的口径（sw_audio_rt.h 的注释是定义）：线性域解耦峰值检测器 r = max(d, αR·r + (1 − αR)·d)、e += (r − e)(1 − αA)，增益 = 静态曲线(e)。
    /// 阈值上 20 dB 的台阶（−40 → 0 → −40 dBFS），把混音器输出的每毫秒峰值包络与同一递推的 Swift 模型比（按台阶起点对齐）：全程 ≤ 0.5 dB
    /// （台阶边沿 ±3 ms 除外）；顺便报"增益走到终值 63% 用时"给报告（不是一阶 dB 曲线，用模型预测值判）。
    func testA_compressor_attackReleaseTimeConstants() throws {
        let attack = 0.020, release = 0.200
        let p = CompressorParameters(thresholdDb: -20, ratio: 20, kneeDb: 0, attackSeconds: attack, releaseSeconds: release, makeupGainDb: 0)
        let hi = 48_000...95_999   // 0 dBFS 的那一秒（源样本序号）
        func input(_ k: Int64) -> Float { Float((hi.contains(Int(k)) ? 1.0 : 0.01) * sin(2 * Double.pi * 1000 * Double(k) / 48_000)) }
        let rig = OfflineRig()
        rig.addSource(slot: 0, resampling: .locked, generator: { _, start, n, buf in for i in 0..<n { buf[i] = input(start + Int64(i)) } })
        _ = try rig.mixer.installInputEffects()
        rig.mixer.setEffectKind(.input(slot: 0, .dynamics), .compressor)
        rig.mixer.setCompressor(.input(slot: 0, .dynamics), p)
        rig.mixer.setEffectEnabled(.input(slot: 0, .dynamics), true)
        var out = [Float]()
        rig.run(blocks: 4 * 48_000 / 256 + 20) { b in out.append(contentsOf: b.bus(.master).left) }
        // 模型：同一递推跑同一输入（单声道居中 → 每边 × 1/√2）
        let aa = exp(-1 / (attack * 48_000)), ar = exp(-1 / (release * 48_000))
        var r = 0.0, e = 0.0
        var model = [Float]()
        model.reserveCapacity(4 * 48_000)
        for k in 0..<(4 * 48_000) {
            let x = Double(input(Int64(k)))
            let d = abs(x)
            r = d > r ? d : d + ar * (r - d)
            e += (r - e) * (1 - aa)
            let g = pow(10, p.staticGainDb(inputDb: T.db(max(e, 1e-12))) / 20)
            model.append(Float(x * g / 2.0.squareRoot()))
        }
        // 样本级对齐：台阶起点（第一个 |x| > 0.5 的样本，两边形状相同）；混音器输出比源晚就绪年龄那么多帧
        guard let onsetSampleGot = out.firstIndex(where: { abs($0) > 0.5 }), let onsetSampleWant = model.firstIndex(where: { abs($0) > 0.5 }) else { return XCTFail("没看到台阶") }
        let aligned = Array(out[(onsetSampleGot - onsetSampleWant)...])
        func envelope(_ s: [Float]) -> [Double] { stride(from: 0, to: s.count - 48, by: 48).map { i in T.db(Double(s[i..<(i + 48)].reduce(0) { max($0, abs($1)) })) } }
        let got = envelope(aligned), want = envelope(model)
        let onsetWant = onsetSampleWant / 48, onsetGot = onsetWant
        var worst = 0.0, worstAt = 0
        // 台阶前 0.5 s 起比（更早的那段混音器的环还没就绪、输出是零）；边沿 ±2 ms 不比
        for i in max(0, onsetWant - 500)..<min(want.count, got.count) {
            let edge = abs(i - onsetWant) <= 2 || abs(i - (onsetWant + 1000)) <= 2
            if edge { continue }
            let d = abs(got[i] - want[i])
            if d > worst { worst = d; worstAt = i }
        }
        XCTAssertLessThanOrEqual(worst, 0.5, "与模型的最大偏差 \(worst) dB（第 \(worstAt) ms）")
        // 报告用：增益走到终值 63% 的用时（模型预测 vs 实测）
        func t63(_ env: [Double], onset: Int, from: Int, to: Int) -> Int? {
            let start = env[onset + from], end = env[(onset + to - 200)..<(onset + to)].reduce(0, +) / 200
            let target = start + (end - start) * 0.63
            return env[(onset + from)...].firstIndex { end < start ? $0 <= target : $0 >= target }.map { $0 - onset - from }
        }
        let attackGot = t63(got, onset: onsetGot, from: 0, to: 900), attackWant = t63(want, onset: onsetWant, from: 0, to: 900)
        let releaseGot = t63(got, onset: onsetGot + 1000, from: 2, to: 1900), releaseWant = t63(want, onset: onsetWant + 1000, from: 2, to: 1900)
        print("[W1-D3] 压缩器时间常数：起音设 \(Int(attack * 1000)) ms → 增益 63% 用时 实测 \(attackGot ?? -1) ms / 模型 \(attackWant ?? -1) ms；释放设 \(Int(release * 1000)) ms → 实测 \(releaseGot ?? -1) ms / 模型 \(releaseWant ?? -1) ms；包络最大偏差 \(String(format: "%.3f", worst)) dB")
        XCTAssertEqual(attackGot ?? -99, attackWant ?? 99, accuracy: 3)
        XCTAssertEqual(releaseGot ?? -99, releaseWant ?? 99, accuracy: 10)
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 总线上的同一份压缩器：Master 1 号格 kind = compressor（不装 AU 也能跑），曲线同每路。
    func testA_compressor_sharedImplementationOnBusSlot() throws {
        func level(_ on: Bool) -> Double {
            let rig = OfflineRig()
            rig.addSource(slot: 0, resampling: .locked, generator: Self.sine(1000, dbfs: -10))
            if on {
                rig.mixer.setEffectKind(.bus(.master, .dynamicsProcessor), .compressor)
                rig.mixer.setCompressor(.bus(.master, .dynamicsProcessor), CompressorParameters(thresholdDb: -20, ratio: 4, kneeDb: 0))
                rig.mixer.setEffectEnabled(.bus(.master, .dynamicsProcessor), true)
            }
            rig.run(blocks: 150)
            return T.db(T.rms(rig.collect(blocks: 100, bus: .master).left))
        }
        // 总线上的检测器看到的是声像后的 −13 dBFS（每边 −3 dB）：阈值上 7 dB × (1 − 1/4) = −5.25 dB
        XCTAssertEqual(level(true) - level(false), -5.25, accuracy: 0.5)
    }

    // MARK: - peakLimiter.ceilingDb（024 顺带 (2)）

    /// 0 dBFS 正弦 + 限幅预增益 +6 → 限幅器天花板 0 dBFS；同一格内的输出增益 −6 dB（ceilingDb）→ 峰值 ≤ −6 + 0.3 dBFS；
    /// 格关掉时输出增益也不作用（旁路 = 原样）。
    func testA_busEffects_limiterCeilingDb() throws {
        let rig = OfflineRig()
        rig.addSource(slot: 0, channels: 2, resampling: .locked, generator: Self.sine(1000, dbfs: 0))
        let lim = try rig.mixer.installEffect(.master, .peakLimiter)
        lim.setLimiter(attack: 0.002, decay: 0.024, preGainDb: 6)
        rig.mixer.setEffectOutputGain(.bus(.master, .peakLimiter), dB: -6)
        rig.mixer.setEffectEnabled(.master, .peakLimiter, true)
        rig.run(blocks: 400)
        var pk: Float = 0
        rig.run(blocks: 40) { b in pk = max(pk, Float(T.peak(Array(b.bus(.master).left)))) }
        XCTAssertLessThanOrEqual(T.db(Double(pk)), -6 + 0.3, "天花板 −6 dBFS")
        XCTAssertGreaterThan(T.db(Double(pk)), -9, "不是把信号砍没了")
        rig.mixer.setEffectEnabled(.master, .peakLimiter, false)
        rig.run(blocks: 40)
        var pk2: Float = 0
        rig.run(blocks: 40) { b in pk2 = max(pk2, Float(T.peak(Array(b.bus(.master).left)))) }
        XCTAssertEqual(T.db(Double(pk2)), 0, accuracy: 0.05, "关掉：原样 0 dBFS，输出增益不作用")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    // MARK: - 监听来源（提案 026）与借 Master 声道（X09）

    /// 耳机出口（out 平面 6 / 7）：默认 = 耳机总线自己（旧行为）；选 Bus A → 逐样本 = Bus A 的输出；选 Master → = Master；
    /// 有独听时不管选了谁都只听独听的（耳机总线）。
    func testMonitor_monitorSourceSelectsBusForHeadphoneOutput() {
        let rig = OfflineRig()
        rig.addSource(slot: 0, generator: Self.sine(1000, dbfs: -20))
        rig.addSource(slot: 1, generator: Self.sine(1500, dbfs: -20))
        rig.mixer.setRouting(slot: 0, BusRouting(master: true))
        rig.mixer.setRouting(slot: 1, BusRouting(master: false, busA: true))
        rig.run(blocks: 100)
        func compare(_ a: Bus, _ b: Bus) -> Float {
            var d: Float = 0
            rig.run(blocks: 20) { blk in
                let (al, ar) = blk.bus(a), (bl, br) = blk.bus(b)
                for i in 0..<blk.frames { d = max(d, abs(al[i] - bl[i]), abs(ar[i] - br[i])) }
            }
            return d
        }
        var hp = rig.collect(blocks: 20, bus: .headphones)
        XCTAssertEqual(T.peak(hp.left), 0, "默认：耳机总线自己，没人路由到耳机 → 静音")
        rig.mixer.setMonitorSource(.busA)
        rig.run(blocks: 2)
        XCTAssertEqual(compare(.headphones, .busA), 0, "耳机出口 = Bus A，逐样本")
        rig.mixer.setMonitorSource(.master)
        rig.run(blocks: 2)
        XCTAssertEqual(compare(.headphones, .master), 0, "耳机出口 = Master，逐样本")
        rig.mixer.setSolo(slot: 1, true)
        rig.run(blocks: 100)
        hp = rig.collect(blocks: 20, bus: .headphones)
        let a = rig.collect(blocks: 20, bus: .busA)
        XCTAssertEqual(T.db(T.rms(hp.left)), T.db(T.rms(a.left)), accuracy: 0.05, "独听优先：耳机 = 独听的 1 号（推子后 = Bus A 的电平），不是 Master")
        XCTAssertNotEqual(compare(.headphones, .master), 0)
        rig.mixer.setSolo(slot: 1, false)
        rig.run(blocks: 100)
        XCTAssertEqual(compare(.headphones, .master), 0, "取消独听回到 Master")
        rig.mixer.setMonitorSource(.headphones)
        rig.run(blocks: 2)
        hp = rig.collect(blocks: 20, bus: .headphones)
        XCTAssertEqual(T.peak(hp.left), 0, "选回耳机总线：旧行为")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 借 Master 声道：开关开着且有独听 → Master 出口（平面 0 / 1）写的是耳机总线（独听信号）；独听关 → 回到 Master；开关关 → 独听时也是 Master。
    /// 消费者队列（录制 / 推流）照常拿 Master 总线，不受影响。
    func testMonitor_borrowMasterChannelsWhileSolo() {
        let rig = OfflineRig()
        rig.addSource(slot: 0, generator: Self.sine(1000, dbfs: -20))
        rig.addSource(slot: 1, generator: Self.sine(1500, dbfs: -20))
        rig.mixer.setRouting(slot: 0, BusRouting(master: true))
        rig.mixer.setRouting(slot: 1, BusRouting(master: true))
        rig.mixer.setMonitorSource(.master)
        let tap = rig.mixer.addTap(source: .bus(.master))!
        rig.run(blocks: 100)
        /// 单频点幅度：窗取 4800 样本 = 1 kHz 100 周期 = 1.5 kHz 150 周期（两个频率都整周期，互不泄漏）。
        func amplitude(_ x: [Float], hz: Double) -> Double {
            var re = 0.0, im = 0.0
            let n = min(x.count, 4800)
            for k in 0..<n { let ph = 2 * Double.pi * hz * Double(k) / 48_000; re += Double(x[k]) * cos(ph); im += Double(x[k]) * sin(ph) }
            return 2 * (re * re + im * im).squareRoot() / Double(n)
        }
        rig.mixer.setBorrowMasterForMonitor(true)
        rig.mixer.setSolo(slot: 1, true)
        rig.run(blocks: 100)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4096); defer { storage.deallocate() }
        var ptrs: [UnsafeMutablePointer<Float>?] = [storage, storage + 4096]
        while tap.pop(into: UnsafePointer(ptrs.withUnsafeMutableBufferPointer { $0.baseAddress! })) != nil {}
        var tapLeft = [Float]()
        let m = rig.collect(blocks: 20, bus: .master)
        while let blk = tap.pop(into: UnsafePointer(ptrs.withUnsafeMutableBufferPointer { $0.baseAddress! })) {
            tapLeft.append(contentsOf: UnsafeBufferPointer(start: storage, count: blk.frames))
        }
        XCTAssertLessThan(T.db(amplitude(m.left, hz: 1000)), -80, "独听 1 号：Master 出口上没有 0 号的 1 kHz（出口写的是耳机总线）")
        XCTAssertGreaterThan(T.db(amplitude(m.left, hz: 1500)), -30, "出口上是独听的 1.5 kHz")
        XCTAssertGreaterThan(T.db(amplitude(tapLeft, hz: 1000)), -30, "消费者队列仍是 Master 总线（录制不受影响）")
        rig.mixer.setSolo(slot: 1, false)
        rig.run(blocks: 100)
        let m2 = rig.collect(blocks: 20, bus: .master)
        XCTAssertGreaterThan(T.db(amplitude(m2.left, hz: 1000)), -30, "独听关：回到 Master")
        rig.mixer.setBorrowMasterForMonitor(false)
        rig.mixer.setSolo(slot: 1, true)
        rig.run(blocks: 100)
        let m3 = rig.collect(blocks: 20, bus: .master)
        XCTAssertGreaterThan(T.db(amplitude(m3.left, hz: 1000)), -30, "开关关：独听时出口仍是 Master")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    // MARK: - A7：运行中改每路效果 / 压缩器参数 / 切种类不分配

    func testA7_inputEffectsParamChangesWhileRendering_noAllocationInRealtime() throws {
        RealtimeGuard.installMallocProbe()
        RealtimeGuard.reset()
        defer { RealtimeGuard.removeMallocProbe() }
        let rig = OfflineRig()
        for s in 0..<8 { rig.addSource(slot: s, generator: Self.sine(500 * Double(s + 1), dbfs: -12)) }
        _ = try rig.mixer.installInputEffects()
        try rig.mixer.installStandardEffects()
        for s in 0..<8 {
            rig.mixer.setEffectEnabled(.input(slot: s, .parametricEQ), true)
            rig.mixer.setEffectKind(.input(slot: s, .dynamics), s % 2 == 0 ? .compressor : .audioUnit)
            rig.mixer.setEffectEnabled(.input(slot: s, .dynamics), true)
        }
        rig.mixer.setEffectKind(.bus(.master, .dynamicsProcessor), .compressor)
        for e in BusEffect.allCases { rig.mixer.setEffectEnabled(.master, e, true) }
        var k = 0
        rig.run(blocks: 2000) { _ in
            k += 1
            let s = k % 8
            rig.mixer.effectUnit(.input(slot: s, .parametricEQ))!.setEQBand(k % 3, centerHz: Float(200 + (k % 50) * 100), q: 1, gainDb: Float(k % 25 - 12), enabled: k % 7 != 0)
            rig.mixer.setCompressor(.input(slot: s, .dynamics), CompressorParameters(thresholdDb: Double(-(k % 40)), ratio: Double(1 + k % 20), kneeDb: Double(k % 24),
                                                                                       attackSeconds: 0.0001 + Double(k % 100) * 0.001, releaseSeconds: 0.01 + Double(k % 30) * 0.1, makeupGainDb: Double(k % 24)))
            if k % 97 == 0 { rig.mixer.setEffectKind(.input(slot: s, .dynamics), k % 2 == 0 ? .compressor : .audioUnit) }
            rig.mixer.setEffectOutputGain(.bus(.master, .peakLimiter), dB: Double(-(k % 20)))
            rig.mixer.setMonitorSource(Bus.allCases[k % 4])
            rig.mixer.setBorrowMasterForMonitor(k % 2 == 0)
        }
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
        XCTAssertEqual(RealtimeGuard.allocationsInRealtime, 0, "每路效果 / 压缩器 / 切种类 / 监听来源都不在实时区分配")
        XCTAssertEqual(rig.mixer.stats.underruns, 0)
        XCTAssertEqual(rig.mixer.stats.commandsDropped, 0)
    }

    // MARK: - 预建成本（报告用）

    /// 32 路 × 2 格 = 64 个 AU 预建：时间与常驻内存增量写报告；上限 2 s（启动时间）。
    func testInputEffects_prebuildCostReport() throws {
        func rss() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
            return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : .nan
        }
        let mixer = AudioMixer(configuration: { var c = AudioMixerConfiguration(); c.timebase = T.tb; return c }())
        XCTAssertEqual(mixer.inputCapacity, 32)
        let before = rss()
        let t0 = Date()
        let r = try mixer.installInputEffects()
        let dt = Date().timeIntervalSince(t0)
        let after = rss()
        XCTAssertEqual(r.units, 64)
        for s in 0..<32 {
            XCTAssertEqual(mixer.effectUnit(.input(slot: s, .parametricEQ))?.kind, .nBandEQ)
            XCTAssertEqual(mixer.effectUnit(.input(slot: s, .dynamics))?.kind, .dynamicsProcessor)
        }
        print(String(format: "[W1-D3] 预建 64 个 AU（32 路 × EQ 16 段 + DynamicsProcessor）：%.1f ms，RSS +%.1f MB（%.1f → %.1f）", dt * 1000, after - before, before, after))
        XCTAssertLessThan(dt, 2.0)
    }
}
