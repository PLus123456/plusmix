import XCTest
import Darwin
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// W1-D3 报告用：8 路全开每路效果（EQ 一段 + 自写压缩器）+ Master 三格 时进程 CPU 的增幅（prompt 102 "V1 / CPU"一条）。
/// 空设备（实时线程按块 render）、8 路实时合成源；先量不开效果 N 秒，再量全开 N 秒，报进程 CPU（getrusage，单核 %）与混音块耗时。
/// 不判阈值（基线在 W4-A 的 perf 报告里，口径不同），只报数。`SW_AUDIO_CPU_SECONDS` 改时长（默认 20）。
final class InputEffectsCPUTests: XCTestCase {
    typealias FX = BusEffectsTests

    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    func testCPU_eightInputsAllEffects_report() async throws {
        let seconds = IT.seconds("SW_AUDIO_CPU_SECONDS", default: 20)
        var state = States.fourInputs(afv: false)
        state.inputs = (1...8).map { InputConfig(number: $0, name: "机位 \($0)", source: .synthetic(settings: SyntheticSourceSettings())) }
        let sm = StateMachine(initialState: state)
        sm.start()
        var cfg = AudioEngineConfiguration()
        cfg.output = .null
        let engine = try AudioEngine(stateMachine: sm, configuration: cfg)
        let t0 = HostClock.now() + HostDuration(milliseconds: 300)
        try await engine.start(clock: TickClockSpec(t0: t0, frameRate: .fps60))
        var sources: [RealtimeSource] = []
        for n in 1...8 {
            let hz = 200.0 * Double(n)
            let src = RealtimeSource(t0: t0) { start, count, buf in
                for i in 0..<count { buf[i] = 0.1 * Float(sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) }
            }
            var hints = AudioInputHints(); hints.producerBlockFrames = 256
            try engine.registerInput(number: n, ring: src.ring, hints: hints)
            src.start()
            sources.append(src)
        }
        let analyzer = StreamAnalyzer(name: "cpu", t0: t0)
        try engine.addConsumer(analyzer, source: .master)
        try await Task.sleep(for: .seconds(2))

        func measure(_ label: String) async -> (cpuPct: Double, blockUs: Double, maxBlockUs: Double) {
            let c0 = Self.cpuSeconds(), w0 = HostClock.now()
            let s0 = engine.mixer.stats
            var ticks: [UInt64] = []
            let end = HostClock.now() + HostDuration(seconds: seconds)
            while HostClock.now() < end {
                sm.requestPrepare(TickClockSpec(t0: t0, frameRate: .fps60).tick(at: HostClock.now()) + 1)
                ticks.append(engine.mixer.stats.lastBlockTicks)
                try? await Task.sleep(for: .milliseconds(5))
            }
            let c1 = Self.cpuSeconds(), w1 = HostClock.now()
            let s1 = engine.mixer.stats
            let tpu = Double(HostClock.timebase.numer) / Double(HostClock.timebase.denom) / 1000   // tick → µs
            let avg = ticks.isEmpty ? 0 : Double(ticks.reduce(0, +)) / Double(ticks.count) * tpu
            let r = (cpuPct: (c1 - c0) / (w1 - w0).seconds * 100, blockUs: avg, maxBlockUs: Double(s1.maxBlockTicks) * tpu)
            print("[W1-D3] CPU \(label)：进程 \(String(format: "%.1f", r.cpuPct))%（单核口径），混音块均值 \(String(format: "%.0f", r.blockUs)) µs，最长 \(String(format: "%.0f", r.maxBlockUs)) µs，块 \(s1.blocksRendered - s0.blocksRendered)")
            return r
        }
        engine.mixer.resetStats()
        let off = await measure("8 路无效果")
        // 全开：每路 EQ 一段 + 压缩器；Master EQ + 压缩器 + 限幅
        for n in 1...8 {
            var s = InputSettings()
            s.effects = [FX.eq(1000, q: 1.4, gainDb: 3), InputEffectsIntegrationTests.compressor(thresholdDb: -30, ratio: 4)]
            _ = await sm.apply(.setInputSettings(input: n, settings: s))
        }
        _ = await sm.apply(.setBusEffects(bus: .master, effects: [FX.eq(2000, gainDb: 2), InputEffectsIntegrationTests.compressor(thresholdDb: -20, ratio: 2), FX.limiter(attackSeconds: 0.002)]))
        try await Task.sleep(for: .seconds(2))
        for n in 1...8 { XCTAssertEqual(engine.inputEffectsStatus(n)?.dynamicsKind, .compressor, "输入 \(n) 的效果没接上") }
        engine.mixer.resetStats()
        let on = await measure("8 路全开效果 + Master 三格")
        let st = engine.status
        print("[W1-D3] CPU 增幅：\(String(format: "%+.1f", on.cpuPct - off.cpuPct)) 个百分点（\(String(format: "%.1f", off.cpuPct))% → \(String(format: "%.1f", on.cpuPct))%），混音块均值 \(String(format: "%.0f", off.blockUs)) → \(String(format: "%.0f", on.blockUs)) µs；dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 违规 \(st.realtimeViolations) 不连续 \(analyzer.discontinuities)")
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(st.realtimeViolations, 0)
        XCTAssertLessThan(on.maxBlockUs, 5333, "最长块仍在预算内")
        for s in sources { s.stop() }
        await engine.stop()
        sm.stop()
    }
}
