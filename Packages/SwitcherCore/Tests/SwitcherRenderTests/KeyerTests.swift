// 抠像（设计方案 §5、提案 008 的口径；W3-B 交付 2）：绿幕合成图 → 与已知 alpha 的掩膜 IoU ≥ 0.95、溢色抑制、柔化、关掉不动像素。
import CoreGraphics
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class KeyerTests: XCTestCase {
    static let width = TestImages.width, height = TestImages.height
    static let size = CGSize(width: width, height: height)
    nonisolated(unsafe) static let renderer: OfflineRenderer = {
        do { return try OfflineRenderer() } catch { fatalError("建不出离线渲染器：\(error)") }
    }()
    /// 1 = 黑底，2 = 白底，5 = 绿幕合成图。
    static let inputs: [Int: CGImage] = [
        1: TestImages.image(from: TestImages.grayBuffer(level: 0)),
        2: TestImages.image(from: TestImages.grayBuffer(level: 255)),
        5: TestImages.image(from: TestImages.greenScreenBuffer()),
    ]
    static let referenceAlpha = TestImages.greenScreenAlpha()

    /// 抠像后的输入 5 作 Overlay 2 叠在 program 上。
    static func state(program: Int, keyer: KeyerSettings) -> MixerState {
        var s = MixerState(format: .hd1080p60, inputs: ReferenceStates.phase2Inputs(), program: program, preview: 2)
        s.overlays[1] = OverlayState(input: 5, on: true, rect: .full, animProgress: 1)
        s.inputs[4].settings.keyer = keyer
        return s
    }

    /// 同一抠像分别叠在黑底和白底上 → 每个像素的 alpha = 1 − (白底结果 − 黑底结果) / 255（取绿通道；三个通道一样）。
    static func keyedAlpha(_ keyer: KeyerSettings) throws -> (alpha: [Float], onBlack: Bitmap, onWhite: Bitmap) {
        let black = Bitmap(try renderer.renderOffline(state: state(program: 1, keyer: keyer), inputs: inputs, size: size))
        let white = Bitmap(try renderer.renderOffline(state: state(program: 2, keyer: keyer), inputs: inputs, size: size))
        var alpha = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let diff = Float(white.bgra[i * 4 + 1]) - Float(black.bgra[i * 4 + 1])
            alpha[i] = 1 - min(1, max(0, diff / 255))
        }
        return (alpha, black, white)
    }

    /// 掩膜 IoU（alpha ≥ 0.5）；另算"边带 IoU"：只看参考 alpha 边缘 ±3 px 的像素。
    static func iou(_ a: [Float], _ b: [Float], band: [Bool]? = nil) -> Double {
        var inter = 0, union = 0
        for i in 0..<a.count where band?[i] ?? true {
            let x = a[i] >= 0.5, y = b[i] >= 0.5
            if x && y { inter += 1 }
            if x || y { union += 1 }
        }
        return union == 0 ? 1 : Double(inter) / Double(union)
    }

    /// 参考 alpha 的边缘带：3 px 内有 alpha 跨过 0.5 的像素。
    static func edgeBand(_ alpha: [Float], radius: Int = 3) -> [Bool] {
        var edge = [Bool](repeating: false, count: alpha.count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let m = alpha[i] >= 0.5
                if (alpha[i - 1] >= 0.5) != m || (alpha[i + 1] >= 0.5) != m || (alpha[i - width] >= 0.5) != m || (alpha[i + width] >= 0.5) != m {
                    for dy in -radius...radius { for dx in -radius...radius { edge[(y + dy) * width + (x + dx)] = true } }
                }
            }
        }
        return edge
    }

    /// V8 抠像：已知绿幕合成图（光照渐变 + 噪声）→ 抠像 alpha 与已知 alpha 的掩膜 IoU ≥ 0.95。
    func testV8_keyerGreenScreenEdgeIoUAtLeast095() throws {
        let (alpha, onBlack, _) = try Self.keyedAlpha(ReferenceStates.keyer())
        let full = Self.iou(alpha, Self.referenceAlpha)
        let band = Self.iou(alpha, Self.referenceAlpha, band: Self.edgeBand(Self.referenceAlpha))
        // 掩膜面积差（抠出来的比参考胖 / 瘦多少像素）
        let refCount = Self.referenceAlpha.filter { $0 >= 0.5 }.count, gotCount = alpha.filter { $0 >= 0.5 }.count
        print("V8 抠像：掩膜 IoU \(String(format: "%.4f", full))，边带（±3 px）IoU \(String(format: "%.4f", band))，参考前景 \(refCount) px，抠出 \(gotCount) px")
        XCTAssertGreaterThanOrEqual(full, 0.95, "抠像掩膜与已知 alpha 的 IoU 不达标")
        // 背景（远离前景的绿幕）必须全透：黑底上是黑
        let bg = onBlack.pixel(1700, 950)
        XCTAssertEqual(bg.r + bg.g + bg.b, 0, "绿幕背景应被完全抠掉，得 \(bg)")
        // 前景内部不透明且颜色保留：圆盘中心是肤色
        let fg = onBlack.pixel(620, 560)
        XCTAssertEqual(fg.r, 220, accuracy: 3)
        XCTAssertEqual(fg.g, 170, accuracy: 3)
        XCTAssertEqual(fg.b, 140, accuracy: 3)
        // 输出图另存一份方便人看
        try? PNG.write(try Self.renderer.renderOffline(state: Self.state(program: 1, keyer: ReferenceStates.keyer()), inputs: Self.inputs, size: Self.size),
                       to: RepoPaths.output.appendingPathComponent("keyer-on-black.png"))
    }

    /// 溢色抑制：白色前景边缘的像素混进了绿（合成图的边缘）；spill 1 时抠出来的边缘像素绿通道不再高出红 / 蓝。
    func testKeyer_spillSuppressionRemovesKeyHueFromEdges() throws {
        func excessGreen(spill: Double) throws -> Double {
            let (alpha, onBlack, _) = try Self.keyedAlpha(ReferenceStates.keyer(spill: spill))
            var sum = 0.0, n = 0
            // 白色前景区（左下象限）的边缘像素：参考 alpha 0.4–0.7
            for y in (Self.height / 2)..<Self.height {
                for x in 0..<(Self.width / 2) {
                    let i = y * Self.width + x
                    let a = Self.referenceAlpha[i]
                    guard a > 0.4 && a < 0.7 && alpha[i] > 0.05 else { continue }
                    // 反预乘
                    let p = onBlack.pixel(x, y)
                    let r = Double(p.r) / Double(alpha[i]), g = Double(p.g) / Double(alpha[i]), b = Double(p.b) / Double(alpha[i])
                    sum += g - (r + b) / 2
                    n += 1
                }
            }
            XCTAssertGreaterThan(n, 100, "应有足够的边缘像素")
            return sum / Double(n)
        }
        let none = try excessGreen(spill: 0), fullSpill = try excessGreen(spill: 1)
        print("溢色：边缘像素绿超出 (R+B)/2 的均值：spill 0 → \(String(format: "%.1f", none))，spill 1 → \(String(format: "%.1f", fullSpill))")
        XCTAssertGreaterThan(none, 8, "不抑制时边缘应带绿（否则测试没测到东西）")
        XCTAssertLessThan(fullSpill, 3, "spill 1 时边缘不该再偏绿")
        XCTAssertLessThan(fullSpill, none / 3)
    }

    /// 柔化：softness 大 → alpha 0–1 之间的中间值像素更多；容差 0 + 柔化 0 → 只有精确键色被抠（背景噪声留下来）。
    func testKeyer_softnessAndToleranceBehaveMonotonically() throws {
        func midCount(_ k: KeyerSettings) throws -> Int {
            try Self.keyedAlpha(k).alpha.filter { $0 > 0.05 && $0 < 0.95 }.count
        }
        let hard = try midCount(ReferenceStates.keyer(softness: 0))
        let soft = try midCount(ReferenceStates.keyer(softness: 0.6))
        print("柔化：中间 alpha 像素数 softness 0 → \(hard)，0.6 → \(soft)")
        XCTAssertGreaterThan(soft, hard * 2)
        // 容差 0、柔化 0：只有和键色完全一样的像素才透；合成图的绿幕带噪声，所以大部分背景留下
        let strict = try Self.keyedAlpha(ReferenceStates.keyer(tolerance: 0, softness: 0))
        let bgKept = strict.alpha.enumerated().filter { Self.referenceAlpha[$0.offset] == 0 && $0.element >= 0.5 }.count
        let bgTotal = Self.referenceAlpha.filter { $0 == 0 }.count
        XCTAssertGreaterThan(Double(bgKept) / Double(bgTotal), 0.5, "容差 0 时带噪声的绿幕大部分应留下")
        // 容差 1：全抠光（连前景都没了）
        let loose = try Self.keyedAlpha(ReferenceStates.keyer(tolerance: 1, softness: 0))
        XCTAssertTrue(loose.alpha.allSatisfy { $0 < 0.5 }, "容差 1（半径 0.5）应把所有像素都抠掉")
    }

    /// 关掉抠像：输出 = 原图（绿幕可见），逐像素与不带 keyer 的渲染一致。
    func testKeyer_disabledLeavesPixelsUntouched() throws {
        let off = Bitmap(try Self.renderer.renderOffline(state: Self.state(program: 1, keyer: ReferenceStates.keyer(enabled: false)), inputs: Self.inputs, size: Self.size))
        var plain = Self.state(program: 1, keyer: KeyerSettings())
        plain.inputs[4].settings.keyer = KeyerSettings()
        let ref = Bitmap(try Self.renderer.renderOffline(state: plain, inputs: Self.inputs, size: Self.size))
        XCTAssertEqual(off.bgra, ref.bgra)
        let bg = off.pixel(1700, 950)
        XCTAssertTrue(bg.g > 150 && bg.r < 40, "关掉抠像绿幕应可见，得 \(bg)")
    }

    /// 抠像对该输入出现的每一处都生效：作 PGM 底时（黑底透出）、在多画面缩略图里、在 PVW 里。
    func testKeyer_appliesAsProgramPreviewAndInMultiview() throws {
        var s = MixerState(format: .hd1080p60, inputs: ReferenceStates.phase2Inputs(), program: 5, preview: 5)
        s.inputs[4].settings.keyer = ReferenceStates.keyer()
        let r = try Self.renderer.render(state: s, inputs: Self.inputs, size: Self.size)
        let pgm = Bitmap(r.program).pixel(1700, 950)
        XCTAssertEqual(pgm.r + pgm.g + pgm.b, 0, "PGM 底抠像后背景应是黑，得 \(pgm)")
        let pvw = Bitmap(r.preview).pixel(1700, 950)
        XCTAssertEqual(pvw.r + pvw.g + pvw.b, 0, "PVW 抠像后背景应是黑，得 \(pvw)")
        // 多画面里输入 5 的格子（第 5 格，index 4）：格子右下角区域应是黑而不是绿
        let cell = try XCTUnwrap(MultiviewLayout.inputCell(index: 4, inputCount: 8, width: 1920, height: 1080))
        let mv = Bitmap(r.multiview)
        let p = mv.pixel(Int((cell.x + cell.width * 0.9) * 1920), Int((cell.y + cell.height * 0.9) * 1080))
        XCTAssertLessThan(p.g, 40, "多画面缩略图里绿幕也应被抠掉，得 \(p)")
    }
}
