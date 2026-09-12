import XCTest
@testable import SwitcherContracts

/// 时间契约：拍点时间必须是整数运算（设计方案 §3.1），浮点累加有误差。
final class TimeTests: XCTestCase {
    private let appleSiliconTimebase = MachTimebase(numer: 125, denom: 3)   // 24 MHz
    private let nanosecondTimebase = MachTimebase(numer: 1, denom: 1)       // Intel
    private let oddTimebase = MachTimebase(numer: 7, denom: 11)             // 故意选个整除不了的

    /// 59.94 fps，第 216000 拍（1 小时）的 time(of:) 与有理数精确值一致，误差 0。
    /// 精确值手算：216000 × 1001 / 60000 s = 3603.6 s = 3 603 600 000 000 ns。
    func testP1_tickTime_5994_tick216000_isExact() {
        let exactNs: Int128 = 3_603_600_000_000
        for tb in [appleSiliconTimebase, nanosecondTimebase, HostClock.timebase] {
            let t0 = HostTime(ticks: 123_456_789)
            let spec = TickClockSpec(t0: t0, frameRate: .fps5994)
            let got = Int128(spec.time(of: Tick(216_000), timebase: tb).ticks) - Int128(t0.ticks)
            // 精确 host tick 数 = ns × denom / numer；对 125/3 和 1/1 都能整除
            let exactTicks = exactNs * Int128(tb.denom) / Int128(tb.numer)
            XCTAssertEqual(got, exactTicks, "时基 \(tb.numer)/\(tb.denom) 下误差不为 0")
        }
        // Apple Silicon 24 MHz 时基下就是 86 486 400 000 个 tick（400400 × 216000）
        XCTAssertEqual(TickClockSpec(t0: .zero, frameRate: .fps5994).time(of: Tick(216_000), timebase: appleSiliconTimebase).ticks,
                       86_486_400_000)
        // 8 小时也精确
        let eightHoursNs: Int128 = 3_603_600_000_000 * 8
        XCTAssertEqual(Int128(TickClockSpec(t0: .zero, frameRate: .fps5994).time(of: Tick(216_000 * 8), timebase: nanosecondTimebase).ticks),
                       eightHoursNs)
    }

    /// 同样的量用浮点累加，证明它有误差（所以拍点数学不许用浮点累加）。
    func testP1_tickTime_floatAccumulationDrifts() {
        var oneHour = 0.0
        for _ in 0..<216_000 { oneHour += 1001.0 / 60000.0 }
        XCTAssertNotEqual(oneHour, 3603.6, "浮点累加 1 小时后应与精确值不同")
        var eightHours = 0.0
        for _ in 0..<(216_000 * 8) { eightHours += 1001.0 / 60000.0 }
        XCTAssertNotEqual(eightHours, 3603.6 * 8)
        let errUs1h = (oneHour - 3603.6) * 1e6
        let errUs8h = (eightHours - 3603.6 * 8) * 1e6
        print("浮点累加误差：1 h = \(errUs1h) µs，8 h = \(errUs8h) µs；整数路径误差 = 0")
        XCTAssertNotEqual(errUs1h, 0)
        XCTAssertNotEqual(errUs8h, 0)
    }

