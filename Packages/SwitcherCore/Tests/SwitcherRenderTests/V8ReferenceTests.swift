// V8 画面正确性（测试标准 §1 V8、§3 V8、§4：PSNR ≥ 40 dB 或 SSIM ≥ 0.98）。
// 固定状态 + 固定输入图 → 离线渲染 → 与 Tests/References/*.png 比。
// 生成 / 更新参考图：scripts/gen-references.sh（设 SWITCHER_GEN_REFERENCES=1 跑这些测试）；改了参考图必须在报告 / PR 里说明。
import CoreGraphics
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class V8ReferenceTests: XCTestCase {
    static let size = CGSize(width: TestImages.width, height: TestImages.height)
    static let psnrThreshold = 40.0
    static let ssimThreshold = 0.98

    /// 一张参考图：名字、状态、取哪张输出、PVW 是否叠加。
    struct RefCase {
        let name: String
        let state: MixerState
        let target: OfflineRenderTarget
        var overlaysInPreview = false
    }

    /// V8 的参考图集。前五张是 W1-C 的（状态不变，改了实现也必须逐像素一致）；其余是 W3-B 加的（每张为什么这样见 Tests/References/README.md）。
    static let cases: [RefCase] = [
        RefCase(name: "v8-fixed-pgm", state: ReferenceStates.fixed(), target: .program),
        RefCase(name: "v8-fade50-pgm", state: ReferenceStates.fade50(), target: .program),
        RefCase(name: "v8-ftb100-pgm", state: ReferenceStates.ftb100(), target: .program),
        RefCase(name: "v8-preview-pvw", state: ReferenceStates.fixed(), target: .preview),
        RefCase(name: "v8-fixed-multiview", state: ReferenceStates.fixed(), target: .multiview),
        // W3-B
        RefCase(name: "v8-overlay-order-pgm", state: ReferenceStates.overlayOrder(), target: .program),
        RefCase(name: "v8-pip-border-pgm", state: ReferenceStates.pipBorder(), target: .program),
        RefCase(name: "v8-keyer-pgm", state: ReferenceStates.keyed(), target: .program),
        RefCase(name: "v8-wipe50-l2r-pgm", state: ReferenceStates.wipe50(.leftToRight), target: .program),
        RefCase(name: "v8-wipe50-r2l-pgm", state: ReferenceStates.wipe50(.rightToLeft), target: .program),
        RefCase(name: "v8-wipe50-t2b-pgm", state: ReferenceStates.wipe50(.topToBottom), target: .program),
        RefCase(name: "v8-wipe50-b2t-pgm", state: ReferenceStates.wipe50(.bottomToTop), target: .program),
        RefCase(name: "v8-wipe50-diag-pgm", state: ReferenceStates.wipe50(.diagonal), target: .program),
        RefCase(name: "v8-wipe50-l2r-soft-pgm", state: ReferenceStates.wipe50(.leftToRight, softness: 0.2), target: .program),
        RefCase(name: "v8-zoom50-pgm", state: ReferenceStates.zoom50(), target: .program),
        RefCase(name: "v8-stinger-mid-pgm", state: ReferenceStates.stingerMid(), target: .program),
        RefCase(name: "v8-overlay-slide50-pgm", state: ReferenceStates.overlaySlide50(), target: .program),
        RefCase(name: "v8-overlay-zoom50-pgm", state: ReferenceStates.overlayZoom50(), target: .program),
        RefCase(name: "v8-preview-overlays-pvw", state: ReferenceStates.fixed8(), target: .preview, overlaysInPreview: true),
        RefCase(name: "v8-multiview-pgmpvw2x2", state: ReferenceStates.withMultiviewPreset(ReferenceStates.fixed8(), "pgmPvw+2x2"), target: .multiview),
        RefCase(name: "v8-multiview-3x3", state: ReferenceStates.withMultiviewPreset(ReferenceStates.fixed8(), "3x3"), target: .multiview),
        RefCase(name: "v8-multiview-custom", state: ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout), target: .multiview),
    ]

    // 测试类串行跑，共用一个离线渲染器省得每个用例重建纹理；OfflineRenderer 不是 Sendable，所以显式声明不做并发检查
    nonisolated(unsafe) private static let renderer: OfflineRenderer = {
        do { return try OfflineRenderer() } catch { fatalError("建不出离线渲染器：\(error)") }
    }()
    private static let inputs = TestImages.phase2ReferenceInputs()

    /// 渲染一个 case，按环境变量决定写参考图还是比对。返回 (psnr, ssim)。
    @discardableResult
    func compare(_ name: String, state: MixerState, target: OfflineRenderTarget, overlaysInPreview: Bool = false,
                 file: StaticString = #filePath, line: UInt = #line) throws -> (Double, Double) {
        Self.renderer.overlaysInPreview = overlaysInPreview
        defer { Self.renderer.overlaysInPreview = false }
        let image = try Self.renderer.renderOffline(state: state, inputs: Self.inputs, size: Self.size, target: target)
        let refURL = RepoPaths.references.appendingPathComponent("\(name).png")
        if RepoPaths.generatingReferences {
            try PNG.write(image, to: refURL)
            print("已写参考图 \(refURL.path)")
            return (.infinity, 1)
        }
        // 实际输出也存一份，方便人工对比
        try? PNG.write(image, to: RepoPaths.output.appendingPathComponent("\(name).png"))
        guard let ref = PNG.read(refURL) else {
            throw XCTSkip("没有参考图 \(refURL.path)：先跑 scripts/gen-references.sh")
        }
        let a = Bitmap(image), b = Bitmap(ref)
        XCTAssertEqual(a.width, b.width, file: file, line: line)
        XCTAssertEqual(a.height, b.height, file: file, line: line)
        let psnr = ImageMetrics.psnr(a, b)
        let ssim = ImageMetrics.ssim(a, b)
        print("V8 \(name)：PSNR \(psnr.isInfinite ? "∞" : String(format: "%.2f", psnr)) dB，SSIM \(String(format: "%.4f", ssim))")
        XCTAssertTrue(psnr >= Self.psnrThreshold || ssim >= Self.ssimThreshold,
                      "\(name)：PSNR \(psnr) dB / SSIM \(ssim) 都不达标（≥ 40 dB 或 ≥ 0.98）", file: file, line: line)
        return (psnr, ssim)
    }

    /// 固定状态：PGM = 输入 1，Overlay 1（下三分之一，输入 3）和 3（画中画右下 1/4，输入 4）开，FTB 关。
    func testV8_fixedStateMatchesReference() throws {
        try compare("v8-fixed-pgm", state: ReferenceStates.fixed(), target: .program)
    }

    /// Fade 50%。
    func testV8_fade50MatchesReference() throws {
        try compare("v8-fade50-pgm", state: ReferenceStates.fade50(), target: .program)
    }

    /// FTB 100%。
    func testV8_ftb100MatchesReference() throws {
        try compare("v8-ftb100-pgm", state: ReferenceStates.ftb100(), target: .program)
    }

    /// 纯 PVW。
    func testV8_previewMatchesReference() throws {
        try compare("v8-preview-pvw", state: ReferenceStates.fixed(), target: .preview)
    }

    /// 多画面（基础网格 + tally 边框 + 名字）。
    func testV8_multiviewMatchesReference() throws {
        try compare("v8-fixed-multiview", state: ReferenceStates.fixed(), target: .multiview)
    }

    /// 所有 case 一次跑完（gen-references.sh 用这个 filter）。
    func testV8_generateOrCompareAllReferences() throws {
        for c in Self.cases { try compare(c.name, state: c.state, target: c.target, overlaysInPreview: c.overlaysInPreview) }
    }

    // MARK: - W3-B 加的参考图（每张一个测试，方便单独跑；结构性检查在 OverlayTests / KeyerTests / TransitionTests / MultiviewLayoutTests）

    func testV8_overlayOrderMatchesReference() throws { try compare("v8-overlay-order-pgm", state: ReferenceStates.overlayOrder(), target: .program) }
    func testV8_pipBorderMatchesReference() throws { try compare("v8-pip-border-pgm", state: ReferenceStates.pipBorder(), target: .program) }
    func testV8_keyerMatchesReference() throws { try compare("v8-keyer-pgm", state: ReferenceStates.keyed(), target: .program) }
    func testV8_wipe50AllDirectionsMatchReference() throws {
        try compare("v8-wipe50-l2r-pgm", state: ReferenceStates.wipe50(.leftToRight), target: .program)
        try compare("v8-wipe50-r2l-pgm", state: ReferenceStates.wipe50(.rightToLeft), target: .program)
        try compare("v8-wipe50-t2b-pgm", state: ReferenceStates.wipe50(.topToBottom), target: .program)
        try compare("v8-wipe50-b2t-pgm", state: ReferenceStates.wipe50(.bottomToTop), target: .program)
        try compare("v8-wipe50-diag-pgm", state: ReferenceStates.wipe50(.diagonal), target: .program)
        try compare("v8-wipe50-l2r-soft-pgm", state: ReferenceStates.wipe50(.leftToRight, softness: 0.2), target: .program)
    }
    func testV8_zoom50MatchesReference() throws { try compare("v8-zoom50-pgm", state: ReferenceStates.zoom50(), target: .program) }
    func testV8_stingerMidMatchesReference() throws { try compare("v8-stinger-mid-pgm", state: ReferenceStates.stingerMid(), target: .program) }
    func testV8_overlayAnimationsMatchReference() throws {
        try compare("v8-overlay-slide50-pgm", state: ReferenceStates.overlaySlide50(), target: .program)
        try compare("v8-overlay-zoom50-pgm", state: ReferenceStates.overlayZoom50(), target: .program)
    }
    func testV8_previewWithOverlaysMatchesReference() throws { try compare("v8-preview-overlays-pvw", state: ReferenceStates.fixed8(), target: .preview, overlaysInPreview: true) }
    func testV8_multiviewLayoutsMatchReference() throws {
        try compare("v8-multiview-pgmpvw2x2", state: ReferenceStates.withMultiviewPreset(ReferenceStates.fixed8(), "pgmPvw+2x2"), target: .multiview)
        try compare("v8-multiview-3x3", state: ReferenceStates.withMultiviewPreset(ReferenceStates.fixed8(), "3x3"), target: .multiview)
        try compare("v8-multiview-custom", state: ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout), target: .multiview)
    }

    // MARK: - 不依赖参考图的结构性检查（参考图错了这些也会报）

    /// 叠加顺序：Overlay 3 在 Overlay 1 上面。把两个 overlay 放同一位置：1 = 纯红全幅，3 = 纯蓝全幅 → 结果是蓝。
    func testV8_overlay3DrawsAboveOverlay1() throws {
        var s = ReferenceStates.fixed()
        s.overlays[0] = OverlayState(input: 3, on: true, rect: .full, animProgress: 1)
        s.overlays[2] = OverlayState(input: 4, on: true, rect: .full, animProgress: 1)
        let red = TestImages.image(from: TestImages.grayBuffer(level: 0, width: 64, height: 64).filled(255, 0, 0))
        let blue = TestImages.image(from: TestImages.grayBuffer(level: 0, width: 64, height: 64).filled(0, 0, 255))
        let img = try Self.renderer.renderOffline(state: s, inputs: [1: Self.inputs[1]!, 3: red, 4: blue], size: CGSize(width: 256, height: 144))
        let bm = Bitmap(img)
        let p = bm.pixel(128, 72)
        XCTAssertEqual(p.b, 255, "Overlay 3 应盖住 Overlay 1")
        XCTAssertEqual(p.r, 0)
        // 反过来：3 关掉，看到 1 的红
        s.overlays[2].on = false
        s.overlays[2].animProgress = 0
        let img2 = try Self.renderer.renderOffline(state: s, inputs: [1: Self.inputs[1]!, 3: red, 4: blue], size: CGSize(width: 256, height: 144))
        let q = Bitmap(img2).pixel(128, 72)
        XCTAssertEqual(q.r, 255)
        XCTAssertEqual(q.b, 0)
    }

    /// 画中画位置：右下 1/4 的中心是输入 4 的内容，左上还是输入 1。
    func testV8_pictureInPictureLandsInBottomRightQuarter() throws {
        let s = ReferenceStates.fixed()
        let img = try Self.renderer.renderOffline(state: s, inputs: Self.inputs, size: Self.size)
        let bm = Bitmap(img)
        // 输入 4 右下象限的亮格是黄 (230,230,60)；画中画把整幅 1920×1080 缩到右下 960×540，其右下象限中心 ≈ (1680, 945)
        let pip = bm.pixel(1680, 945)
        XCTAssertTrue(pip.r > 200 && pip.g > 200 && pip.b < 100 || pip.r < 80 && pip.g < 80, "画中画右下象限应是黄 / 暗黄棋盘，得 \(pip)")
        // 画中画左上角 (960+8, 540+8) 附近是输入 4 的左上象限（红系）
        let pipTopLeft = bm.pixel(975, 552)
        XCTAssertTrue(pipTopLeft.r > pipTopLeft.g && pipTopLeft.r > pipTopLeft.b, "画中画左上应是红系棋盘，得 \(pipTopLeft)")
        // PGM 左上 (200, 300) 是输入 1 的渐变（灰），不受画中画影响
        let base = bm.pixel(200, 300)
        XCTAssertLessThan(abs(base.r - base.g), 3)
        XCTAssertLessThan(abs(base.g - base.b), 3)
    }

    /// 半透明叠加：输入 3 的 50% 白方块盖在输入 1 上 → 输出 = 0.5·白 + 0.5·底（gamma 域直接混合，决策 6）。
    func testV8_alphaOverlayBlendsInGammaDomain() throws {
        var s = ReferenceStates.fixed()
        s.overlays[2].on = false
        s.overlays[2].animProgress = 0
        let img = try Self.renderer.renderOffline(state: s, inputs: Self.inputs, size: Self.size)
        let bm = Bitmap(img)
        let x = 400, y = 300   // 在 50% 白方块 (200–620, 200–420) 里
        let baseLevel = Double(x * 255 / (TestImages.width - 1))   // 输入 1 渐变底在 x 处的灰
        let expected = (255.0 + baseLevel) / 2
        let p = bm.pixel(x, y)
        XCTAssertEqual(Double(p.r), expected, accuracy: 2)
        XCTAssertEqual(Double(p.g), expected, accuracy: 2)
        XCTAssertEqual(Double(p.b), expected, accuracy: 2)
    }

    /// FTB 50%：每个像素 = 0.5 × 无 FTB 的像素。
    func testV8_ftbHalfScalesEveryPixel() throws {
        var s = ReferenceStates.fixed()
        s.ftb = FadeToBlack(on: true, durationTicks: 30, level: 0.5)
        let with = Bitmap(try Self.renderer.renderOffline(state: s, inputs: Self.inputs, size: Self.size))
        let without = Bitmap(try Self.renderer.renderOffline(state: ReferenceStates.fixed(), inputs: Self.inputs, size: Self.size))
        for (x, y) in [(100, 100), (960, 540), (1500, 900), (1700, 1000)] {
            let a = with.pixel(x, y), b = without.pixel(x, y)
            XCTAssertEqual(Double(a.r), Double(b.r) / 2, accuracy: 1.5)
            XCTAssertEqual(Double(a.g), Double(b.g) / 2, accuracy: 1.5)
            XCTAssertEqual(Double(a.b), Double(b.b) / 2, accuracy: 1.5)
        }
    }

    /// 裁切 + 变换：输入 1 左半裁掉、缩到 0.5、右移 0.25 → 画面中心偏右处是输入 1 的右半内容，左边是黑。
    func testV8_cropAndTransformPlaceContent() throws {
        var s = MixerState(format: .hd1080p60, inputs: ReferenceStates.inputs(count: 1), program: 1, preview: 0)
        s.inputs[0].settings.crop = CropInsets(left: 0.5, top: 0, right: 0, bottom: 0)
        s.inputs[0].settings.transform = Transform2D(scale: 0.5, offsetX: 0.25, offsetY: 0)
        let img = try Self.renderer.renderOffline(state: s, inputs: [1: Self.inputs[2]!], size: Self.size)   // 输入 2 = 色条
        let bm = Bitmap(img)
        // 裁掉左半后剩下右 3.5 条（绿右半、品、红、蓝），fit 后宽 = 960·(960/1080·... ) —— 只查定性：左 1/3 黑，中心偏右有颜色
        let left = bm.pixel(200, 300)
        XCTAssertEqual(left.r + left.g + left.b, 0, "变换后左侧应是黑边")
        let mid = bm.pixel(1400, 300)
        XCTAssertGreaterThan(mid.r + mid.g + mid.b, 100, "内容应出现在右侧")
        // 翻转：水平翻转后，原本最右的蓝条到最左
        s.inputs[0].settings.crop = .none
        s.inputs[0].settings.transform = Transform2D(flipHorizontal: true)
        let flipped = Bitmap(try Self.renderer.renderOffline(state: s, inputs: [1: Self.inputs[2]!], size: Self.size))
        let l = flipped.pixel(100, 300)
        XCTAssertTrue(l.b > 150 && l.r < 40 && l.g < 40, "水平翻转后最左应是蓝条，得 \(l)")
    }

    /// 无信号 / 编号 0：PGM = 0 时全黑；PGM 指向没有帧的输入也全黑，不崩。
    func testV8_missingInputRendersBlack() throws {
        var s = ReferenceStates.fixed()
        s.program = 0
        s.overlays = Array(repeating: OverlayState(), count: 4)
        let bm = Bitmap(try Self.renderer.renderOffline(state: s, inputs: Self.inputs, size: CGSize(width: 320, height: 180)))
        XCTAssertEqual(bm.pixel(160, 90).r + bm.pixel(160, 90).g + bm.pixel(160, 90).b, 0)
        s.program = 9   // 没这路（W3-B 起输入表带 5–8 路，用 9）
        let bm2 = Bitmap(try Self.renderer.renderOffline(state: s, inputs: Self.inputs, size: CGSize(width: 320, height: 180)))
        XCTAssertEqual(bm2.pixel(10, 10).r + bm2.pixel(10, 10).g + bm2.pixel(10, 10).b, 0)
    }
}

extension CVPixelBuffer {
    /// 测试用：整幅填一个纯色（BGRA）。
    func filled(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CVPixelBuffer {
        PixelBuffers.fillBGRA(self) { _, _ in (r, g, b, 255) }
        return self
    }
}
