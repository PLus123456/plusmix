import XCTest
import SwitcherContracts
@testable import SwitcherNDI

/// 抖动缓冲的数学（NDIClockMap）与重采样器：不需要 SDK。
final class NDIClockMapTests: XCTestCase {
    /// 60 fps 发送端：第 k 帧时间戳 k × 166 667（100 ns），本机墙钟 = 时间戳 + 钟差 + 传输 + 抖动。
    private func run(frames: Int, offset100ns: Int64, transit100ns: (Int) -> Int64, map: inout NDIClockMap) -> [Double] {
        var out: [Double] = []
        let t0 = HostClock.now()
        for k in 0..<frames {
            let ts = Int64(k) * 166_667
            let arrivalWall = ts + offset100ns + transit100ns(k)
            // host time 按真实帧间隔推进（块轮换按它算）
            let host = t0 + HostDuration(nanoseconds: Int64(k) * 16_666_700 + transit100ns(k) * 100)
            out.append(map.observe(senderTimestamp100ns: ts, arrivalHost: host, arrivalWall100ns: arrivalWall).milliseconds)
        }
        return out
    }

    func testNDI_clockMap_undefinedTimestampGivesZeroJitter() {
        var m = NDIClockMap()
        let j = m.observe(senderTimestamp100ns: Int64.max, arrivalHost: .now(), arrivalWall100ns: NDIClockMap.wallClock100ns())
        XCTAssertEqual(j, .zero)
        XCTAssertEqual(m.samples, 0)
        XCTAssertNil(m.baseline100ns)
    }

    func testNDI_clockMap_constantTransitIsZeroJitter_lateFrameGetsItsExcess() {
        var m = NDIClockMap()
        let j = run(frames: 120, offset100ns: 0, transit100ns: { k in k == 50 ? 5_000 + 30_000 : 5_000 }, map: &m)
        for (k, v) in j.enumerated() where k != 50 { XCTAssertEqual(v, 0, accuracy: 1e-9, "帧 \(k)") }
        XCTAssertEqual(j[50], 3.0, accuracy: 1e-6, "晚到 3 ms 的帧抖动 = 3 ms")
        XCTAssertEqual(m.maxJitterMs, 3.0, accuracy: 1e-6)
        XCTAssertEqual(m.resets, 0)
        XCTAssertEqual(m.baseline100ns, 5_000, "基线 = 传输时间（钟差 0）")
    }

    func testNDI_clockMap_clockOffsetIrrelevant() {
        // 发送端的钟快 2 小时
        var m = NDIClockMap()
        let j = run(frames: 120, offset100ns: -72_000_000_000, transit100ns: { k in k == 7 ? 12_000 : 2_000 }, map: &m)
        XCTAssertEqual(j[7], 1.0, accuracy: 1e-6)
        XCTAssertEqual(j.filter { $0 == 0 }.count, 119)
        XCTAssertEqual(m.resets, 0)
    }

    func testNDI_clockMap_baselineFollowsPermanentRise_within2Blocks() {
        // 第 120 帧起传输时间永久多 10 ms：之后最多 2 个块（2 s = 120 帧）内抖动回到 0
        var m = NDIClockMap()
        let j = run(frames: 400, offset100ns: 0, transit100ns: { k in k < 120 ? 5_000 : 105_000 }, map: &m)
        XCTAssertEqual(j[120], 10.0, accuracy: 1e-6, "跳变那帧抖动 = 10 ms")
        let recovered = j.enumerated().first { $0.offset > 120 && $0.element == 0 }?.offset
        XCTAssertNotNil(recovered)
        XCTAssertLessThanOrEqual(recovered ?? .max, 120 + 121, "基线 ≤ 2 s 内跟上")
        for v in j[300...] { XCTAssertEqual(v, 0, accuracy: 1e-9) }
        XCTAssertEqual(m.resets, 0, "10 ms 不算钟跳变")
    }