    /// 30 / 60 fps 的整数拍点也精确；59.94 相邻两拍的间隔只可能是 floor(T) 或 ceil(T)。
    func testP1_tickTime_intervalsNeverAccumulate() {
        for tb in [appleSiliconTimebase, nanosecondTimebase, oddTimebase] {
            for rate in [FrameRate.fps30, .fps5994, .fps60, .fps2997, .fps25] {
                let spec = TickClockSpec(t0: HostTime(ticks: 1_000), frameRate: rate)
                let d = rate.frameDuration
                // 每拍 host tick 数的精确有理数 = p × 1e9 × denom / (q × numer)
                let num = Int128(d.numerator) * 1_000_000_000 * Int128(tb.denom)
                let den = Int128(d.denominator) * Int128(tb.numer)
                let floorT = num / den
                let ceilT = (num % den == 0) ? floorT : floorT + 1
                var prev = spec.time(of: .zero, timebase: tb)
                XCTAssertEqual(prev, spec.t0)
                for n in 1...20_000 {
                    let t = spec.time(of: Tick(Int64(n)), timebase: tb)
                    let delta = Int128(t.ticks) - Int128(prev.ticks)
                    XCTAssertTrue(delta == floorT || delta == ceilT, "\(rate) 第 \(n) 拍间隔 \(delta) 不在 {\(floorT), \(ceilT)}")
                    prev = t
                }
                // 第 n 拍的绝对值 = floor(n × 精确值)，不是 n 个 floor(T) 之和
                let n: Int128 = 20_000
                XCTAssertEqual(Int128(prev.ticks) - 1_000, n * num / den)
            }
        }
    }

    /// tick(at:) 是 time(of:) 的逆：返回最大的 n 使 time(of: n) ≤ t。
    func testP1_tickTime_tickAt_isExactInverse() {
        var rng = SystemRandomNumberGenerator()
        for tb in [appleSiliconTimebase, nanosecondTimebase, oddTimebase] {
            for rate in [FrameRate.fps30, .fps5994, .fps60, .fps2997] {
                let spec = TickClockSpec(t0: HostTime(ticks: 5_000_000), frameRate: rate)
                for _ in 0..<2_000 {
                    let n = Int64.random(in: 0...2_000_000, using: &rng)
                    let t = spec.time(of: Tick(n), timebase: tb)
                    XCTAssertEqual(spec.tick(at: t, timebase: tb), Tick(n))
                    let next = spec.time(of: Tick(n + 1), timebase: tb)
                    XCTAssertEqual(spec.tick(at: next - HostDuration(ticks: 1), timebase: tb), Tick(n), "下一拍前 1 个 host tick 仍属于第 n 拍")
                    if n > 0 {
                        XCTAssertEqual(spec.tick(at: t - HostDuration(ticks: 1), timebase: tb), Tick(n - 1))
                    }
                }
                // t0 之前是负拍
                XCTAssertEqual(spec.tick(at: spec.t0 - HostDuration(ticks: 1), timebase: tb), Tick(-1))
            }
        }
    }

    func testP1_hostTime_conversionsUseTimebase() {
        let tb = appleSiliconTimebase
        let t = HostTime(nanoseconds: 1_000_000_000, timebase: tb)
        XCTAssertEqual(t.ticks, 24_000_000)
        XCTAssertEqual(t.nanoseconds(timebase: tb), 1_000_000_000)
        let d = HostDuration(nanoseconds: 16_683_333, timebase: tb)
        XCTAssertEqual(d.ticks, 400_399)   // floor(16683333 × 3 / 125)
        XCTAssertEqual(HostDuration(milliseconds: 1, timebase: tb).ticks, 24_000)
        XCTAssertEqual(HostDuration(ticks: 24_000).milliseconds(timebase: tb), 1, accuracy: 1e-12)
        let a = HostTime(ticks: 100), b = HostTime(ticks: 130)
        XCTAssertEqual(b - a, HostDuration(ticks: 30))
        XCTAssertEqual(a - b, HostDuration(ticks: -30))
        XCTAssertEqual(a + HostDuration(ticks: 30), b)
        XCTAssertEqual(b - HostDuration(ticks: 30), a)
        XCTAssertTrue(a < b)
        XCTAssertGreaterThan(HostTime.now().ticks, 0)
        XCTAssertTrue(HostClock.timebase.numer > 0 && HostClock.timebase.denom > 0)
    }

