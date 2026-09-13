// V9 色彩正确性（测试标准 §1 V9、§3 V9、§4：误差 ≤ 1 个 8-bit 电平，16–235 不得被拉伸或压缩）。
// 三种输入格式各走一遍："输入 → 合成 → RGB→NV12 kernel → 读回"，期望值由契约里的 TestPattern.ycbcr（double）算。
import CoreVideo
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class V9ColorTests: XCTestCase {
    static let width = 1920
    static let height = 1080
    static let rampSteps = 32

    /// 一个色块：像素矩形 + 期望的 (Y, Cb, Cr)。
    struct Patch {
        let name: String
        let x: Int, y: Int, width: Int, height: Int
        let expected: YCbCr
    }

    /// 上 3/4 色条（7 条）、下 1/4 灰阶（0–255 步 8，32 级）——与 TestImages.colorBarsBuffer 同一布局。
    static func patches() -> [Patch] {
        var list: [Patch] = []
        let barW = width / 7, barH = height * 3 / 4
        for (i, (r, g, b)) in TestImages.colorBars75.enumerated() {
            list.append(Patch(name: "bar\(i)", x: i * barW, y: 0, width: barW, height: barH,
                              expected: TestPattern.ycbcr(r: Double(r), g: Double(g), b: Double(b))))
        }
        let stepW = width / rampSteps
        for k in 0..<rampSteps {
            let v = Double(k * 8)
            list.append(Patch(name: "gray\(k * 8)", x: k * stepW, y: barH, width: stepW, height: height - barH,
                              expected: TestPattern.ycbcr(r: v, g: v, b: v)))
        }
        return list
    }

    /// 期望值按四舍五入取整（GPU kernel 同样 round，见 Compositor.metal）。
    static func rounded(_ c: YCbCr) -> (Int, Int, Int) { (Int(c.y.rounded()), Int(c.cb.rounded()), Int(c.cr.rounded())) }

    /// 在每个色块中心 16×16 区域检查：每个亮度样本 / 色度样本与期望差 ≤ 1。返回最大误差。
    static func check(_ nv12: CVPixelBuffer, patches: [Patch], file: StaticString = #filePath, line: UInt = #line) -> (maxY: Int, maxC: Int) {
        let planes = PixelBuffers.nv12Planes(nv12)
        var maxY = 0, maxC = 0
        for p in patches {
            let (ey, ecb, ecr) = rounded(p.expected)
            let cx0 = p.x + p.width / 2 - 8, cy0 = p.y + p.height / 2 - 8
            for y in cy0..<(cy0 + 16) {
                for x in cx0..<(cx0 + 16) {
                    let v = Int(planes.luma[y * planes.width + x])
                    let d = abs(v - ey)
                    maxY = max(maxY, d)
                    if d > 1 {
                        XCTFail("\(p.name) 亮度 (\(x),\(y)) = \(v)，期望 \(ey)（\(p.expected.y)）", file: file, line: line)
                        return (maxY, maxC)
                    }
                }
            }
            for cy in (cy0 / 2)..<(cy0 / 2 + 8) {
                for cx in (cx0 / 2)..<(cx0 / 2 + 8) {
                    let cb = Int(planes.chroma[cy * planes.width + cx * 2]), cr = Int(planes.chroma[cy * planes.width + cx * 2 + 1])
                    let d = max(abs(cb - ecb), abs(cr - ecr))
                    maxC = max(maxC, d)
                    if d > 1 {
                        XCTFail("\(p.name) 色度 (\(cx),\(cy)) = (\(cb),\(cr))，期望 (\(ecb),\(ecr))", file: file, line: line)
                        return (maxY, maxC)
                    }
                }
            }
        }
        return (maxY, maxC)
    }

    static func programOnlyState() -> MixerState {
        MixerState(format: .hd1080p60, inputs: ReferenceStates.inputs(count: 1), program: 1, preview: 0)
    }

    /// BGRA 输入 → 合成 → NV12：灰阶每级误差 ≤ 1，且 0 → 16、255 → 235（范围不被拉伸压缩）。
    func testV9_grayRampAndColorBarsBGRAToNV12_withinOneLevel() throws {
        let renderer = try OfflineRenderer()
        let result = try renderer.render(state: Self.programOnlyState(), pixelBuffers: [1: TestImages.colorBarsBuffer()],
                                         size: CGSize(width: Self.width, height: Self.height))
        let (maxY, maxC) = Self.check(result.programNV12, patches: Self.patches())
        print("V9 BGRA→NV12：最大亮度误差 \(maxY)，最大色度误差 \(maxC)")
        XCTAssertLessThanOrEqual(maxY, 1)
        XCTAssertLessThanOrEqual(maxC, 1)
    }

    /// 范围检查单列出来：RGB 0 必须是 Y 16、RGB 255 必须是 Y 235，RGB 128 是 126（16 + 219·128/255 = 125.9）。
    func testV9_limitedRangeEndpointsExact() throws {
        let renderer = try OfflineRenderer()
        let pb = PixelBuffers.bgra(width: 256, height: 64)
        PixelBuffers.fillBGRA(pb) { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }   // 每列一个电平 0–255
        let result = try renderer.render(state: Self.programOnlyState(), pixelBuffers: [1: pb], size: CGSize(width: 256, height: 64))
        let planes = PixelBuffers.nv12Planes(result.programNV12)
        var maxErr = 0
        for level in 0..<256 {
            let expected = Int((16 + 219 * Double(level) / 255).rounded())
            let got = Int(planes.luma[32 * 256 + level])
            maxErr = max(maxErr, abs(got - expected))
            XCTAssertLessThanOrEqual(abs(got - expected), 1, "电平 \(level)：得 \(got) 期望 \(expected)")
        }
        XCTAssertEqual(Int(planes.luma[32 * 256 + 0]), 16, "RGB 0 必须映射到 Y 16")
        XCTAssertEqual(Int(planes.luma[32 * 256 + 255]), 235, "RGB 255 必须映射到 Y 235")
        XCTAssertEqual(Int(planes.luma[32 * 256 + 128]), 126)
        // 灰的色度恒为 128
        for cx in 0..<128 {
            XCTAssertEqual(Int(planes.chroma[16 * 256 + cx * 2]), 128)
            XCTAssertEqual(Int(planes.chroma[16 * 256 + cx * 2 + 1]), 128)
        }
        print("V9 0–255 全电平：最大误差 \(maxErr)")
    }

    /// NV12（limited）输入 → RGB → NV12 往返：每个电平误差 ≤ 1。
    func testV9_nv12RoundTrip_withinOneLevel() throws {
        let patches = Self.patches()
        let pb = PixelBuffers.nv12(width: Self.width, height: Self.height)
        Self.fillYCbCr(pb, patches: patches, uyvy: false)
        let renderer = try OfflineRenderer()
        let result = try renderer.render(state: Self.programOnlyState(), pixelBuffers: [1: pb], size: CGSize(width: Self.width, height: Self.height))
        let (maxY, maxC) = Self.check(result.programNV12, patches: patches)
        print("V9 NV12→RGB→NV12：最大亮度误差 \(maxY)，最大色度误差 \(maxC)")
        XCTAssertLessThanOrEqual(maxY, 1)
        XCTAssertLessThanOrEqual(maxC, 1)
    }

    /// UYVY（DeckLink 8-bit 的格式）输入 → RGB → NV12：同样 ≤ 1。
    func testV9_uyvyInputToNV12_withinOneLevel() throws {
        let patches = Self.patches()
        let pb = PixelBuffers.uyvy(width: Self.width, height: Self.height)
        Self.fillYCbCr(pb, patches: patches, uyvy: true)
        let renderer = try OfflineRenderer()
        let result = try renderer.render(state: Self.programOnlyState(), pixelBuffers: [1: pb], size: CGSize(width: Self.width, height: Self.height))
        let (maxY, maxC) = Self.check(result.programNV12, patches: patches)
        print("V9 UYVY→RGB→NV12：最大亮度误差 \(maxY)，最大色度误差 \(maxC)")
        XCTAssertLessThanOrEqual(maxY, 1)
        XCTAssertLessThanOrEqual(maxC, 1)
    }

    /// full-range NV12（'420f'）输入：Y 0–255 要被正确当成 full range，输出 limited：Y_out = round(16 + 219·Y/255)。
    func testV9_fullRangeNV12Input_mapsIntoLimited() throws {
        let pb = PixelBuffers.nv12(width: 512, height: 64, full: true)
        PixelBuffers.fillNV12(pb, luma: { x, _ in UInt8(x / 2) }, chroma: { _, _ in (128, 128) })   // 每两列一个电平
        let renderer = try OfflineRenderer()
        let result = try renderer.render(state: Self.programOnlyState(), pixelBuffers: [1: pb], size: CGSize(width: 512, height: 64))
        let planes = PixelBuffers.nv12Planes(result.programNV12)
        var maxErr = 0
        for level in 0..<256 {
            let expected = Int((16 + 219 * Double(level) / 255).rounded())
            let got = Int(planes.luma[32 * 512 + level * 2])
            maxErr = max(maxErr, abs(got - expected))
            XCTAssertLessThanOrEqual(abs(got - expected), 1, "full-range Y \(level)：得 \(got) 期望 \(expected)")
        }
        XCTAssertEqual(Int(planes.luma[32 * 512]), 16)
        XCTAssertEqual(Int(planes.luma[32 * 512 + 255 * 2]), 235)
        print("V9 full-range NV12 输入：最大误差 \(maxErr)")
    }

    /// BT.601 矩阵的 NV12 输入：着色器按 601 解、输出按 709 编，色条的期望值 = 601 解出的 RGB 再经 709。
    func testV9_bt601InputIsConvertedThrough709Output() throws {
        // 用 601 把 75% 色条编成 YCbCr，标 bt601；解回来应是同样的 RGB，再经 709 输出 → 期望 = 709 的 ycbcr(rgb)
        func ycbcr601(_ r: Double, _ g: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = 128 + 224 * (b - y) / 1.772 / 255, cr = 128 + 224 * (r - y) / 1.402 / 255
            return (UInt8((16 + 219 * y / 255).rounded()), UInt8(cb.rounded()), UInt8(cr.rounded()))
        }
        let patches = Self.patches().filter { $0.name.hasPrefix("bar") }
        let pb = PixelBuffers.nv12(width: Self.width, height: Self.height)
        let barW = Self.width / 7
        let codes = TestImages.colorBars75.map { ycbcr601(Double($0.0), Double($0.1), Double($0.2)) }
        PixelBuffers.fillNV12(pb, luma: { x, _ in codes[min(6, x / barW)].0 },
                              chroma: { cx, _ in (codes[min(6, cx * 2 / barW)].1, codes[min(6, cx * 2 / barW)].2) })
        // 601 输入要经 Frame.color 告诉渲染器；OfflineRenderer 按像素格式推色彩，所以这里直接走内部 API 拼 Frame
        let renderer = try OfflineRenderer()
        let frameColor = ColorInfo(primaries: .bt709, transfer: .bt709, matrix: .bt601, range: .limited)
        let result = try renderer.render(state: Self.programOnlyState(), frames: [1: Frame(pixelBuffer: pb, pts: .zero, duration: .zero, color: frameColor, inputNumber: 1, sequence: 0, ingressTime: .zero)],
                                         size: CGSize(width: Self.width, height: Self.height))
        // 601 编码本身有一次舍入（≤ 0.5 电平），加上输出舍入，容差放 2
        let planes = PixelBuffers.nv12Planes(result.programNV12)
        for p in patches {
            let (ey, ecb, ecr) = Self.rounded(p.expected)
            let x = p.x + p.width / 2, y = p.y + p.height / 2
            let gy = Int(planes.luma[y * planes.width + x])
            let gcb = Int(planes.chroma[(y / 2) * planes.width + (x / 2) * 2]), gcr = Int(planes.chroma[(y / 2) * planes.width + (x / 2) * 2 + 1])
            XCTAssertLessThanOrEqual(abs(gy - ey), 2, "\(p.name) Y \(gy) vs \(ey)")
            XCTAssertLessThanOrEqual(abs(gcb - ecb), 2, "\(p.name) Cb \(gcb) vs \(ecb)")
            XCTAssertLessThanOrEqual(abs(gcr - ecr), 2, "\(p.name) Cr \(gcr) vs \(ecr)")
        }
    }

    /// 把色块的期望 YCbCr 写进 NV12 / UYVY 缓冲。
    static func fillYCbCr(_ pb: CVPixelBuffer, patches: [Patch], uyvy: Bool) {
        func patch(at x: Int, _ y: Int) -> (Int, Int, Int) {
            for p in patches where x >= p.x && x < p.x + p.width && y >= p.y && y < p.y + p.height { return rounded(p.expected) }
            return (16, 128, 128)
        }
        if uyvy {
            PixelBuffers.fillUYVY(pb, luma: { x, y in UInt8(patch(at: x, y).0) },
                                  chroma: { cx, y in let c = patch(at: cx * 2, y); return (UInt8(c.1), UInt8(c.2)) })
        } else {
            PixelBuffers.fillNV12(pb, luma: { x, y in UInt8(patch(at: x, y).0) },
                                  chroma: { cx, cy in let c = patch(at: cx * 2, cy * 2); return (UInt8(c.1), UInt8(c.2)) })
        }
    }
}
