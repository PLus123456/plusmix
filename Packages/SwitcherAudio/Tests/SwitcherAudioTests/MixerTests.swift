import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// 混音核心（离线驱动）：路由矩阵、AFV 曲线、延迟补偿、声像、对齐、命令确认。
final class MixerTests: XCTestCase {

    func testMixer_attachDetachCommandsAreAcknowledged() {
        let rig = OfflineRig()
        let src = rig.addSource(slot: 3)
        XCTAssertEqual(rig.mixer.commandsPushed, 1)
        XCTAssertEqual(rig.mixer.commandsApplied, 0, "没跑块之前命令不会被应用")
        XCTAssertFalse(rig.mixer.waitForCommands(timeout: 0.05))
        rig.run(blocks: 1)
        XCTAssertEqual(rig.mixer.commandsApplied, 1)
        XCTAssertTrue(rig.mixer.stats.inputs[3].attached)
        XCTAssertTrue(rig.mixer.ring(atSlot: 3) === src.ring)
        rig.mixer.detach(slot: 3)
        XCTAssertNil(rig.mixer.ring(atSlot: 3))
        rig.run(blocks: 1)
        XCTAssertTrue(rig.mixer.waitForCommands(timeout: 0.1))
        XCTAssertFalse(rig.mixer.stats.inputs[3].attached)
        XCTAssertEqual(rig.mixer.stats.blocksRendered, 2)
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// 四总线路由矩阵，表驱动：16 种路由 × 有无独听 × PFL / AFL。只送 A 不送 Master 时 Master 里该信号 ≤ −120 dB。
    func testRouting_matrixTableDriven() {
        struct Case { let routing: BusRouting; let solo: Bool; let mode: MonitorMode }
        var cases = [Case]()
        for m in [false, true] { for a in [false, true] { for b in [false, true] { for h in [false, true] {
            for solo in [false, true] { for mode in [MonitorMode.afl, .pfl] {
                cases.append(Case(routing: BusRouting(master: m, busA: a, busB: b, headphones: h), solo: solo, mode: mode))
            } }
        } } } }
        for c in cases {
            let rig = OfflineRig()
            // 恒定 −20 dBFS 的 1 kHz（TestSignal 的 click 会影响 RMS，用纯正弦生成器）
            rig.addSource(slot: 0, generator: { _, start, n, buf in
                for i in 0..<n { buf[i] = 0.1 * Float(sin(2 * Double.pi * 1000 * Double(start + Int64(i)) / 48_000)) }
            })
            rig.mixer.setRouting(slot: 0, c.routing)
            rig.mixer.setSolo(slot: 0, c.solo)
            rig.mixer.setMonitorMode(c.mode)
            rig.mixer.setGain(slot: 0, dB: -6)   // 推子 −6 dB：PFL 应不受影响，AFL 受影响
            // 先跑 100 块让环就绪、增益平滑到位，再采 100 块
            rig.run(blocks: 100)
            var bus = [Bus: (l: [Float], r: [Float])]()
            var outs = [Bus: ([Float], [Float])]()
            for b in Bus.allCases { outs[b] = ([], []) }
            rig.run(blocks: 100) { blk in
                for b in Bus.allCases {
                    let (l, r) = blk.bus(b)
                    outs[b]!.0.append(contentsOf: l); outs[b]!.1.append(contentsOf: r)
                }
            }
            for b in Bus.allCases { bus[b] = (outs[b]!.0, outs[b]!.1) }
            // 单声道输入居中：等功率声像每边 −3 dB；推子 −6 dB → 每边 0.1 × 0.7071 × 0.5011
            let expectedAFL = T.db(0.1 / sqrt(2.0) * pow(10, -6.0 / 20) / sqrt(2.0))   // RMS = 峰值/√2
            let expectedPFL = T.db(0.1 / sqrt(2.0))                                    // 推子前、不声像
            let desc = "routing=\(c.routing) solo=\(c.solo) mode=\(c.mode)"
            func check(_ b: Bus, on: Bool, expected: Double) {
                let l = T.db(T.rms(bus[b]!.l)), r = T.db(T.rms(bus[b]!.r))
                if on {
                    XCTAssertEqual(l, expected, accuracy: 0.05, "\(desc) \(b) L")
                    XCTAssertEqual(r, expected, accuracy: 0.05, "\(desc) \(b) R")
                } else {
                    XCTAssertLessThanOrEqual(l, -120, "\(desc) \(b) L 应无信号")
                    XCTAssertLessThanOrEqual(r, -120, "\(desc) \(b) R 应无信号")
                }
            }
            check(.master, on: c.routing.master, expected: expectedAFL)
            check(.busA, on: c.routing.busA, expected: expectedAFL)
            check(.busB, on: c.routing.busB, expected: expectedAFL)
            // 耳机：独听时只听独听的（PFL 推子前 / AFL 推子后），否则按路由
            if c.solo {
                check(.headphones, on: true, expected: c.mode == .pfl ? expectedPFL : expectedAFL)
            } else {
                check(.headphones, on: c.routing.headphones, expected: expectedAFL)
            }
        }
    }

    /// 独听：有一路独听时，其他未独听的输入即使路由到耳机也听不到。
    func testRouting_soloSilencesOthersOnHeadphones() {
        let rig = OfflineRig()
        rig.addSource(slot: 0, generator: { _, start, n, buf in for i in 0..<n { buf[i] = 0.5 * Float(sin(Double(start + Int64(i)) * 0.1)) } })
        rig.addSource(slot: 1, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 0 } })
        rig.mixer.setRouting(slot: 0, BusRouting(master: true, headphones: true))
        rig.mixer.setRouting(slot: 1, BusRouting(master: true, headphones: true))
        rig.mixer.setSolo(slot: 1, true)
        rig.run(blocks: 100)
        let hp = rig.collect(blocks: 50, bus: .headphones)
        XCTAssertLessThanOrEqual(T.db(T.rms(hp.left)), -120)
        let master = rig.collect(blocks: 50, bus: .master)
        XCTAssertGreaterThan(T.db(T.rms(master.left)), -20, "Master 不受独听影响")
    }

    /// AFV 等幅交叉淡变：中点两路各 −3 dB；起点按 startHostTime 样本定位；整个过程功率和为 1。
    func testAFV_equalPowerCrossfadeMidpointIsMinus3dB() {
        let rig = OfflineRig()
        // 两路直流（恒定 1.0），路由到 Master；左右各自看：A 只送左（pan −1），B 只送右（pan +1）
        rig.addSource(slot: 0, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
        rig.addSource(slot: 1, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
        rig.mixer.setPan(slot: 0, -1)
        rig.mixer.setPan(slot: 1, 1)
        rig.mixer.setAFVGain(slot: 1, 0)     // B 先关
        rig.run(blocks: 200)                 // 就绪 + 平滑到位
        // 起点：第 5 块的第 100 个样本；时长 40 块（10240 样本）
        let startBlock = rig.driver.blockIndex + 5
        let startSample = 100
        let tpf = 1e9 / 48_000
        let start = HostTime(ticks: rig.driver.hostTime(ofBlock: startBlock).ticks + UInt64((Double(startSample) * tpf).rounded()))
        let durationBlocks = 40
        rig.mixer.crossfade(from: 0, to: 1, durationBlocks: durationBlocks, startHostTime: start)
        var l = [Float](), r = [Float]()
        let base = rig.driver.blockIndex
        rig.run(blocks: 60) { b in l.append(contentsOf: b.bus(.master).left); r.append(contentsOf: b.bus(.master).right) }
        let s0 = (startBlock - base) * 256 + startSample
        let dur = durationBlocks * 256
        // 起点前：A = 1，B = 0
        XCTAssertEqual(Double(l[s0 - 1]), 1.0, accuracy: 1e-4)
        XCTAssertEqual(Double(r[s0 - 1]), 0.0, accuracy: 1e-4)
        // 中点：各 −3.01 dB
        let mid = s0 + dur / 2
        XCTAssertEqual(T.db(Double(l[mid])), -3.01, accuracy: 0.05, "from 在中点应 −3 dB")
        XCTAssertEqual(T.db(Double(r[mid])), -3.01, accuracy: 0.05, "to 在中点应 −3 dB")
        // 终点后：A = 0，B = 1
        XCTAssertEqual(Double(l[s0 + dur + 10]), 0.0, accuracy: 1e-4)
        XCTAssertEqual(Double(r[s0 + dur + 10]), 1.0, accuracy: 1e-4)
        // 全程等功率：l² + r² = 1，且单调
        var lastL: Float = 2, lastR: Float = -1
        for i in stride(from: s0, to: s0 + dur, by: 7) {
            XCTAssertEqual(Double(l[i] * l[i] + r[i] * r[i]), 1.0, accuracy: 1e-3, "样本 \(i) 功率和")
            XCTAssertLessThanOrEqual(l[i], lastL + 1e-6); XCTAssertGreaterThanOrEqual(r[i], lastR - 1e-6)
            lastL = l[i]; lastR = r[i]
        }
        // 起点精确到样本：s0 + k 处的增益 = cos(π/2 · k / dur)（k = 1 时 float32 分辨不出与 1 的差，用 k = 64 与 640）
        for k in [64, 640, 2048] {
            XCTAssertEqual(Double(l[s0 + k]), cos(Double.pi / 2 * Double(k) / Double(dur)), accuracy: 2e-6, "s0+\(k)")
            XCTAssertEqual(Double(r[s0 + k]), sin(Double.pi / 2 * Double(k) / Double(dur)), accuracy: 2e-6, "s0+\(k)")
        }
        // 起点错一个样本就对不上：s0 − 1 仍是 1.0 / 0.0
        XCTAssertEqual(Double(l[s0 - 1]), 1.0, accuracy: 1e-7)
        XCTAssertEqual(Double(r[s0 - 1]), 0.0, accuracy: 1e-7)
    }

    /// 延迟补偿：设 100 ms，click 在输出里正好晚 4800 样本（对比 0 ms 的同一输入）。
    func testDelay_100msMovesClickByExactly4800Samples() {
        func clickPosition(delayMs: Double) -> Int {
            let rig = OfflineRig()
            // 一个 click：样本 20000…20047 = 1.0，其他 0
            rig.addSource(slot: 0, resampling: .locked, generator: { _, start, n, buf in
                for i in 0..<n { let s = start + Int64(i); buf[i] = (s >= 20_000 && s < 20_048) ? 1 : 0 }
            })
            rig.mixer.setPan(slot: 0, -1)
            rig.mixer.setDelay(slot: 0, milliseconds: delayMs)
            let out = rig.collect(blocks: 400, bus: .master)   // 400 × 256 = 102400 样本
            return out.left.firstIndex { $0 > 0.5 } ?? -1
        }
        let p0 = clickPosition(delayMs: 0)
        let p100 = clickPosition(delayMs: 100)
        XCTAssertGreaterThan(p0, 0)
        XCTAssertEqual(p100 - p0, 4800, "100 ms 延迟补偿应正好 4800 样本")
        // 500 ms 上限也精确
        XCTAssertEqual(clickPosition(delayMs: 500) - p0, 24_000)
    }

    /// 锁定比率 1.0 时重采样器无对齐延迟：输出样本 k 就是环里第 (起点 + k) 帧（libsamplerate 前补零，sinc 中心对准）。
    func testAlignment_lockedRatioHasZeroLatency() {
        let rig = OfflineRig()
        // 斜坡 + 每 1000 样本一个标记：用线性斜坡能直接读出帧序号（sinc 对直线保真）
        rig.addSource(slot: 0, resampling: .locked, generator: { _, start, n, buf in
            for i in 0..<n { buf[i] = Float(start + Int64(i)) * 1e-6 }
        })
        rig.mixer.setPan(slot: 0, -1)
        rig.run(blocks: 50)
        let stats = rig.mixer.stats.inputs[0]
        XCTAssertTrue(stats.primed)
        let out = rig.collect(blocks: 20, bus: .master)
        // 输出第 k 个样本 ≈ (consumedStart + k) × 1e-6：用相邻差分 = 1e-6 且绝对值反推序号
        let idx0 = Double(out.left[1000]) / 1e-6
        let idx1 = Double(out.left[1001]) / 1e-6
        XCTAssertEqual(idx1 - idx0, 1.0, accuracy: 0.01)
        XCTAssertEqual(idx0.rounded(), idx0, accuracy: 0.02, "输出样本对应整数帧序号（无分数延迟）")
    }

    /// 声像律：单声道等功率（中点 −3 dB、两端 0 / 满）；立体声平衡（中点各 1，不抬升）。
    func testPan_lawMonoEqualPowerAndStereoBalance() {
        for (pan, el, er) in [(0.0, 1 / sqrt(2.0), 1 / sqrt(2.0)), (-1.0, 1.0, 0.0), (1.0, 0.0, 1.0), (0.5, cos(0.75 * .pi / 2), sin(0.75 * .pi / 2))] {
            let rig = OfflineRig()
            rig.addSource(slot: 0, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
            rig.mixer.setPan(slot: 0, pan)
            rig.run(blocks: 200)
            let o = rig.collect(blocks: 2, bus: .master)
            XCTAssertEqual(Double(o.left[100]), el, accuracy: 1e-4, "mono pan=\(pan) L")
            XCTAssertEqual(Double(o.right[100]), er, accuracy: 1e-4, "mono pan=\(pan) R")
        }
        for (pan, el, er) in [(0.0, 1.0, 1.0), (-1.0, 1.0, 0.0), (1.0, 0.0, 1.0), (0.5, min(1, sqrt(2.0) * cos(0.75 * .pi / 2)), 1.0)] {
            let rig = OfflineRig()
            rig.addSource(slot: 0, channels: 2, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
            rig.mixer.setPan(slot: 0, pan)
            rig.run(blocks: 200)
            let o = rig.collect(blocks: 2, bus: .master)
            XCTAssertEqual(Double(o.left[100]), el, accuracy: 1e-4, "stereo pan=\(pan) L")
            XCTAssertEqual(Double(o.right[100]), er, accuracy: 1e-4, "stereo pan=\(pan) R")
        }
    }

    /// 增益 / 静音 / 总线增益都平滑到位，且数值正确。
    func testGain_inputAndBusGainsApply() {
        let rig = OfflineRig()
        rig.addSource(slot: 0, generator: { _, _, n, buf in for i in 0..<n { buf[i] = 1 } })
        rig.mixer.setPan(slot: 0, -1)
        rig.mixer.setGain(slot: 0, dB: -12)
        rig.mixer.setBusGain(.master, dB: 6)
        rig.run(blocks: 200)
        var o = rig.collect(blocks: 2, bus: .master)
        XCTAssertEqual(T.db(Double(o.left[10])), -6, accuracy: 0.01)
        rig.mixer.setMuted(slot: 0, true)
        rig.run(blocks: 50)
        o = rig.collect(blocks: 2, bus: .master)
        XCTAssertEqual(Double(o.left[10]), 0, accuracy: 1e-6)
        rig.mixer.setMuted(slot: 0, false)
        rig.mixer.setBusMuted(.master, true)
        rig.run(blocks: 50)
        o = rig.collect(blocks: 2, bus: .master)
        XCTAssertEqual(Double(o.left[10]), 0, accuracy: 1e-6)
        // 静音切换是平滑的：没有单样本跳变 > 0.1
        rig.mixer.setBusMuted(.master, false)
        var prev: Float = 0
        var maxJump: Float = 0
        rig.run(blocks: 20) { b in for v in b.bus(.master).left { maxJump = max(maxJump, abs(v - prev)); prev = v } }
        XCTAssertLessThan(maxJump, 0.1, "静音解除应平滑（无爆音）")
    }

    /// 消费者队列：Master 块带首样本 host time（= 块的拍点时刻）、序号连续；消费者不取则丢块并计数，实时线程不受影响。
    func testTap_masterBlocksCarryHostTimeAndDropWhenFull() {
        let rig = OfflineRig()
        rig.addSource(slot: 0)
        let tap = rig.mixer.addTap(source: .bus(.master), capacityBlocks: 8)!
        rig.run(blocks: 4)
        XCTAssertEqual(tap.count, 4)
        var expectedIndex = 0
        var lastSeq: UInt64? = nil
        while let b = tap.pop() {
            XCTAssertEqual(b.hostTime, rig.driver.hostTime(ofBlock: expectedIndex))
            XCTAssertEqual(b.planes.count, 2)
            XCTAssertEqual(b.planes[0].count, 256)
            if let s = lastSeq { XCTAssertEqual(b.sequence, s + 1) }
            lastSeq = b.sequence
            expectedIndex += 1
        }
        XCTAssertEqual(expectedIndex, 4)
        rig.run(blocks: 20)   // 容量 8：丢 12 块
        XCTAssertEqual(tap.count, 8)
        XCTAssertEqual(tap.dropped, 12)
        XCTAssertEqual(rig.mixer.stats.tapDrops, 12)
        XCTAssertEqual(rig.mixer.stats.underruns, 0)
        rig.mixer.removeTap(tap)
        rig.run(blocks: 2)
        XCTAssertTrue(rig.mixer.waitForCommands(timeout: 0.1))
    }
}
