// V6 切换准确性 / V7 转场进度精度，渲染侧（测试标准 §1 V6–V7、§3 V6–V7、§4）。
// 状态机用 Support/TransitionModel（W1-B reducer 转场部分的复刻）按契约口径推进度，渲染走 OfflineRenderer（与实时路径同一个 encodeFrame）。
// 输入 A 灰 64（Y 71）、输入 B 灰 192（Y 181）；输入 3 是带 alpha 的 stinger 图。
//
// 进度量法（本会话定的口径，报告 §4 有说明）：Fade = 混合比例；Wipe = 擦边位置（直线方向 = 面积覆盖率；对角线由面积反推边位置）；
// Zoom = 新画面的尺度（中心行上新画面的宽度 / 画面宽）；Stinger = 底在第几拍换。
import CoreVideo
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class TransitionTests: XCTestCase {
    static let width = 640, height = 360
    static let size = CGSize(width: width, height: height)
    nonisolated(unsafe) static let renderer: OfflineRenderer = {
        do { return try OfflineRenderer() } catch { fatalError("建不出离线渲染器：\(error)") }
    }()
    static let frames: [Int: Frame] = {
        let buffers: [Int: CVPixelBuffer] = [
            1: TestImages.grayBuffer(level: 64, width: width, height: height),
            2: TestImages.grayBuffer(level: 192, width: width, height: height),
            3: TestImages.stingerBuffer(width: width, height: height),
        ]
        return buffers.mapValues { Frame(pixelBuffer: $0, pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: 0, sequence: 0, ingressTime: .zero) }
    }()

    /// 基础状态：PGM 1（旧）、PVW 2（新）。
    static func baseState(type: TransitionType, duration: Int, wipe: WipeParams = WipeParams(), stinger: StingerParams = StingerParams()) -> MixerState {
        var s = MixerState(format: .hd1080p60, inputs: ReferenceStates.inputs(count: 3), program: 1, preview: 2)
        s.transition = TransitionState(type: type, durationTicks: duration, progress: 0, source: .auto, startTick: nil, wipe: wipe, stinger: stinger)
        return s
    }

    /// 渲染一拍，拿亮度平面。
    static func render(_ state: MixerState) throws -> LumaPlane {
        LumaPlane(try renderer.renderNV12(state: state, frames: frames, size: size).program)
    }

    /// 从第 0 拍跑到 last：每拍先 advance，再在第 s 拍应用命令（= 引擎每拍的顺序），然后渲染。
    static func run(_ model: inout TransitionModel, commandAt s: Tick, through last: Int64,
                    apply: (inout TransitionModel) -> Void) throws -> [Int64: LumaPlane] {
        var out: [Int64: LumaPlane] = [:]
        for t in 0...last {
            let tick = Tick(t)
            model.advance(to: tick)
            if tick == s { apply(&model) }
            out[t] = try render(model.state)
        }
        return out
    }

    /// 20 组确定性的 (时长, 起始拍)。
    static func cases(seed: UInt64) -> [(duration: Int, start: Int64)] {
        var rng = SplitMix(seed: seed)
        let durations = [2, 3, 5, 8, 10, 15, 20, 30]
        return (0..<20).map { _ in (durations[Int(rng.next() % UInt64(durations.count))], Int64(2 + rng.next() % 5)) }
    }

    // MARK: - V6

    /// Cut：第 n 拍应用，第 n 帧起全是新输入，之前全是旧输入，任何一帧都不许混合（硬性）。20 次。
    func testV6_cutLandsOnExactTick_20runs() throws {
        for (i, c) in Self.cases(seed: 1).enumerated() {
            var model = TransitionModel(state: Self.baseState(type: .cut, duration: 0))
            let frames = try Self.run(&model, commandAt: Tick(c.start), through: c.start + 3) { $0.cut() }
            for (t, luma) in frames.sorted(by: { $0.key < $1.key }) {
                let expected = t < c.start ? GrayLevels.oldLuma : GrayLevels.newLuma
                XCTAssertTrue(luma.isUniform(expected, tolerance: 0), "第 \(i) 次（Cut @ \(c.start)）：第 \(t) 拍不是纯 \(expected)（均值 \(luma.mean)）")
            }
        }
    }

    /// Fade / Wipe / Zoom 共用：第 s 拍应用命令（progress 0，画面仍是旧的）；第 s + 1 拍出现第一帧混合；第 s + d 拍起全是新的；中间覆盖率单调不减。
    private func checkAuto(_ type: TransitionType, seed: UInt64, wipe: (SplitMix) -> WipeParams = { _ in WipeParams() }, file: StaticString = #filePath, line: UInt = #line) throws {
        var rng = SplitMix(seed: seed &+ 100)
        for (i, c) in Self.cases(seed: seed).enumerated() {
            let params = wipe(rng)
            _ = rng.next()
            var model = TransitionModel(state: Self.baseState(type: type, duration: c.duration, wipe: params))
            let frames = try Self.run(&model, commandAt: Tick(c.start), through: c.start + Int64(c.duration) + 2) { $0.startAuto(at: Tick(c.start)) }
            var lastCoverage = -1.0
            for t in 0...(c.start + Int64(c.duration) + 2) {
                let luma = frames[t]!
                let label = "第 \(i) 次（\(type) d=\(c.duration) @ \(c.start) \(params.direction) soft \(params.softness)）第 \(t) 拍"
                if t <= c.start {
                    XCTAssertTrue(luma.isUniform(GrayLevels.oldLuma, tolerance: 0), "\(label)：命令拍及之前必须是纯旧画面（均值 \(luma.mean)）", file: file, line: line)
                } else if t < c.start + Int64(c.duration) {
                    XCTAssertFalse(luma.isUniform(GrayLevels.oldLuma), "\(label)：新画面应从 s + 1 拍起出现", file: file, line: line)
                    XCTAssertFalse(luma.isUniform(GrayLevels.newLuma), "\(label)：完成前不该已经全是新画面", file: file, line: line)
                    let cov = GrayLevels.coverage(mean: luma.mean)
                    XCTAssertGreaterThanOrEqual(cov, lastCoverage - 1e-6, "\(label)：覆盖率应单调不减", file: file, line: line)
                    lastCoverage = cov
                } else {
                    XCTAssertTrue(luma.isUniform(GrayLevels.newLuma, tolerance: 0), "\(label)：第 s + d 拍起必须是纯新画面（均值 \(luma.mean)）", file: file, line: line)
                }
            }
        }
    }

    func testV6_fadeFirstMixedFrameAtNextTickCompletesAtDuration_20runs() throws {
        try checkAuto(.fade, seed: 2)
    }

    func testV6_wipeFirstMixedFrameAtNextTickCompletesAtDuration_20runs() throws {
        let directions: [WipeDirection] = [.leftToRight, .rightToLeft, .topToBottom, .bottomToTop, .diagonal]
        try checkAuto(.wipe, seed: 3) { rng in
            var r = rng
            return WipeParams(direction: directions[Int(r.next() % 5)], softness: r.next() % 2 == 0 ? 0 : 0.1)
        }
    }

    func testV6_zoomFirstMixedFrameAtNextTickCompletesAtDuration_20runs() throws {
        try checkAuto(.zoom, seed: 4)
    }

    /// Stinger：底在 stinger 的第 cutAtTick 拍换（第 0 拍 = 命令拍，那一帧什么都不叠；所以最早在 s + 1 换；cutAtTick ≥ d 时在完成拍换）。
    /// 判定用 stinger 图永远透明的左上 / 右下两角；带子经过的中心区域在过渡期间必须是 stinger 的颜色。20 次。
    func testV6_stingerUnderLayerCutsAtConfiguredTick_20runs() throws {
        var rng = SplitMix(seed: 5)
        let w = Self.width, h = Self.height
        for (i, c) in Self.cases(seed: 5).enumerated() {
            let cutAt = Int(rng.next() % UInt64(c.duration + 2))   // 0 … d + 1，含越界
            var model = TransitionModel(state: Self.baseState(type: .stinger, duration: c.duration, stinger: StingerParams(input: 3, cutAtTick: cutAt)))
            let last = c.start + Int64(c.duration) + 1
            let frames = try Self.run(&model, commandAt: Tick(c.start), through: last) { $0.startAuto(at: Tick(c.start)) }
            let expectedFlip = cutAt >= c.duration ? c.start + Int64(c.duration) : c.start + Int64(max(cutAt, 1))
            for t in 0...last {
                let luma = frames[t]!
                let label = "第 \(i) 次（Stinger d=\(c.duration) cutAt=\(cutAt) @ \(c.start)）第 \(t) 拍"
                let expected = t < expectedFlip ? GrayLevels.oldLuma : GrayLevels.newLuma
                XCTAssertTrue(luma.isUniform(expected, x: 0, y: 0, width: w * 15 / 100, height: h * 15 / 100, tolerance: 0), "\(label)：左上角应是 \(expected)（底换的拍不对）", file: #filePath, line: #line)
                XCTAssertTrue(luma.isUniform(expected, x: w - w * 15 / 100, y: h - h * 15 / 100, width: w * 15 / 100, height: h * 15 / 100, tolerance: 0), "\(label)：右下角应是 \(expected)", file: #filePath, line: #line)
                let center = luma[400, 240]
                if t > c.start && t < c.start + Int64(c.duration) {
                    XCTAssertTrue(center != GrayLevels.oldLuma && center != GrayLevels.newLuma, "\(label)：过渡期间带子中心应是 stinger 的颜色，得 \(center)")
                } else {
                    XCTAssertEqual(center, expected, "\(label)：过渡之外不该有 stinger")
                }
            }
        }
    }

    // MARK: - V7

    /// 30 拍转场：第 s + k 拍的进度应为 k / 30，误差（换算成帧）≤ 1。
    private func curveError(type: TransitionType, wipe: WipeParams = WipeParams(), duration d: Int = 30,
                            measure: (LumaPlane) -> Double) throws -> (maxFrames: Double, monotonic: Bool) {
        let s: Int64 = 2
        var model = TransitionModel(state: Self.baseState(type: type, duration: d, wipe: wipe))
        let frames = try Self.run(&model, commandAt: Tick(s), through: s + Int64(d)) { $0.startAuto(at: Tick(s)) }
        var maxErr = 0.0, last = -1.0, monotonic = true
        for k in 1..<d {
            let p = measure(frames[s + Int64(k)]!)
            maxErr = max(maxErr, abs(p - Double(k) / Double(d)) * Double(d))
            if p < last - 1e-9 { monotonic = false }
            last = p
        }
        return (maxErr, monotonic)
    }

    func testV7_fadeProgressCurveWithinOneFrame() throws {
        let (err, mono) = try curveError(type: .fade) { GrayLevels.coverage(mean: $0.mean) }
        print("V7 Fade 30 拍：最大曲线误差 \(String(format: "%.3f", err)) 帧，单调 \(mono)")
        XCTAssertLessThanOrEqual(err, 1)
        XCTAssertTrue(mono)
    }

    /// Wipe 四个直线方向：覆盖面积 = 进度；对角线：面积 = 2e²（e ≤ 0.5）/ 1 − 2(1 − e)²，反推边位置 e 与进度比。硬边和 0.1 软边都测。
    func testV7_wipeProgressCurveWithinOneFrame() throws {
        func diagonalEdge(area a: Double) -> Double { a <= 0.5 ? (a / 2).squareRoot() : 1 - ((1 - a) / 2).squareRoot() }
        for direction in [WipeDirection.leftToRight, .rightToLeft, .topToBottom, .bottomToTop, .diagonal] {
            for softness in [0.0, 0.1] {
                let (err, mono) = try curveError(type: .wipe, wipe: WipeParams(direction: direction, softness: softness)) { luma in
                    let cov = GrayLevels.coverage(mean: luma.mean)
                    return direction == .diagonal ? diagonalEdge(area: cov) : cov
                }
                print("V7 Wipe \(direction) 软边 \(softness) 30 拍：最大曲线误差 \(String(format: "%.3f", err)) 帧，单调 \(mono)")
                XCTAssertLessThanOrEqual(err, 1, "Wipe \(direction) 软边 \(softness)")
                XCTAssertTrue(mono, "Wipe \(direction) 软边 \(softness) 不单调")
            }
        }
    }

    /// Zoom：新画面绕中心按进度缩放（尺度 = 进度），中心行上新画面的宽度 / 画面宽 = 进度。
    func testV7_zoomProgressCurveWithinOneFrame() throws {
        let (err, mono) = try curveError(type: .zoom) { luma in
            Double(luma.countNearer(to: GrayLevels.newLuma, than: GrayLevels.oldLuma, row: Self.height / 2)) / Double(Self.width)
        }
        print("V7 Zoom 30 拍：最大曲线误差 \(String(format: "%.3f", err)) 帧，单调 \(mono)")
        XCTAssertLessThanOrEqual(err, 1)
        XCTAssertTrue(mono)
    }

    /// T-bar 推到 25 / 50 / 75%：Wipe 的覆盖率、Zoom 的尺度与推杆位置之差 ≤ 2%（目标 1%）。
    func testV7_tbarMappingWipeAndZoom() throws {
        for (type, label) in [(TransitionType.wipe, "Wipe"), (.zoom, "Zoom")] {
            for p in [0.25, 0.5, 0.75] {
                var model = TransitionModel(state: Self.baseState(type: type, duration: 30))
                model.tbar(p)
                let luma = try Self.render(model.state)
                let measured = type == .wipe ? GrayLevels.coverage(mean: luma.mean)
                    : Double(luma.countNearer(to: GrayLevels.newLuma, than: GrayLevels.oldLuma, row: Self.height / 2)) / Double(Self.width)
                print("V7 T-bar \(label) \(p) → \(String(format: "%.4f", measured))（误差 \(String(format: "%.2f", abs(measured - p) * 100))%）")
                XCTAssertEqual(measured, p, accuracy: 0.01, "\(label) T-bar \(p) 映射误差超过 1%")
            }
        }
    }

    // MARK: - 结构性检查（V8 的 Wipe / Zoom / Stinger 参考图之外，不依赖参考图）

    /// Wipe 50%：各方向新画面占哪一半。
    func testV8_wipe50EachDirectionRevealsExpectedHalf() throws {
        let w = Self.width, h = Self.height
        let samples: [(WipeDirection, new: (Int, Int), old: (Int, Int))] = [
            (.leftToRight, (w / 4, h / 2), (3 * w / 4, h / 2)),
            (.rightToLeft, (3 * w / 4, h / 2), (w / 4, h / 2)),
            (.topToBottom, (w / 2, h / 4), (w / 2, 3 * h / 4)),
            (.bottomToTop, (w / 2, 3 * h / 4), (w / 2, h / 4)),
            (.diagonal, (w / 4, h / 4), (3 * w / 4, 3 * h / 4)),
        ]
        for (direction, newAt, oldAt) in samples {
            var s = Self.baseState(type: .wipe, duration: 30, wipe: WipeParams(direction: direction))
            s.transition.progress = 0.5
            s.transition.startTick = Tick(0)
            let luma = try Self.render(s)
            XCTAssertEqual(luma[newAt.0, newAt.1], GrayLevels.newLuma, "\(direction)：\(newAt) 应是新画面")
            XCTAssertEqual(luma[oldAt.0, oldAt.1], GrayLevels.oldLuma, "\(direction)：\(oldAt) 应是旧画面")
            // 硬边：没有中间值
            XCTAssertTrue(luma.bytes.allSatisfy { Int($0) == GrayLevels.oldLuma || Int($0) == GrayLevels.newLuma }, "\(direction)：硬边不该有混合像素")
        }
        // 软边 0.2：边上有一段过渡，且左右两端仍是纯的
        var soft = Self.baseState(type: .wipe, duration: 30, wipe: WipeParams(direction: .leftToRight, softness: 0.2))
        soft.transition.progress = 0.5
        soft.transition.startTick = Tick(0)
        let luma = try Self.render(soft)
        XCTAssertEqual(luma[w / 8, h / 2], GrayLevels.newLuma)
        XCTAssertEqual(luma[7 * w / 8, h / 2], GrayLevels.oldLuma)
        let edge = luma[w / 2, h / 2]
        XCTAssertTrue(edge > GrayLevels.oldLuma + 20 && edge < GrayLevels.newLuma - 20, "软边中点应是中间值，得 \(edge)")
        let quarterIn = luma[w / 2 - Int(0.08 * Double(w)), h / 2]
        XCTAssertTrue(quarterIn > edge, "软边内侧应更接近新画面")
    }

    /// Zoom 50%：新画面是居中、宽高各一半的矩形；外面是旧画面，没有混合。
    func testV8_zoom50NewPictureIsCenteredHalfSize() throws {
        let w = Self.width, h = Self.height
        var s = Self.baseState(type: .zoom, duration: 30)
        s.transition.progress = 0.5
        s.transition.startTick = Tick(0)
        let luma = try Self.render(s)
        XCTAssertEqual(luma[w / 2, h / 2], GrayLevels.newLuma)
        XCTAssertEqual(luma[w / 8, h / 2], GrayLevels.oldLuma)
        XCTAssertEqual(luma[w / 2, h / 8], GrayLevels.oldLuma)
        XCTAssertEqual(luma[w / 4 - 2, h / 2], GrayLevels.oldLuma, "左边缘外")
        XCTAssertEqual(luma[w / 4 + 2, h / 2], GrayLevels.newLuma, "左边缘内")
        XCTAssertEqual(luma[w / 2, h / 4 - 2], GrayLevels.oldLuma, "上边缘外")
        XCTAssertEqual(luma[w / 2, h / 4 + 2], GrayLevels.newLuma, "上边缘内")
        XCTAssertEqual(luma.countNearer(to: GrayLevels.newLuma, than: GrayLevels.oldLuma, row: h / 2), w / 2, accuracy: 2)
    }

    /// Stinger 中点（30 拍，第 15 拍换底，进度 0.5）：透明角落已经是新画面；带子中心是 stinger。第 14 拍（进度 14/30）角落还是旧画面。
    func testV8_stingerMidpointShowsNewUnderAndStingerOnTop() throws {
        var s = Self.baseState(type: .stinger, duration: 30, stinger: StingerParams(input: 3, cutAtTick: 15))
        s.transition.startTick = Tick(0)
        s.transition.progress = 0.5
        let mid = try Self.render(s)
        XCTAssertEqual(mid[10, 10], GrayLevels.newLuma)
        XCTAssertEqual(mid[Self.width - 10, Self.height - 10], GrayLevels.newLuma)
        XCTAssertNotEqual(mid[400, 240], GrayLevels.newLuma)
        s.transition.progress = 14.0 / 30
        let before = try Self.render(s)
        XCTAssertEqual(before[10, 10], GrayLevels.oldLuma)
        XCTAssertNotEqual(before[400, 240], GrayLevels.oldLuma)
        // stinger 输入没帧：退化成"第 15 拍换底的延迟 Cut"，不崩
        s.transition.stinger.input = 9
        s.transition.progress = 0.5
        XCTAssertTrue(try Self.render(s).isUniform(GrayLevels.newLuma, tolerance: 0))
        s.transition.progress = 14.0 / 30
        XCTAssertTrue(try Self.render(s).isUniform(GrayLevels.oldLuma, tolerance: 0))
    }

    /// 切向黑场（preview = 0）：Wipe / Zoom / Stinger 都按进度压黑，不崩。
    func testTransition_toBlackWorksForWipeZoomStinger() throws {
        let w = Self.width, h = Self.height
        for type in [TransitionType.wipe, .zoom, .stinger] {
            var s = Self.baseState(type: type, duration: 30, stinger: StingerParams(input: 3, cutAtTick: 10))
            s.preview = 0
            s.transition.startTick = Tick(0)
            s.transition.progress = 0.5
            let luma = try Self.render(s)
            XCTAssertLessThan(luma.mean, Double(GrayLevels.oldLuma), "\(type)：整体应比纯旧画面暗")
            switch type {
            case .wipe:   // 左→右 50%：左半黑、右半旧
                XCTAssertEqual(luma[w / 4, h / 2], 16, "wipe 左半应是黑")
                XCTAssertEqual(luma[3 * w / 4, h / 2], GrayLevels.oldLuma, "wipe 右半应是旧画面")
            case .zoom:   // 居中一半大小的黑块
                XCTAssertEqual(luma[w / 2, h / 2], 16, "zoom 中心应是黑")
                XCTAssertEqual(luma[w / 8, h / 8], GrayLevels.oldLuma, "zoom 角落应是旧画面")
            default:      // 第 15 拍 ≥ cutAt 10：底已是黑，带子照旧
                XCTAssertEqual(luma[10, 10], 16, "stinger 换底后角落应是黑")
                XCTAssertNotEqual(luma[400, 240], 16, "stinger 带子中心应是 stinger")
            }
        }
    }

    /// TransitionRenderer 的 stinger 换底判定（纯函数）。
    func testTransition_stingerCutRule() {
        // d = 30, cutAt = 15：第 14 拍旧、第 15 拍新
        XCTAssertFalse(TransitionRenderer.stingerShowsNewUnder(progress: 14.0 / 30, durationTicks: 30, cutAtTick: 15))
        XCTAssertTrue(TransitionRenderer.stingerShowsNewUnder(progress: 15.0 / 30, durationTicks: 30, cutAtTick: 15))
        // cutAt 0 与 1 等价（第 0 拍不画）
        XCTAssertTrue(TransitionRenderer.stingerShowsNewUnder(progress: 1.0 / 30, durationTicks: 30, cutAtTick: 0))
        XCTAssertTrue(TransitionRenderer.stingerShowsNewUnder(progress: 1.0 / 30, durationTicks: 30, cutAtTick: 1))
        // cutAt ≥ d：过渡期间永远不换（完成时状态机对调）
        XCTAssertFalse(TransitionRenderer.stingerShowsNewUnder(progress: 29.0 / 30, durationTicks: 30, cutAtTick: 30))
        XCTAssertFalse(TransitionRenderer.stingerShowsNewUnder(progress: 29.0 / 30, durationTicks: 30, cutAtTick: 99))
        // 浮点：k / d 再乘 d 可能差一个 ulp，要按四舍五入
        XCTAssertTrue(TransitionRenderer.stingerShowsNewUnder(progress: 7.0 / 30, durationTicks: 30, cutAtTick: 7))
    }
}

/// 确定性的随机数（SplitMix64）。
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
