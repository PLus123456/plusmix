import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// A7 实时线程违规（测试标准 §1 A7、§2.9、§4：0 次，硬性）。
/// 离线 10 分钟标准负载（8 路输入含 ±100 ppm 漂移、四总线效果链全开、四个消费者队列、表）在守卫 + malloc 钩子下跑，
/// 违规 = 0、实时区内分配 = 0。真设备 1 分钟在 DeviceTests 里。
final class RealtimeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        RealtimeGuard.installMallocProbe()
        RealtimeGuard.reset()
    }
    override func tearDown() {
        RealtimeGuard.removeMallocProbe()
        super.tearDown()
    }

    /// 机制自检：守卫区里故意 malloc，钩子必须记到；否则后面的 0 没有意义。
    func testA7_guardSelfTestCatchesAllocation() {
        let before = RealtimeGuard.violations
        let caught = RealtimeGuard.selfTest()
        XCTAssertGreaterThanOrEqual(caught, 2, "malloc 钩子没记到守卫区内的分配")
        XCTAssertGreaterThanOrEqual(RealtimeGuard.violations - before, 3, "封装 + 钩子都应记违规")
        XCTAssertFalse(RealtimeGuard.isActiveOnThisThread)
        RealtimeGuard.reset()
    }

    /// 标准负载离线 10 分钟（SW_AUDIO_A7_SECONDS 可改）。
    func testA7_offline10min_zeroViolations() throws {
        let seconds = T.seconds("SW_AUDIO_A7_SECONDS", default: 600)
        let rig = OfflineRig()
        try rig.mixer.installStandardEffects()
        let drifts: [Double] = [100, -100, 50, -50, 0, 0, 0, 0]
        // 便宜的生成器（查表正弦，每路不同频率）：TestSignal.render 在 debug Swift 里每样本 0.6 µs，8 路就是 2.5 ms/块，
        // 会把离线 10 分钟拖到 5 分钟；这里测的是混音器的实时规则，不是信号本身
        let table: [Float] = (0..<48_000).map { Float(0.1 * sin(2 * Double.pi * Double($0) / 48_000)) }
        for (i, d) in drifts.enumerated() {
            let step = Int64(200 * (i + 1))   // 200 Hz × (i+1)
            rig.addSource(slot: i, channels: i % 2 == 0 ? 1 : 2, driftPpm: d, producerBlock: i == 3 ? 480 : 256,
                          generator: { _, start, n, buf in
                var idx = Int((start * step) % 48_000)
                let st = Int(step)
                for k in 0..<n { buf[k] = table[idx]; idx += st; if idx >= 48_000 { idx -= 48_000 } }
            })
            rig.mixer.setRouting(slot: i, BusRouting(master: true, busA: i % 2 == 0, busB: i % 3 == 0, headphones: i == 1))
            rig.mixer.setGain(slot: i, dB: -12)
            rig.mixer.setPan(slot: i, Double(i) / 4 - 1)
            rig.mixer.setDelay(slot: i, milliseconds: Double(i * 20))
        }
        for b in Bus.allCases { for e in BusEffect.allCases { rig.mixer.setEffectEnabled(b, e, true) } }
        rig.mixer.effectUnit(.master, .parametricEQ)!.setParametricEQ(centerHz: 2000, q: 1, gainDb: 3)
        rig.mixer.effectUnit(.master, .peakLimiter)!.setLimiter(preGainDb: 3)
        let taps = [rig.mixer.addTap(source: .bus(.master))!, rig.mixer.addTap(source: .bus(.busA))!,
                    rig.mixer.addTap(source: .bus(.headphones))!, rig.mixer.addTap(source: .input(slot: 2))!]
        let blocks = Int(seconds * 48_000 / 256)
        var blk = 0
        let t0 = Date()
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4096)
        defer { storage.deallocate() }
        var ptrs: [UnsafeMutablePointer<Float>?] = [storage, storage + 4096]
        rig.run(blocks: blocks) { _ in
            blk += 1
            // 每 100 块做点"运行期"的事：改增益、切换 AFV、消费队列
            if blk % 100 == 0 {
                rig.mixer.setGain(slot: blk % 8, dB: Double(-12 + (blk / 100) % 6))
                rig.mixer.crossfade(from: (blk / 100) % 8, to: (blk / 100 + 1) % 8, durationBlocks: 30, startHostTime: rig.driver.nextBlockHostTime)
                for t in taps { while t.pop(into: UnsafePointer(ptrs.withUnsafeMutableBufferPointer { $0.baseAddress! })) != nil {} }
            }
        }
        let wall = Date().timeIntervalSince(t0)
        let st = rig.mixer.stats
        XCTAssertEqual(st.rtViolations, 0, "A7 违规必须为 0")
        XCTAssertEqual(RealtimeGuard.allocationsInRealtime, 0, "实时区内不许有 malloc / free")
        XCTAssertEqual(st.underruns, 0)
        XCTAssertEqual(st.blocksRendered, UInt64(blocks))
        XCTAssertEqual(st.commandsDropped, 0)
        for i in 0..<8 { XCTAssertTrue(st.inputs[i].primed, "输入 \(i) 就绪") ; XCTAssertEqual(st.inputs[i].reprimes, 1) }
        let tpf = 1e9 / 48_000
        print(String(format: "[A7] 离线 %.0f s 标准负载：违规 %llu，实时区分配 %llu，欠载 %llu，%d 块，墙钟 %.1f s（%.1f× 实时），最长块 %.0f µs（预算 5333 µs）",
                     seconds, st.rtViolations, RealtimeGuard.allocationsInRealtime, st.underruns, blocks, wall, seconds / wall,
                     Double(st.maxBlockTicks) * HostClock.timebase.numerDouble / 1000))
        _ = tpf
    }
}

extension MachTimebase {
    /// numer / denom 的浮点值（纳秒每 tick）。
    var numerDouble: Double { Double(numer) / Double(denom) }
}
