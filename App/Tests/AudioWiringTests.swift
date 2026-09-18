// W2-B2 接缝 4：AudioEngine（W2-E）。起停 20 次不崩不漏（RSS 平）；Master 表有读数（Stats.audio.meters，提案 004）；FTB 时 Master 落到 −∞。
// 测试宿主用空设备（AppController：SWITCHER_TEST_AUDIO=default 可改成真设备）。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class AudioWiringTests: XCTestCase {
    /// 每次新建节目 = 一套新的引擎 + 音频引擎（旧的先停）：20 轮不崩；RSS 热身 5 轮后的增长 < 40 MB。
    func testAudio_engineStartStop20TimesNoCrashRSSFlat() throws {
        var rss: [Double] = []
        for i in 1...20 {
            let session = try AppTest.freshSession()
            session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
            XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live, "第 \(i) 轮")
            XCTAssertTrue(session.audio.engine.isRunning, "第 \(i) 轮音频引擎应在跑")
            XCTAssertEqual(session.audio.registeredInputs, [1])
            AppTest.pump(seconds: 0.4)
            rss.append(AppTest.residentMB())
        }
        let text = rss.map { String(format: "%.0f", $0) }.joined(separator: " ")
        print("音频引擎起停 20 轮 RSS（MB）：\(text)")
        let growth = rss[19] - rss[4]
        XCTAssertLessThan(growth, 40, "热身后 15 轮 RSS 增长应 < 40 MB，实际 \(String(format: "%.1f", growth)) MB：\(text)")
        XCTAssertEqual(AppTest.controller.session?.audio.engine.status.counters.dropouts, 0)
    }

    /// 合成源带音频（1 kHz −20 dBFS）→ Stats 里 Master 峰值 ≈ −20 dBFS、调音台有读数；FTB 开 → Master 落到 −∞（−120 下限）；关 → 回来。
    func testAudio_masterMeterReadsAndFTBDropsToSilence() throws {
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        func masterPeak() -> Double? { session.stats?.audio.meters.buses.first { $0.bus == Bus.master.name }?.peakDb.max() }
        var peak: Double?
        XCTAssertTrue(AppTest.waitUntil(6) { peak = masterPeak(); return (peak ?? -200) > -40 }, "Master 应有读数（≈ −20 dBFS），实际 \(String(describing: peak))")
        XCTAssertEqual(peak ?? 0, -20, accuracy: 3, "1 kHz −20 dBFS 的峰值")
        XCTAssertTrue(AppTest.waitUntil(2) { wc.mixerPanel.displayedPeak != "−∞ dBFS" }, "调音台读数：\(wc.mixerPanel.displayedPeak)")
        XCTAssertTrue(AppTest.waitUntil(2) { wc.mixerPanel.meter.level != nil }, "表的条子（AudioEngineStatus，50 ms）应有电平")
        let status = session.audio.status
        print("Master 峰值 \(peak!) dBFS；调音台 \(wc.mixerPanel.displayedPeak)；status Master \(status.buses.first { $0.bus == .master }?.peakDb ?? [])；输入对齐 \(status.inputs.map { "\($0.number): primed \($0.primed) aligned \($0.aligned) 年龄 \($0.ageSetpointFrames) 帧" })；设备 \(status.device.kind) \(status.device.name)")

        session.send(.ftb(on: true))
        XCTAssertTrue(AppTest.waitUntil(4) { (masterPeak() ?? 0) <= -119 }, "FTB 后 Master 应落到 −∞：\(String(describing: masterPeak()))")
        XCTAssertTrue(AppTest.waitUntil(2) { wc.mixerPanel.displayedPeak == "−∞ dBFS" }, "调音台应显示 −∞：\(wc.mixerPanel.displayedPeak)")
        session.send(.ftb(on: false))
        XCTAssertTrue(AppTest.waitUntil(4) { (masterPeak() ?? -200) > -40 }, "FTB 关掉后应回来：\(String(describing: masterPeak()))")
        let a = session.stats!.audio
        print("A1：dropouts \(a.dropouts) underruns \(a.underruns) discontinuities \(a.discontinuities)")
        XCTAssertEqual(a.dropouts, 0)
    }
}
