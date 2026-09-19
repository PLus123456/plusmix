import XCTest
import CSwitcherDeckLink
@testable import SwitcherDeckLink

/// 硬件参考钟 ↔ host time 的一阶滤波校准器：纯数学，SDK 不在也跑。
final class DeckLinkCalibratorTests: XCTestCase {
    func testDeckLink_calibrator_firstSampleAdopted_thenFirstOrderFilter() {
        var c = sw_decklink_calibrator()
        sw_decklink_calibrator_init(&c, 5)
        XCTAssertEqual(sw_decklink_calibrator_observe(&c, 1_000_000_000, 0), 0, "第一个样本直接采用，残差 0")
        XCTAssertEqual(c.offset_ns, 1_000_000_000)
        // 第二个样本 o_k 比 o 多 32 000 ns → 残差 32 000，o 涨 1/32 = 1 000
        XCTAssertEqual(sw_decklink_calibrator_observe(&c, 2_000_032_000, 1_000_000_000), 32_000)
        XCTAssertEqual(c.offset_ns, 1_000_001_000)
        XCTAssertEqual(sw_decklink_calibrator_map(&c, 500_000_000), 1_500_001_000)
        XCTAssertEqual(c.max_abs_residual_ns, 32_000)
        XCTAssertEqual(c.samples, 2)
        // 负残差对称
        XCTAssertEqual(sw_decklink_calibrator_observe(&c, 3_000_000_000 - 31_000, 2_000_000_000), -32_000)
        XCTAssertEqual(c.offset_ns, 1_000_000_000)
    }

    func testDeckLink_calibrator_stepConvergesWithin5TimeConstants() {
        var c = sw_decklink_calibrator()
        sw_decklink_calibrator_init(&c, 5)   // τ = 32 样本
        sw_decklink_calibrator_observe(&c, 0, 0)
        // 之后 o_k 恒为 1 ms
        for k in 1...160 { sw_decklink_calibrator_observe(&c, Int64(k) * 16_666_667 + 1_000_000, Int64(k) * 16_666_667) }
        XCTAssertLessThan(abs(c.offset_ns - 1_000_000), 10_000, "5τ 后离目标 < 10 µs（e⁻⁵ ≈ 0.7%）")
        XCTAssertEqual(c.max_abs_residual_ns, 1_000_000, "最大残差就是那一步")
    }

    func testDeckLink_calibrator_uniformJitterAveragedOut() {
        var c = sw_decklink_calibrator()
        sw_decklink_calibrator_init(&c, 5)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int64 {   // 均匀 ±20 µs
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int64((seed >> 33) % 40_001) - 20_000
        }
        let truth: Int64 = 123_456_789_000
        for k in 0..<2000 {
            let hw = Int64(k) * 16_666_667
            sw_decklink_calibrator_observe(&c, hw + truth + next(), hw)
        }
        XCTAssertLessThan(abs(c.offset_ns - truth), 6_000, "±20 µs 均匀抖动经 1/32 低通后偏差 < 6 µs（3σ ≈ 4.5 µs）")
        let rms = sw_decklink_calibrator_residual_rms(&c)
        XCTAssertGreaterThan(rms, 9_000, "残差 RMS ≈ 均匀分布的 σ = 20 µs / √3 ≈ 11.5 µs")
        XCTAssertLessThan(rms, 14_000)
        XCTAssertLessThanOrEqual(c.max_abs_residual_ns, 40_000, "|o_k − o| ≤ |o_k − 真值| + |o − 真值| ≤ 20 + 20 µs（第一个样本直接采用，o 起点可偏 20 µs）")
    }

    func testDeckLink_info_sdkFlagsConsistent() {
        XCTAssertEqual(SwitcherDeckLinkInfo.isSDKAvailable, sw_decklink_sdk_compiled() != 0)
        if SwitcherDeckLinkInfo.isSDKAvailable {
            XCTAssertFalse(SwitcherDeckLinkInfo.sdkVersion.isEmpty)
            print("DeckLink SDK 头版本 \(SwitcherDeckLinkInfo.sdkVersion)，驱动在：\(SwitcherDeckLinkInfo.isDriverPresent)，驱动版本 \(SwitcherDeckLinkInfo.driverVersion)")
        } else {
            XCTAssertEqual(SwitcherDeckLinkInfo.sdkVersion, "")
            XCTAssertFalse(SwitcherDeckLinkInfo.isDriverPresent)
        }
    }
}
