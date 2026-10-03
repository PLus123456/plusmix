// 多画面的纯音频格与真实电平表（W3-B2 交付 1 / 2）。
// - 纯音频输入（`InputConfig.kind == .audio`，W2-A2）的格子：深灰底（不是黑）+ 名字 + 电平表；电平表对它总是画，不看 meters 开关。
// - 电平表的数：组装方把 `Stats.audio.meters`（提案 004）经 `setMeters` 递给渲染器 → 三块定长缓冲 → 渲染线程零分配地读。
//   峰值保持 1 s（写端按喂数时刻算），−60…0 dBFS，分段：< −18 绿、−18…−6 黄、≥ −6 红；没数据的输入格退回占位（暗条 + 四道刻度）。
import CoreGraphics
import Darwin
import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class MultiviewMetersTests: XCTestCase {
    static let width = 1920, height = 1080
    typealias RGBA = (r: Int, g: Int, b: Int, a: Int)

    var renderer: OfflineRenderer { V8ReferenceTests.renderer }

    /// 多画面离线渲染；meters 按顺序喂完再渲染，渲染完清掉（共用的渲染器不留状态）。
    func renderMultiview(_ state: MixerState, meters: [V8ReferenceTests.MeterFeedCall] = []) throws -> Bitmap {
        for c in meters { renderer.setMeters(c.meters, at: c.at) }
        defer { renderer.setMeters(nil) }
        return Bitmap(try renderer.renderOffline(state: state, inputs: V8ReferenceTests.inputs,
                                                 size: CGSize(width: Self.width, height: Self.height), target: .multiview))
    }

    /// 渲染器同一份算式解析出的格子（像素）：规格 + 内框。
    func cells(_ state: MixerState) -> [(spec: MultiviewCellSpec, inner: PixelRect)] {
        let t = MultiviewLayoutTable()
        t.parse(state: state, width: Self.width, height: Self.height)
        return (0..<t.cellCount).map { (t.cells[$0], t.cells[$0].rect.insetBy(t.border)) }
    }

    /// 与参考图比：PSNR ≥ 40 dB 或 SSIM ≥ 0.98，与 `V8ReferenceTests.compare` 同一套判法。只读，不会在生成模式下改写参考图。
    /// 原来是逐字节相等（"PSNR ∞"）：2026-10-01 起系统字体资源变了一次，名字标签差几个像素（PSNR ≈ 51 dB）就红，与渲染逻辑无关
    /// （reports/issues/W5E-w3-compositor-3-multiview-meters-strict-reference-drift.md）；用户 2026-10-03 定改成 PSNR 判法，G6 改。
    func assertEqualsReference(_ name: String, _ bm: Bitmap, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = RepoPaths.references.appendingPathComponent("\(name).png")
        guard let ref = PNG.read(url) else { throw XCTSkip("没有参考图 \(url.path)") }
        let refBitmap = Bitmap(ref)
        let psnr = ImageMetrics.psnr(bm, refBitmap), ssim = ImageMetrics.ssim(bm, refBitmap)
        XCTAssertTrue(psnr >= V8ReferenceTests.psnrThreshold || ssim >= V8ReferenceTests.ssimThreshold,
                      "应与 \(name).png 一致：PSNR \(psnr.isInfinite ? "∞" : String(format: "%.2f", psnr)) dB / SSIM \(String(format: "%.4f", ssim))（≥ 40 dB 或 ≥ 0.98）",
                      file: file, line: line)
    }

    /// 电平表里一个取样点：channel 0 = L、1 = R；fraction = 从表下端往上的比例（0 = −60 dBFS，1 = 0 dBFS）。
    /// 几何按报告写的口径：条收进暗条 1 px，两个声道各占一半、中间 1 px 缝。
    static func meterPoint(_ strip: PixelRect, channel: Int, fraction: Float) -> (x: Int, y: Int) {
        let areaX = strip.x + 1, areaW = strip.width - 2
        let areaY = strip.y + 1, areaH = strip.height - 2
        let gap: Float = areaW >= 5 ? 1 : 0
        let bw = (areaW - gap) / 2
        let x = channel == 0 ? areaX + bw / 2 : areaX + bw + gap + bw / 2
        return (Int(x), Int(areaY + areaH * (1 - fraction)))
    }

    static func isGreen(_ p: RGBA) -> Bool { p.g > 150 && p.r < 90 && p.b < 110 }
    static func isYellow(_ p: RGBA) -> Bool { p.r > 200 && p.g > 150 && p.b < 60 }
    static func isRed(_ p: RGBA) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }

    // MARK: - 纯音频格

    /// 含一路纯音频输入的 3×3：该格深灰底 + 名字 + 电平表（meters 关也画），不画输入表里给它的帧；参考图 PSNR ∞。
    func testV8_multiviewAudioOnlyCellPlaceholder() throws {
        let s = ReferenceStates.audioOnly3x3()
        XCTAssertEqual(MultiviewLayout.layoutSettings(in: s)?.meters, false, "这张图 meters 关：只有纯音频格该有电平表")
        try V8ReferenceTests.compare("v8-multiview-audio-only-3x3", state: s, target: .multiview)
        let mv = try renderMultiview(s)
        let cs = cells(s)

        // 1. 格子表只把输入 6 标成纯音频
        let audio = cs.filter { $0.spec.audioOnly }
        XCTAssertEqual(audio.map { Int($0.spec.input) }, [ReferenceStates.audioOnlyNumber])
        let inner = try XCTUnwrap(audio.first).inner

        // 2. 深灰底（0.15 → 38），不是黑；输入表里给了输入 6 帧（stinger 图，中心是橙色斜带），纯音频格不画它
        for (fx, fy) in [(0.3, 0.3), (0.5, 0.5), (0.7, 0.4)] as [(Float, Float)] {
            let p = mv.pixel(Int(inner.x + inner.width * fx), Int(inner.y + inner.height * fy))
            XCTAssertTrue(abs(p.r - 38) <= 1 && abs(p.g - 38) <= 1 && abs(p.b - 38) <= 1, "纯音频格应是深灰底 38，(\(fx), \(fy)) 得 \(p)")
        }

        // 3. 电平表（没有读数 = 占位）：暗条 = 深灰的 30%，刻度比暗条亮得多
        let strip = CompositorPasses.meterStrip(inner)
        let sx = Int(strip.x + strip.width / 2)
        let body = mv.pixel(sx, Int(strip.y + strip.height * 0.5))
        XCTAssertLessThan(body.r + body.g + body.b, 3 * 16, "暗条（70% 黑盖在深灰上）应接近 11，得 \(body)")
        let tickRows = (Int(strip.y + strip.height * 0.2) - 2)...(Int(strip.y + strip.height * 0.2) + 2)
        let brightest = tickRows.map { mv.pixel(sx, $0).g }.max() ?? 0
        XCTAssertGreaterThan(brightest, 100, "1/5 处应有刻度线")

        // 4. 名字：左下角 55% 黑的标签条（38 × 0.45 ≈ 17）+ 白字
        let lh: Float = 38   // 格高 × 14% 与画面高 × 3.5% 取小（drawCellLabel 的算式）
        let labelY = Int(inner.y + inner.height - lh / 2)
        let bar = mv.pixel(Int(inner.x) + 3, labelY)
        XCTAssertTrue(abs(bar.g - 17) <= 2, "标签条左端（文字前的留边）应是 55% 黑盖深灰 ≈ 17，得 \(bar)")
        let row = (Int(inner.x) + 8)..<(Int(inner.x) + 220)
        XCTAssertGreaterThan(row.map { mv.pixel($0, labelY).g }.max() ?? 0, 200, "标签条里应有白字")

        // 5. 别的输入格 meters 关：同一位置没有暗条（输入 7 = 青底，右侧仍是青）
        let cell7 = try XCTUnwrap(cs.first { $0.spec.kind == .input && $0.spec.input == 7 }).inner
        let strip7 = CompositorPasses.meterStrip(cell7)
        let c7 = mv.pixel(Int(strip7.x + strip7.width / 2), Int(strip7.y + strip7.height * 0.5))
        XCTAssertTrue(c7.g > 150 && c7.b > 170, "meters 关时普通输入格不画电平表，得 \(c7)")

        // 6. meters 开：普通输入格多出暗条，纯音频格那一块逐像素不变
        let on = try renderMultiview(ReferenceStates.audioOnly3x3(meters: true))
        let c7on = on.pixel(Int(strip7.x + strip7.width / 2), Int(strip7.y + strip7.height * 0.5))
        XCTAssertLessThan(c7on.g, 100, "meters 开时输入 7 格右侧应是暗条，得 \(c7on)")
        for y in stride(from: Int(inner.y), to: Int(inner.y + inner.height), by: 7) {
            for x in stride(from: Int(inner.x), to: Int(inner.x + inner.width), by: 7) {
                if mv.pixel(x, y) != on.pixel(x, y) { return XCTFail("纯音频格不该受 meters 开关影响：(\(x), \(y)) \(mv.pixel(x, y)) → \(on.pixel(x, y))") }
            }
        }

        // 7. 给了读数：纯音频格的表画真实电平（−10 dBFS → 表高 5/6，中段是绿、上段黄）
        let fed = try renderMultiview(s, meters: [.init(meters: ReferenceStates.meters(inputs: [6: [-10, -10]], master: nil), at: ReferenceStates.meterT0)])
        XCTAssertTrue(Self.isGreen(fed.pixel(Self.meterPoint(strip, channel: 0, fraction: 0.5).x, Self.meterPoint(strip, channel: 0, fraction: 0.5).y)))
        let top = Self.meterPoint(strip, channel: 1, fraction: 0.78)
        XCTAssertTrue(Self.isYellow(fed.pixel(top.x, top.y)), "−10 dBFS 的条在 0.7–0.83 之间是黄，得 \(fed.pixel(top.x, top.y))")
    }

    /// 格子表里的纯音频标记跟快照走：只标输入格，PGM / PVW 格即使切到纯音频输入也不算；换回有画面的来源标记就没了。
    func testMultiview_audioOnlyFlagsFollowSnapshot() {
        let table = MultiviewLayoutTable()
        func flagged(_ s: MixerState) -> [Int] {
            table.parse(state: s, width: 1920, height: 1080)
            return (0..<table.cellCount).filter { table.cells[$0].audioOnly }.map { Int(table.cells[$0].input) }
        }
        var s = ReferenceStates.audioOnly3x3()
        XCTAssertEqual(flagged(s), [6])
        s.program = 6
        s.preview = 6
        XCTAssertEqual(flagged(s), [6], "PGM / PVW 格画的是合成结果，不算纯音频格")
        s.inputs[5].source = .camera(uniqueID: "cam")
        XCTAssertEqual(flagged(s), [], "来源换成摄像头后不再是纯音频格")
        // 两路纯音频、默认布局
        var two = ReferenceStates.fixed8()
        two.inputs[1].source = .audio(deviceUID: "")
        two.inputs[7].source = .audio(deviceUID: "x", channels: [2, 3])
        XCTAssertEqual(flagged(two), [2, 8])
    }

    // MARK: - 真实电平表

    /// 刻度与分段：−60…0 dBFS 线性映射到表高，< −18 绿、−18…−6 黄、≥ −6 红；超出范围钳到两端。
    func testMultiview_meterScaleAndColorSegments() {
        XCTAssertEqual(MeterScale.fraction(-60), 0)
        XCTAssertEqual(MeterScale.fraction(0), 1)
        XCTAssertEqual(MeterScale.fraction(-120), 0, "Stats 的下限 −120 在表的最下端")
        XCTAssertEqual(MeterScale.fraction(3), 1, "过载钳到顶")
        XCTAssertEqual(MeterScale.fraction(-30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(MeterScale.fraction(-18), 0.7, accuracy: 1e-6)
        XCTAssertEqual(MeterScale.fraction(-6), 0.9, accuracy: 1e-6)
        func color(_ db: Float) -> SIMD4<Float> { CompositorPasses.meterColor(forFraction: MeterScale.fraction(db)) }
        XCTAssertEqual(color(-59), CompositorPasses.meterGreen)
        XCTAssertEqual(color(-18.1), CompositorPasses.meterGreen)
        XCTAssertEqual(color(-18), CompositorPasses.meterYellow)
        XCTAssertEqual(color(-6.1), CompositorPasses.meterYellow)
        XCTAssertEqual(color(-6), CompositorPasses.meterRed)
        XCTAssertEqual(color(0), CompositorPasses.meterRed)
    }

    /// 写端：峰值保持 1 s（左右声道各算各的）、单声道 / 空读数、Master、容量 64、清掉、过期、连写只取最新。
    func testMultiview_meterFeedHoldCapacityClearAndStaleness() throws {
        let feed = MultiviewMeterFeed()
        let t0 = ReferenceStates.meterT0
        func ms(_ v: Double) -> HostDuration { HostDuration(milliseconds: v) }
        func m(_ inputs: [Int: [Double]], master: [Double]? = nil) -> Stats.AudioCounters.Meters { ReferenceStates.meters(inputs: inputs, master: master) }
        XCTAssertNil(feed.acquire(now: nil), "没喂过 → 没有表（多画面画占位）")

        // 1. 基本：输入 3 的 [L, R]、Master
        feed.write(m([3: [-10, -20]], master: [-6, -7]), at: t0)
        var t = try XCTUnwrap(feed.acquire(now: nil))
        XCTAssertEqual(t.levels(forInput: 3), SIMD4<Float>(-10, -20, -10, -20))
        XCTAssertNil(t.levels(forInput: 4))
        XCTAssertNil(t.levels(forInput: 0))
        XCTAssertEqual(t.programLevels, SIMD4<Float>(-6, -7, -6, -7))

        // 2. 0.5 s 后 L 回落、R 升高：L 的保持不动（没到 1 s），R 的保持跟上新峰值
        feed.write(m([3: [-30, -5]]), at: t0 + ms(500))
        t = try XCTUnwrap(feed.acquire(now: nil))
        XCTAssertEqual(t.levels(forInput: 3), SIMD4<Float>(-30, -5, -10, -5))
        XCTAssertNil(t.programLevels, "这次没有 master 总线 → PGM 格没有读数")

        // 3. t0 + 1.2 s：L 的保持（t0 定的）到期回到当前值；R 的保持（t0 + 0.5 s 定的）还在
        feed.write(m([3: [-40, -35]]), at: t0 + ms(1200))
        XCTAssertEqual(feed.acquire(now: nil)?.levels(forInput: 3), SIMD4<Float>(-40, -35, -40, -5))
        // t0 + 1.6 s：R 的也到期回到当前值；L 的保持是 t0 + 1.2 s 新定的（−40），还在
        feed.write(m([3: [-41, -36]]), at: t0 + ms(1600))
        XCTAssertEqual(feed.acquire(now: nil)?.levels(forInput: 3), SIMD4<Float>(-41, -36, -40, -36))

        // 4. 单声道 [x] → 两个声道都是 x；空数组 = 没有这一路；非有限数当下限
        feed.write(m([1: [-12], 2: [], 5: [.nan, -.infinity]]), at: t0 + ms(2000))
        t = try XCTUnwrap(feed.acquire(now: nil))
        XCTAssertEqual(t.levels(forInput: 1), SIMD4<Float>(-12, -12, -12, -12))
        XCTAssertNil(t.levels(forInput: 2))
        XCTAssertEqual(t.levels(forInput: 5), SIMD4<Float>(repeating: -120))
        XCTAssertNil(t.levels(forInput: 3), "这次没给输入 3 → 表里没有它")

        // 5. 容量：80 路只留编号最小的 64 路
        feed.write(m(Dictionary(uniqueKeysWithValues: (1...80).map { ($0, [-Double($0), -Double($0)]) })), at: t0 + ms(2100))
        t = try XCTUnwrap(feed.acquire(now: nil))
        XCTAssertEqual(t.count, MultiviewMeterTable.capacity)
        XCTAssertEqual(t.levels(forInput: 64)?.x, -64)
        XCTAssertNil(t.levels(forInput: 65))

        // 6. 连写三次不读：读端拿到最后那次
        for k in 0..<3 { feed.write(m([7: [-Double(10 + k), -1]]), at: t0 + ms(2200 + Double(k) * 10)) }
        XCTAssertEqual(feed.acquire(now: nil)?.levels(forInput: 7)?.x, -12)

        // 7. 过期：喂数之后超过 3 s 还没新数 → 当没有表（音频停了表不该冻在最后一个值）；now = nil（离线）不判过期
        let fedAt = t0 + ms(2220)
        XCTAssertNotNil(feed.acquire(now: fedAt + ms(2900)))
        XCTAssertNil(feed.acquire(now: fedAt + ms(3100)))
        XCTAssertNotNil(feed.acquire(now: nil))

        // 8. 清掉 → 没有表；再喂 → 保持从头算，不继承清掉之前的
        feed.write(nil, at: t0 + ms(2300))
        XCTAssertNil(feed.acquire(now: nil))
        feed.write(m([7: [-50, -50]]), at: t0 + ms(2400))
        XCTAssertEqual(feed.acquire(now: nil)?.levels(forInput: 7), SIMD4<Float>(-50, -50, -50, -50))
    }

    /// 提案 017：同一组读数再带 RMS（= 峰值 − 9 dB）→ 新参考图 v8-multiview-meters-rms：实心条只到 RMS，峰值变成细线，保持线照旧；
    /// 没有 RMS 的老数据（上一条用例）画法不变、v8-multiview-meters 不重生成。
    func testV8_multiviewMetersWithRMS() throws {
        let s = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout)
        func withRms(_ m: Stats.AudioCounters.Meters?) -> Stats.AudioCounters.Meters? {
            guard var m else { return nil }
            m.inputs = m.inputs.mapValues { Stats.AudioCounters.InputMeter(peakDb: $0.peakDb, rmsDb: $0.peakDb.map { $0 - 9 }) }
            m.buses = m.buses.map { var b = $0; b.rmsDb = b.peakDb.map { $0 - 9 }; return b }
            return m
        }
        let calls = ReferenceStates.referenceMeterCalls.map { V8ReferenceTests.MeterFeedCall(meters: withRms($0.meters), at: $0.at) }
        try V8ReferenceTests.compare("v8-multiview-meters-rms", state: s, target: .multiview, meters: calls)

        let fed = try renderMultiview(s, meters: calls)
        let peakOnly = try renderMultiview(s, meters: ReferenceStates.referenceMeterCalls)
        let placeholder = try renderMultiview(s)
        XCTAssertFalse(fed.bgra == peakOnly.bgra, "带 RMS 的画法与只有峰值的不同")
        let cs = cells(s)
        func strip(ofInput n: Int) throws -> PixelRect {
            CompositorPasses.meterStrip(try XCTUnwrap(cs.first { $0.spec.kind == .input && Int($0.spec.input) == n }, "没有输入 \(n) 的格子").inner)
        }
        func at(_ bm: Bitmap, _ strip: PixelRect, _ ch: Int, _ f: Float) -> RGBA {
            let p = Self.meterPoint(strip, channel: ch, fraction: f)
            return bm.pixel(p.x, p.y)
        }
        func unchanged(_ strip: PixelRect, _ ch: Int, _ f: Float) -> Bool { at(fed, strip, ch, f) == at(placeholder, strip, ch, f) }
        /// 细线只有 2 px：在期望位置上下 3 行里找颜色
        func lineNear(_ strip: PixelRect, _ ch: Int, _ f: Float, _ test: (RGBA) -> Bool) -> Bool {
            let p = Self.meterPoint(strip, channel: ch, fraction: f)
            return (-3...3).contains { test(fed.pixel(p.x, p.y + $0)) }
        }
        // 输入 1：峰值 −3 / −5（0.95 / 0.917），RMS −12 / −14（0.8 / 0.767）：实心条到 0.8（0.75 处黄），0.85 处是暗条，0.95 附近一道红线
        let s1 = try strip(ofInput: 1)
        XCTAssertTrue(Self.isGreen(at(fed, s1, 0, 0.5)))
        XCTAssertTrue(Self.isYellow(at(fed, s1, 0, 0.75)), "RMS 条 0.8 高，0.75 处应是黄，得 \(at(fed, s1, 0, 0.75))")
        XCTAssertTrue(unchanged(s1, 0, 0.85), "RMS 条顶 0.8 与峰值线 0.95 之间应是暗条，得 \(at(fed, s1, 0, 0.85))")
        XCTAssertTrue(lineNear(s1, 0, 0.95, Self.isRed), "峰值 −3 dBFS 处应有一道红线")
        XCTAssertTrue(unchanged(s1, 0, 0.985), "峰值线之上是暗条")
        XCTAssertTrue(unchanged(s1, 1, 0.85))
        XCTAssertTrue(lineNear(s1, 1, 0.917, Self.isRed), "R 峰值 −5 dBFS 处应有一道红线")
        // 输入 4：峰值 −33 / −40（0.45 / 0.333），RMS −42 / −49（0.3 / 0.183），保持 −21 / −27（0.65 / 0.55）：绿条到 0.3，0.45 附近绿线，0.65 附近绿线，两线之间暗条
        let s4 = try strip(ofInput: 4)
        XCTAssertTrue(Self.isGreen(at(fed, s4, 0, 0.2)))
        XCTAssertTrue(unchanged(s4, 0, 0.38), "RMS 条顶 0.3 与峰值线 0.45 之间应是暗条")
        XCTAssertTrue(lineNear(s4, 0, 0.45, Self.isGreen), "峰值 −33 dBFS 处应有一道绿线")
        XCTAssertTrue(unchanged(s4, 0, 0.55), "峰值线与保持线之间应是暗条")
        XCTAssertTrue(lineNear(s4, 0, 0.65, Self.isGreen), "保持线 −21 dBFS 照旧")
        // 只有峰值的老数据：画法与 W3-B2 相同（上一条用例的参考图没动）
        try assertEqualsReference("v8-multiview-meters", peakOnly)
    }

    /// 017：表里带 RMS，没有 RMS 的数据为 nil；PGM 格读 master 的 RMS
    func testMultiview_meterFeedCarriesRMS() throws {
        let feed = MultiviewMeterFeed()
        let t0 = HostTime(ticks: 5_000_000)
        var m = Stats.AudioCounters.Meters()
        m.inputs = [3: .init(peakDb: [-10, -20], rmsDb: [-19, -29]), 5: .init(peakDb: [-30])]
        m.buses = [.init(bus: Bus.master.name, peakDb: [-6, -7], rmsDb: [-15, -16], truePeakDb: [-5, -6], lufsM: -18, lufsS: -18, lufsI: -18, lra: 1)]
        feed.write(m, at: t0)
        let t = try XCTUnwrap(feed.acquire(now: nil))
        XCTAssertEqual(t.rms(forInput: 3), SIMD2<Float>(-19, -29))
        XCTAssertEqual(t.levels(forInput: 3), SIMD4<Float>(-10, -20, -10, -20))
        XCTAssertNil(t.rms(forInput: 5), "没给 rms_db 的路 → nil（画法回到只有峰值）")
        XCTAssertNotNil(t.levels(forInput: 5))
        XCTAssertEqual(t.programRms, SIMD2<Float>(-15, -16))
        m.buses[0].rmsDb = []
        feed.write(m, at: t0 + HostDuration(milliseconds: 100))
        XCTAssertNil(feed.acquire(now: nil)?.programRms, "master 没有 rms_db → PGM 格只有峰值")
    }

    /// 给定 meters 表（三路不同电平 + Master）→ 参考图 PSNR ∞；没给表 / 清掉表 → 与 W3-B 的占位图 v8-multiview-custom 逐像素相同。
    func testV8_multiviewMetersFromStats() throws {
        let s = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout)
        let calls = ReferenceStates.referenceMeterCalls
        try V8ReferenceTests.compare("v8-multiview-meters", state: s, target: .multiview, meters: calls)

        // 没给表 → 与占位图相同（W3-B 生成的图，本会话没动）
        let placeholder = try renderMultiview(s)
        try assertEqualsReference("v8-multiview-custom", placeholder)
        // 喂过再清掉 → 又回到占位图
        for c in calls { renderer.setMeters(c.meters, at: c.at) }
        renderer.setMeters(nil)
        try assertEqualsReference("v8-multiview-custom", try renderMultiview(s))

        let fed = try renderMultiview(s, meters: calls)
        XCTAssertFalse(fed.bgra == placeholder.bgra)
        let cs = cells(s)
        func strip(ofInput n: Int) throws -> PixelRect {
            CompositorPasses.meterStrip(try XCTUnwrap(cs.first { $0.spec.kind == .input && Int($0.spec.input) == n }, "没有输入 \(n) 的格子").inner)
        }
        func at(_ bm: Bitmap, _ strip: PixelRect, _ ch: Int, _ f: Float) -> RGBA {
            let p = Self.meterPoint(strip, channel: ch, fraction: f)
            return bm.pixel(p.x, p.y)
        }
        func unchanged(_ strip: PixelRect, _ ch: Int, _ f: Float) -> Bool { at(fed, strip, ch, f) == at(placeholder, strip, ch, f) }

        // 输入 1：−3 / −5 → 表高 0.95 / 0.917，顶端进红区
        let s1 = try strip(ofInput: 1)
        XCTAssertTrue(Self.isGreen(at(fed, s1, 0, 0.5)))
        XCTAssertTrue(Self.isYellow(at(fed, s1, 0, 0.75)))
        XCTAssertTrue(Self.isRed(at(fed, s1, 0, 0.93)), "−3 dBFS 的 L 在 0.93 处应是红，得 \(at(fed, s1, 0, 0.93))")
        XCTAssertTrue(Self.isRed(at(fed, s1, 1, 0.905)))
        XCTAssertTrue(unchanged(s1, 1, 0.935), "R 条顶在 0.917，0.935 处应还是暗条")
        // 输入 3：−14 / −16 → 0.767 / 0.733，黄区
        let s3 = try strip(ofInput: 3)
        XCTAssertTrue(Self.isYellow(at(fed, s3, 0, 0.75)))
        XCTAssertTrue(Self.isYellow(at(fed, s3, 1, 0.72)))
        XCTAssertTrue(unchanged(s3, 0, 0.785))
        XCTAssertTrue(unchanged(s3, 1, 0.75))
        // 输入 4：−33 / −40 → 0.45 / 0.333，绿区；峰值保持 −21 / −27 → 0.65 / 0.55 处一道绿线，线和条之间是暗条
        let s4 = try strip(ofInput: 4)
        XCTAssertTrue(Self.isGreen(at(fed, s4, 0, 0.43)))
        XCTAssertTrue(unchanged(s4, 0, 0.55), "条顶 0.45 与保持线 0.65 之间应是暗条")
        let holdLine = (0..<4).map { k -> RGBA in
            let p = Self.meterPoint(s4, channel: 0, fraction: 0.65)
            return fed.pixel(p.x, p.y + k - 1)
        }
        XCTAssertTrue(holdLine.contains { Self.isGreen($0) }, "L 的峰值保持线应在 −21 dBFS（0.65）处，附近四行得 \(holdLine)")
        XCTAssertTrue(unchanged(s4, 1, 0.45), "R 条顶 0.333 与保持线 0.55 之间应是暗条")
        // 输入 2 / 5 没有读数 → 占位，逐像素与占位图相同
        for n in [2, 5] {
            let st = try strip(ofInput: n)
            for f in stride(from: Float(0.02), to: 1, by: 0.07) {
                XCTAssertTrue(unchanged(st, 0, f) && unchanged(st, 1, f), "输入 \(n) 没有读数，表应是占位（\(f)）")
            }
        }
        // PGM 格：Master −9 / −10 → 0.85 / 0.833，黄区；PVW 格：PVW 是输入 2、没有读数 → 不画表（与占位图相同）
        let pgm = CompositorPasses.meterStrip(try XCTUnwrap(cs.first { $0.spec.kind == .program }).inner)
        XCTAssertTrue(Self.isYellow(at(fed, pgm, 0, 0.84)), "PGM 格 L 在 0.84 处应是黄，得 \(at(fed, pgm, 0, 0.84))")
        XCTAssertTrue(Self.isGreen(at(fed, pgm, 1, 0.3)))
        // R 条顶 0.833 之上是暗条：70% 黑盖住 PGM 画面（没给表时 PGM 格根本没有这条，所以跟占位图比的是"画面 × 0.3"）
        let above = at(fed, pgm, 1, 0.845), content = at(placeholder, pgm, 1, 0.845)
        XCTAssertFalse(Self.isYellow(above))
        XCTAssertEqual(Double(above.g), Double(content.g) * 0.3, accuracy: 2, "R 条顶之上应是暗条，得 \(above)，画面 \(content)")
        let pvw = CompositorPasses.meterStrip(try XCTUnwrap(cs.first { $0.spec.kind == .preview }).inner)
        for f in stride(from: Float(0.02), to: 1, by: 0.07) {
            XCTAssertTrue(unchanged(pvw, 0, f) && unchanged(pvw, 1, f), "PVW 的输入没有读数，PVW 格不画表（\(f)）")
        }
        // meters 关：输入格和 PGM 格都不画表，与没给表逐像素相同
        var off = ReferenceStates.customLayout
        off.meters = false
        let offState = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), off)
        XCTAssertTrue(try renderMultiview(offState, meters: calls).bgra == renderMultiview(offState).bgra, "meters 关时表不画，读数不起作用")
    }

    /// 实时路径：另一条线程 `setMeters` 100 次（每 5 ms 一次），期间渲染线程 0 次分配（MallocProbe = malloc_logger 钩子，只数渲染线程）；
    /// 渲染线程确实一次次接手了新表。
    func testMultiview_meterTableUpdateDoesNotAllocateOnRenderThread() throws {
        try XCTSkipUnless(MallocProbe.isAvailable, "找不到 malloc_logger 符号")
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd1080p60, maxInputs: 9)
        // 自定义布局（meters 开）+ 输入 5 换成纯音频：输入格、纯音频格、PGM / PVW 格都在读表
        var state = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout)
        state.inputs[4].source = .audio(deviceUID: "")
        let engine = FakeEngine(renderer: renderer, format: .hd1080p60, inputs: FakeInputs.nv12(count: 8), state: state)
        let startTick: Int64 = 60, stopTick: Int64 = 150
        let counting = SharedFlag(), go = SharedFlag()
        let probeWindow = ProbeWindow()
        engine.beforeRender = { tick in
            if tick.rawValue == startTick { probeWindow.start = HostClock.now(); MallocProbe.start(); counting.value = true; go.value = true }
        }
        engine.afterRender = { tick, _ in
            if counting.value, tick.rawValue == stopTick { MallocProbe.stop(); counting.value = false; probeWindow.stop = HostClock.now() }
        }
        let adoptionsBefore = SharedCounter()
        let writerDone = DispatchSemaphore(value: 0)
        let writes = SharedCounter()
        let writer = Thread {
            while !go.value { usleep(1000) }
            adoptionsBefore.value = renderer.meterAdoptions
            probeWindow.writerStart = HostClock.now()
            for k in 0..<100 {
                var inputs: [Int: [Double]] = [:]
                for n in 1...8 { inputs[n] = [-Double((k * 7 + n * 5) % 60), -Double((k * 3 + n * 11) % 60)] }
                renderer.setMeters(ReferenceStates.meters(inputs: inputs, master: [-Double(k % 40), -12]))
                writes.value += 1
                usleep(5000)
            }
            probeWindow.writerEnd = HostClock.now()
            writerDone.signal()
        }
        writer.start()
        engine.run(seconds: 3.2)
        XCTAssertEqual(writerDone.wait(timeout: .now() + 5), .success)
        MallocProbe.stop()
        let adoptions = renderer.meterAdoptions - adoptionsBefore.value
        renderer.shutdown()

        let list = MallocProbe.attributions()
        let own = list.filter(\.isOwn)
        let swiftOwned = list.filter { $0.directCaller.contains(":$s") }
        print("电平表更新期间（第 \(startTick)–\(stopTick) 拍）：setMeters \(writes.value) 次，渲染线程接手新表 \(adoptions) 次；"
              + "渲染线程共 \(list.count) 次分配，SwitcherRender 代码 \(own.count) 次，全部 Swift 代码 \(swiftOwned.count) 次")
        for (k, v) in MallocProbe.histogram(list).prefix(8) { print("   \(v)x  \(k)") }
        for a in own.prefix(3) { print("   自己的分配：\(a.stack.prefix(12).joined(separator: " <- "))") }
        XCTAssertEqual(writes.value, 100)
        XCTAssertTrue(probeWindow.start <= probeWindow.writerStart && probeWindow.writerEnd <= probeWindow.stop,
                      "100 次 setMeters 都要落在计数窗口里")
        XCTAssertGreaterThan(adoptions, 10, "渲染线程应一帧帧接手新表（60 fps × 约 0.55 s）")
        XCTAssertEqual(own.count, 0, "setMeters 期间渲染线程上 SwitcherRender 代码不许分配")
        #if !DEBUG
        XCTAssertEqual(swiftOwned.count, 0, "release 下渲染线程上任何 Swift 代码都不该分配")
        #endif
        XCTAssertEqual(engine.skipped.load(ordering: .relaxed), 0)
    }

    /// 实时渲染器的多画面（带表）与离线逐字节相同：两边读同一种表、同一份画法。
    func testMultiview_realtimeMetersMatchOffline() throws {
        var options = MetalRendererOptions()
        options.multiviewOutput = true
        let rt = try MetalRenderer(options: options)
        try rt.prepare(format: .hd1080p60, maxInputs: 9)
        let sink = CollectingSink()
        sink.holdDepth = 1
        rt.sink = sink
        let buffers = TestImages.phase2ReferenceBuffers()
        let table = RenderInputTable(capacity: 9)
        for (n, pb) in buffers {
            table[inputNumber: n] = Frame(pixelBuffer: pb, pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: n, sequence: 0, ingressTime: .zero)
        }
        var state = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout)
        state.inputs[4].source = .audio(deviceUID: "")   // 输入 5 纯音频：它的格子也画表
        let snap = MixerSnapshot(state: state, sequence: 1, tick: .zero)
        var inputs = ReferenceStates.referenceMeterInputs
        inputs[5] = [-24.5, -30]
        let meters = ReferenceStates.meters(inputs: inputs, master: ReferenceStates.referenceMeterMaster)
        for i in 0..<30 {   // 等标签线程画好名字；每拍都喂一次（实时路径按当前时刻判过期）
            rt.setMeters(meters)
            _ = rt.render(tick: Tick(Int64(i)), at: HostClock.now(), snapshot: snap, inputs: table)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)
        rt.setMeters(meters)
        XCTAssertEqual(rt.render(tick: Tick(30), at: HostClock.now(), snapshot: snap, inputs: table), .submitted)
        Thread.sleep(forTimeInterval: 0.1)
        let frame = try XCTUnwrap(sink.lastHeld)
        rt.shutdown()
        let multiview = try XCTUnwrap(frame.multiview)
        let offline = try OfflineRenderer()
        offline.setMeters(meters, at: ReferenceStates.meterT0)
        let r = try offline.render(state: state, pixelBuffers: buffers, size: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(PixelBuffers.nv12Planes(multiview.pixelBuffer).luma, PixelBuffers.nv12Planes(r.multiviewNV12).luma, "多画面（带表）实时与离线应逐字节相同")
        XCTAssertEqual(PixelBuffers.nv12Planes(multiview.pixelBuffer).chroma, PixelBuffers.nv12Planes(r.multiviewNV12).chroma)
        // 过期：实时路径超过 3 s 没喂 → 表退回占位（这里直接验读端，不必真等 3 s）
        let feed = MultiviewMeterFeed()
        let fedAt = HostClock.now()
        feed.write(meters, at: fedAt)
        XCTAssertNil(feed.acquire(now: fedAt + HostDuration(seconds: 3.5)))
    }
}

/// 测试线程之间传几个时刻（钩子在渲染线程、写端在另一条线程）。
final class ProbeWindow: @unchecked Sendable {
    var start = HostTime(ticks: .max), stop = HostTime.zero
    var writerStart = HostTime.zero, writerEnd = HostTime(ticks: .max)
}

/// 闭包能捕获的计数器。
final class SharedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
