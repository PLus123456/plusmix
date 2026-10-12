import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 提案 026 允许 `monitorSource = headphones`（用户 2026-10-12，P5-3）：集成层把它原样交给混音器（`SW_CMD_MONITOR_SOURCE i0 = 3` = 耳机总线自己，W1-D3 已支持），
/// 不再"万一出现按 master"。耳机出口 = 只有每路 `routing.headphones` 送出的那些；独听仍优先（与 master / busA / busB 同口径）。
final class MonitorSourceHeadphonesTests: XCTestCase {
    typealias FX = BusEffectsTests

    /// 1 → Master（1 kHz）、2 → Bus A + 耳机（1.5 kHz）、3 → Bus B + 耳机（750 Hz）：耳机总线 = 2 + 3，与任何一条节目总线都不同。
    /// 监听点设在延迟线后（AudioEngineConfiguration.monitorPoint）：耳机总线与 A / B 拿的是同一份推子后信号，同一块逐样本可比——耳机出口 = A 出口 + B 出口。
    /// 频谱旁证每次量 96 块（24 576 帧 = 三个频率与它们的差频都是整数个周期，单频点 DFT 互不泄漏）。
    /// 状态起来就是 headphones（启动那次推送）→ 改 master → 再用命令改回 headphones → 独听 2 → 耳机出口 = 只有 2（= A）→ 关独听回到耳机总线。
    func test026_monitorSourceHeadphones_exitIsHeadphonesBus_soloStillWins() async throws {
        var state = States.fourInputs(afv: false)
        state.inputs[1].settings.audio.routing = BusRouting(master: false, busA: true, headphones: true)
        state.inputs[2].settings.audio.routing = BusRouting(master: false, busB: true, headphones: true)
        state.audio.monitorSource = .headphones
        let rig = try await EngineRig(state: state) { $0.monitorPoint = .postDelayLine }
        try rig.addSource(number: 1, generator: FX.sine(1000, amplitude: 0.2))
        try rig.addSource(number: 2, generator: FX.sine(1500, amplitude: 0.2))
        try rig.addSource(number: 3, generator: FX.sine(750, amplitude: 0.2))
        var hp = [Float](), master = [Float](), busA = [Float](), busB = [Float]()
        rig.afterBlock = { b in
            hp.append(contentsOf: b.bus(.headphones).left); master.append(contentsOf: b.bus(.master).left)
            busA.append(contentsOf: b.bus(.busA).left); busB.append(contentsOf: b.bus(.busB).left)
        }
        func measure() async {
            hp.removeAll(); master.removeAll(); busA.removeAll(); busB.removeAll()
            await rig.run(blocks: 96)
        }
        func assertHeadphonesBus(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(hp.isEmpty, label, file: file, line: line)
            XCTAssertNil(Self.sampleDiff(hp, zip(busA, busB).map { $0 + $1 }), "\(label)：耳机出口逐样本 = 耳机总线（送耳机的 2 + 3 = A + B）", file: file, line: line)
            XCTAssertLessThan(IT.db(FX.amplitude(hp[...], hz: 1000)), -80, "\(label)：没有只走 Master 的 1 kHz", file: file, line: line)
            XCTAssertGreaterThan(IT.db(FX.amplitude(hp[...], hz: 1500)), -30, label, file: file, line: line)
            XCTAssertGreaterThan(IT.db(FX.amplitude(hp[...], hz: 750)), -30, label, file: file, line: line)
        }

        // 状态起来就是 headphones：start 那次推送就交给混音器
        await rig.run(seconds: 1)
        XCTAssertEqual(rig.engine.status.monitorSource, .headphones)
        await measure()
        assertHeadphonesBus("状态 headphones")

        // 改 master：耳机出口 = Master（W1-D3 的口径不变）
        let toMaster = await rig.sm.apply(.setMonitorSource(bus: .master))
        XCTAssertTrue(toMaster.applied)
        await rig.run(seconds: 0.2)
        XCTAssertEqual(rig.engine.status.monitorSource, .master)
        await measure()
        XCTAssertFalse(hp.isEmpty)
        XCTAssertNil(Self.sampleDiff(hp, master), "监听 Master：耳机出口逐样本 = Master")

        // 命令改回 headphones（P5 时 reducer 拒收）
        let toHeadphones = await rig.sm.apply(.setMonitorSource(bus: .headphones))
        XCTAssertTrue(toHeadphones.applied, "headphones = 听耳机总线自己，合法")
        await rig.run(seconds: 0.2)
        XCTAssertEqual(rig.engine.status.monitorSource, .headphones)
        await measure()
        assertHeadphonesBus("命令改回 headphones")

        // 独听优先：独听 2（AFL）→ 耳机出口 = 只有 2，就是 Bus A 那一份；750 Hz 没了
        _ = await rig.sm.apply(.setInputAudio(input: 2, solo: true))
        await rig.run(seconds: 0.2)
        await measure()
        XCTAssertFalse(hp.isEmpty)
        XCTAssertNil(Self.sampleDiff(hp, busA), "独听 2：耳机出口逐样本 = 独听的那一路（= Bus A），monitorSource 不管用")
        XCTAssertLessThan(IT.db(FX.amplitude(hp[...], hz: 750)), -80, "没独听的 3 不进耳机")
        XCTAssertEqual(rig.engine.status.monitorSource, .headphones, "独听不改状态里的监听来源")

        // 关独听：回到耳机总线
        _ = await rig.sm.apply(.setInputAudio(input: 2, solo: false))
        await rig.run(seconds: 0.2)
        await measure()
        assertHeadphonesBus("关独听")
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// 逐样本比（Float ==）：相同 = nil；不同只报个数和第一个不同的位置（整段打出来是几十万字）。
    static func sampleDiff(_ a: [Float], _ b: [Float]) -> String? {
        guard a.count == b.count else { return "长度 \(a.count) ≠ \(b.count)" }
        guard let first = a.indices.first(where: { a[$0] != b[$0] }) else { return nil }
        let n = a.indices.reduce(0) { $0 + (a[$1] != b[$1] ? 1 : 0) }
        return "\(n) / \(a.count) 个样本不同，第一个在 \(first)：\(a[first]) vs \(b[first])"
    }
}