    func testNDI_clockMap_fasterFrameBecomesNewBaselineImmediately() {
        var m = NDIClockMap()
        let j = run(frames: 60, offset100ns: 0, transit100ns: { k in k == 30 ? 1_000 : 5_000 }, map: &m)
        XCTAssertEqual(j[30], 0, "更快到的帧抖动 0")
        XCTAssertEqual(j[31], 0.4, accuracy: 1e-6, "之后正常帧相对新基线多 0.4 ms")
    }

    func testNDI_clockMap_jumpResetsBaseline() {
        var m = NDIClockMap()
        // 发送端对时：从第 60 帧起时间戳整体前跳 5 s（d 突然少 5 s）
        var out: [Double] = []
        let t0 = HostClock.now()
        for k in 0..<120 {
            let ts = Int64(k) * 166_667 + (k >= 60 ? 50_000_000 : 0)
            let wall = Int64(k) * 166_667 + 5_000
            out.append(m.observe(senderTimestamp100ns: ts, arrivalHost: t0 + HostDuration(nanoseconds: Int64(k) * 16_666_700), arrivalWall100ns: wall).milliseconds)
        }
        XCTAssertEqual(m.resets, 1)
        XCTAssertEqual(out[60], 0)
        XCTAssertEqual(out[61], 0)
    }

    func testNDI_resampler_44100to48000_lengthAndContinuity() {
        var r = NDILinearResampler(sourceRate: 44_100, targetRate: 48_000, channels: 2)
        var out: [[Float]] = [[], []]
        var totalIn = 0
        // 1 kHz 正弦，按 441 帧一块喂 100 块（= 1 s）
        let f = 1000.0
        var n = 0
        for _ in 0..<100 {
            var l = [Float](repeating: 0, count: 441), rr = [Float](repeating: 0, count: 441)
            for i in 0..<441 {
                l[i] = Float(sin(2 * .pi * f * Double(n + i) / 44_100))
                rr[i] = -l[i]
            }
            n += 441
            totalIn += 441
            l.withUnsafeBufferPointer { lp in
                rr.withUnsafeBufferPointer { rp in
                    r.process(input: [lp.baseAddress!, rp.baseAddress!], frames: 441, into: &out)
                }
            }
        }
        // 1 s 的 44.1k → 48k：48000 ± 1 帧
        XCTAssertEqual(out[0].count, 48_000, accuracy: 1)
        XCTAssertEqual(out[1].count, out[0].count)
        // 输出应是 1 kHz 正弦（采样 48k）：与理想值比，最大误差 < 0.02（线性插值 1 kHz @ 44.1k 的误差量级）
        var maxErr: Float = 0
        for (i, v) in out[0].enumerated() where i > 2 {
            let ideal = Float(sin(2 * .pi * f * Double(i) / 48_000))
            maxErr = max(maxErr, abs(v - ideal))
            XCTAssertEqual(out[1][i], -v)
        }
        XCTAssertLessThan(maxErr, 0.02, "块边界连续、相位不跳")
    }

    func testNDI_resampler_sameRatePassesThroughExactly() {
        var r = NDILinearResampler(sourceRate: 48_000, targetRate: 48_000, channels: 1)
        var out: [[Float]] = [[]]
        let a: [Float] = (0..<256).map { Float($0) }
        a.withUnsafeBufferPointer { p in r.process(input: [p.baseAddress!], frames: 256, into: &out) }
        a.withUnsafeBufferPointer { p in r.process(input: [p.baseAddress!], frames: 256, into: &out) }
        // 线性插值器固有 1 个样本的延迟：每块的最后一个样本要等下一块到了才能出（它可能要与下一块首样本插值），
        // 所以两块 256 出 511 个，内容 = 原序列的前 511 个。同速率在 NDIInput 里根本不经过它（直接写环），这里只钉住语义。
        XCTAssertEqual(out[0].count, 511)
        XCTAssertEqual(Array(out[0][0..<256]), a)
        XCTAssertEqual(Array(out[0][256..<511]), Array(a[0..<255]))
    }
}