    func testP1_rational_reducesAndCompares() {
        XCTAssertEqual(Rational(120_000, 2_002), Rational(60_000, 1_001))
        XCTAssertEqual(Rational(-1, -2), Rational(1, 2))
        XCTAssertEqual(Rational(1, -2).numerator, -1)
        XCTAssertEqual(Rational(1, -2).denominator, 2)
        XCTAssertTrue(Rational(1, 3) < Rational(1, 2))
        XCTAssertTrue(Rational(1001, 60000) < Rational(1, 30))
        XCTAssertEqual(Rational(60_000, 1_001).reciprocal, Rational(1_001, 60_000))
        XCTAssertEqual(Rational(60_000, 1_001) * Rational(1_001, 60_000), .one)
        XCTAssertEqual(Rational(1, 3) + Rational(1, 6), Rational(1, 2))
        XCTAssertEqual(Rational(1, 2) - Rational(1, 3), Rational(1, 6))
        XCTAssertEqual(Rational(1001, 60000).scaled(by: 60), Rational(1001, 1000))
        // 大数相乘走 128 位不溢出
        let big = Rational(Int64.max / 2, 3)
        XCTAssertEqual(big * Rational(3, Int64.max / 2), .one)
        XCTAssertEqual(Rational(3, 1).doubleValue, 3)
        XCTAssertTrue(Rational(4, 2).isInteger)
    }

    func testP1_frameRate_presets() {
        XCTAssertEqual(FrameRate.fps5994.framesPerSecond, Rational(60_000, 1_001))
        XCTAssertEqual(FrameRate.fps5994.frameDuration, Rational(1_001, 60_000))
        XCTAssertEqual(FrameRate.fps5994.nominalFramesPerSecond, 60)
        XCTAssertEqual(FrameRate.fps2997.nominalFramesPerSecond, 30)
        XCTAssertEqual(FrameRate.fps30.frameDuration, Rational(1, 30))
        XCTAssertEqual(FrameRate.fps60.frameDuration, Rational(1, 60))
        XCTAssertTrue(FrameRate.fps5994.isFractional)
        XCTAssertFalse(FrameRate.fps60.isFractional)
        XCTAssertEqual(FrameRate.standard, [.fps30, .fps5994, .fps60])
        XCTAssertEqual(TickClockSpec(t0: .zero, frameRate: .fps5994).frameRate, .fps5994)
    }

    func testP1_time_codableShapes() throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        struct Box: Codable, Equatable { var tick: Tick; var t: HostTime; var d: HostDuration; var r: Rational; var f: FrameRate; var spec: TickClockSpec }
        let box = Box(tick: Tick(42), t: HostTime(ticks: 7), d: HostDuration(ticks: -3), r: Rational(1001, 60000), f: .fps5994,
                      spec: TickClockSpec(t0: HostTime(ticks: 9), frameRate: .fps60))
        let json = String(data: try enc.encode(box), encoding: .utf8)!
        XCTAssertEqual(json, #"{"d":-3,"f":{"denominator":1001,"numerator":60000},"r":{"denominator":60000,"numerator":1001},"spec":{"frameDuration":{"denominator":60,"numerator":1},"t0":9},"t":7,"tick":42}"#)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: json.data(using: .utf8)!), box)
        // 分母为 0 或负数的 JSON 不接受 / 会规范化
        XCTAssertThrowsError(try JSONDecoder().decode(Rational.self, from: #"{"numerator":1,"denominator":0}"#.data(using: .utf8)!))
        XCTAssertEqual(try JSONDecoder().decode(Rational.self, from: #"{"numerator":2,"denominator":-4}"#.data(using: .utf8)!), Rational(-1, 2))
    }

    func testP1_tick_arithmetic() {
        let t = Tick(10)
        XCTAssertEqual(t + 5, Tick(15))
        XCTAssertEqual(t - 5, Tick(5))
        XCTAssertEqual(Tick(15) - t, 5)
        XCTAssertEqual(t.advanced(by: 3), Tick(13))
        XCTAssertEqual(t.distance(to: Tick(13)), 3)
        XCTAssertEqual(Array(Tick(0)..<Tick(3)), [Tick(0), Tick(1), Tick(2)])
        XCTAssertTrue(Tick(-1) < .zero)
    }
}
