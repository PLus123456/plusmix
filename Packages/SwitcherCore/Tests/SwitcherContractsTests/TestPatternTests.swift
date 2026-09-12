import XCTest
import Accelerate
import CoreVideo
@testable import SwitcherContracts

/// 测试图案契约：编解码恒等、退化后仍可解、校验位、调色板、几何布局。
final class TestPatternTests: XCTestCase {

    // MARK: - 码字层（28 位数据 + 4 位 CRC-4）

    /// 与 Python 独立实现（scratchpad/probe/crc4.py，多项式 x^4+x+1，初值 0xF，MSB 先）算出的值逐一比对。
    func testP1_pattern_crc4_matchesIndependentReference() {
        let reference: [(UInt32, UInt8)] = [
            (0x0000000, 0x7), (0x0000001, 0x4), (0xFFFFFFF, 0xB), (0x1234567, 0xD), (0x0ABCDEF, 0xD),
            (216_000, 0xF), (1_728_000, 0xB), (0x8000000, 0x5), (0x5555555, 0x3), (0xAAAAAAA, 0xF),
        ]
        for (data, crc) in reference {
            XCTAssertEqual(TestPattern.crc4(data), crc, String(format: "crc4(0x%07X)", data))
        }
    }

    /// 编解码恒等 10 万随机帧号（码字层：编码 → 32 位字 → 解码）。
    func testP1_pattern_codewordRoundTrip100k() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100_000 {
            let v = UInt32.random(in: 0...TestPattern.dataMask, using: &rng)
            let word = TestPattern.encodeWord(v)
            XCTAssertEqual(word >> 4, v)
            XCTAssertEqual(TestPattern.decodeWord(word), v)
        }
        // 超过 28 位的输入被截断到 28 位
        XCTAssertEqual(TestPattern.decodeWord(TestPattern.encodeWord(0xFFFF_FFFF)), TestPattern.dataMask)
    }

    /// 校验位能捕获任意单块翻转（数据块和校验块都算）。
    func testP1_pattern_checkCatchesSingleBlockFlip() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let v = UInt32.random(in: 0...TestPattern.dataMask, using: &rng)
            let word = TestPattern.encodeWord(v)
            for bit in 0..<32 {
                XCTAssertNil(TestPattern.decodeWord(word ^ (1 << UInt32(bit))), "翻转第 \(bit) 位未被发现，v=\(v)")
            }
        }
        // 全 0 和全 1 的字（全黑 / 全白画面）都不是合法码字
        XCTAssertNil(TestPattern.decodeWord(0))
        XCTAssertNil(TestPattern.decodeWord(0xFFFF_FFFF))
    }

    // MARK: - 几何

    func testP1_pattern_geometryAt1080pMatchesSpec() {
        let g = TestPattern.Geometry(width: 1920, height: 1080)
        XCTAssertEqual(g.blockSize, 32)
        XCTAssertEqual(g.originX, 16)
        XCTAssertEqual(g.row1Y, 16)
        XCTAssertEqual(g.row2Y, 64)
        XCTAssertEqual(g.idRect, TestPattern.Rect(x: 16, y: 112, width: 64, height: 64))
        XCTAssertEqual(g.flashRect, TestPattern.Rect(x: 1920 - 16 - 64, y: 16, width: 64, height: 64))
        XCTAssertEqual(g.blockRect(row: 0, index: 0), TestPattern.Rect(x: 16, y: 16, width: 32, height: 32))
        XCTAssertEqual(g.blockRect(row: 1, index: 31), TestPattern.Rect(x: 16 + 31 * 32, y: 64, width: 32, height: 32))
        // 每块取中心 16×16
        XCTAssertEqual(g.sampleRect(of: g.blockRect(row: 0, index: 0)), TestPattern.Rect(x: 24, y: 24, width: 16, height: 16))
        // 行 1 / 行 2 / 输入 ID / 闪光互不重叠
        let last = g.blockRect(row: 0, index: 31)
        XCTAssertLessThan(last.x + last.width, g.flashRect.x)
        XCTAssertLessThanOrEqual(g.row1Y + g.blockSize, g.row2Y)
        XCTAssertLessThanOrEqual(g.row2Y + g.blockSize, g.idRect.y)
    }

    func testP1_pattern_geometryScalesWithWidth() {
        let g4k = TestPattern.Geometry(width: 3840, height: 2160)
        XCTAssertEqual(g4k.blockSize, 64)
        XCTAssertEqual(g4k.row2Y, 128)
        XCTAssertEqual(g4k.idRect, TestPattern.Rect(x: 32, y: 224, width: 128, height: 128))
        let g720 = TestPattern.Geometry(width: 1280, height: 720)
        XCTAssertEqual(g720.blockSize, 20)      // 21.33 → 向下取偶
        XCTAssertEqual(g720.originX, 10)
        for (w, h) in [(1280, 720), (1366, 768), (1024, 576), (640, 360), (3440, 1440), (1080, 1920)] {
            let g = TestPattern.Geometry(width: w, height: h)
            XCTAssertTrue(g.blockSize % 2 == 0 && g.originX % 2 == 0 && g.idRect.y % 2 == 0, "\(w)×\(h) 坐标必须是偶数（4:2:0 色度对齐）")
            let last = g.blockRect(row: 1, index: 31)
            XCTAssertLessThan(last.x + last.width, g.flashRect.x, "\(w)×\(h) 帧号行与闪光块重叠")
            XCTAssertLessThan(g.idRect.y + g.idRect.height, h)
            XCTAssertGreaterThanOrEqual(g.sampleRect(of: last).width, 4)
        }
    }

    // MARK: - 图像层往返

    func testP1_pattern_imageRoundTrip_bgra1080p() {
        let img = Image.bgra(width: 1920, height: 1080)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<1_500 {
            let c = Self.randomContent(&rng, background: i % 2 == 0 ? .gray(level: UInt8.random(in: 0...255, using: &rng)) : .gradient)
            TestPattern.draw(c, into: img.planes, width: img.width, height: img.height)
            let d = TestPattern.decode(img.planes, width: img.width, height: img.height)
            XCTAssertEqual(d.frameNumber, c.frameNumber)
            XCTAssertEqual(d.hostTimeMs, c.hostTimeMs)
            XCTAssertEqual(d.inputID, c.inputID)
            XCTAssertEqual(d.flash, c.flash)
            if d.frameNumber != c.frameNumber { break }
        }
    }

    func testP1_pattern_imageRoundTrip_nv12_1080p() {
        let img = Image.nv12(width: 1920, height: 1080)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<600 {
            let c = Self.randomContent(&rng, background: .gray(level: 64))
            TestPattern.draw(c, into: img.planes, width: img.width, height: img.height)
            let d = TestPattern.decode(img.planes, width: img.width, height: img.height)
            XCTAssertEqual(d.frameNumber, c.frameNumber)
            XCTAssertEqual(d.hostTimeMs, c.hostTimeMs)
            XCTAssertEqual(d.inputID, c.inputID)
            XCTAssertEqual(d.flash, c.flash)
            if d.frameNumber != c.frameNumber { break }
        }
    }

    func testP1_pattern_imageRoundTrip_otherSizes() {
        var rng = SystemRandomNumberGenerator()
        for (w, h) in [(1280, 720), (3840, 2160), (640, 360), (1366, 768)] {
            for img in [Image.bgra(width: w, height: h), Image.nv12(width: w, height: h)] {
                for _ in 0..<100 {
                    let c = Self.randomContent(&rng, background: .gradient)
                    TestPattern.draw(c, into: img.planes, width: w, height: h)
                    let d = TestPattern.decode(img.planes, width: w, height: h)
                    XCTAssertEqual(d.frameNumber, c.frameNumber, "\(w)×\(h)")
                    XCTAssertEqual(d.hostTimeMs, c.hostTimeMs, "\(w)×\(h)")
                    XCTAssertEqual(d.inputID, c.inputID, "\(w)×\(h)")
                    XCTAssertEqual(d.flash, c.flash, "\(w)×\(h)")
                }
            }
        }
    }

    /// 同一内容画进 BGRA 和 NV12，两边解出来一样；NV12 的灰底是 BT.709 limited 电平（64 → Y 71）。
    func testP1_pattern_bgraAndNV12Agree() {
        let a = Image.bgra(width: 1920, height: 1080), b = Image.nv12(width: 1920, height: 1080)
        let c = TestPattern.Content(frameNumber: 123_456, hostTimeMs: 9_999_999, inputID: 7, flash: true, background: .gray(level: 64))
        TestPattern.draw(c, into: a.planes, width: 1920, height: 1080)
        TestPattern.draw(c, into: b.planes, width: 1920, height: 1080)
        XCTAssertEqual(TestPattern.decode(a.planes, width: 1920, height: 1080), TestPattern.decode(b.planes, width: 1920, height: 1080))
        XCTAssertEqual(a.bgraPixel(x: 1000, y: 800), 0xFF40_4040)      // 底色 BGRA = (64,64,64,255)
        XCTAssertEqual(b.lumaPixel(x: 1000, y: 800), 71)               // 16 + 219 × 64 / 255 = 70.96
        // 帧号 123456 = 0x1E240：第 27 位是 0 → 块 0 黑（Y 16）；第 16 位是 1 → 码字第 20 位 → 块 11 白（Y 235）
        XCTAssertEqual(b.lumaPixel(x: 24, y: 24), 16)
        XCTAssertEqual(b.lumaPixel(x: 16 + 11 * 32 + 8, y: 24), 235)
        XCTAssertEqual(a.bgraPixel(x: 16 + 11 * 32 + 8, y: 24), 0xFFFF_FFFF)
    }

    /// 全黑 / 全白画面：帧号、时间戳、输入 ID 都解成 nil，不误报。
    func testP1_pattern_blankFramesDecodeToNil() {
        let img = Image.bgra(width: 1920, height: 1080)
        for pixel: UInt32 in [0xFF00_0000, 0xFFFF_FFFF, 0xFF80_8080] {
            img.fill(pixel)
            let d = TestPattern.decode(img.planes, width: 1920, height: 1080)
            XCTAssertNil(d.frameNumber)
            XCTAssertNil(d.hostTimeMs)
            XCTAssertNil(d.inputID, "纯色 \(String(pixel, radix: 16)) 不该解出输入 ID")
        }
        img.fill(0xFFFF_FFFF)
        XCTAssertTrue(TestPattern.decode(img.planes, width: 1920, height: 1080).flash)
        img.fill(0xFF00_0000)
        XCTAssertFalse(TestPattern.decode(img.planes, width: 1920, height: 1080).flash)
    }

    /// 高斯模糊 σ = 1.5 + 4:2:0 降采样 + ±10 电平噪声后解码正确率 100%。
    func testP1_pattern_degradedDecodeIs100Percent() {
        let width = 1920, height = 1080
        let src = Image.bgra(width: width, height: height)
        let dst = Image.nv12(width: width, height: height)
        var rng = SystemRandomNumberGenerator()
        var ok = 0
        let frames = 60
        for _ in 0..<frames {
            let level = UInt8.random(in: 0...255, using: &rng)
            let background: TestPattern.Background = Bool.random(using: &rng) ? .gray(level: level) : .gradient
            let c = Self.randomContent(&rng, background: background)
            TestPattern.draw(c, into: src.planes, width: width, height: height)
            Self.degrade(bgra: src, intoNV12: dst, sigma: 1.5, noise: 10, rng: &rng)
            let d = TestPattern.decode(dst.planes, width: width, height: height)
            if d.frameNumber == c.frameNumber && d.hostTimeMs == c.hostTimeMs && d.inputID == c.inputID && d.flash == c.flash {
                ok += 1
            } else {
                XCTFail("退化后解码错误：期望 \(c)，得到 \(d)")
            }
        }
        XCTAssertEqual(ok, frames, "退化解码正确率 \(ok)/\(frames)")
        print("退化解码（σ=1.5 + 4:2:0 + ±10）：\(ok)/\(frames) = \(100 * ok / frames)%")
    }

    // MARK: - 调色板

    /// 任意两色 YCbCr 距离 ≥ 阈值（用测试里独立写的 BT.709 limited 公式算）。
    func testP1_palette_pairwiseYCbCrDistance() {
        let p = TestPattern.palette
        XCTAssertEqual(p.count, 16)
        XCTAssertEqual(Set(p).count, 16)
        var minDistance = Double.infinity
        for i in 0..<p.count {
            for j in (i + 1)..<p.count {
                let a = Self.ycbcr709(p[i]), b = Self.ycbcr709(p[j])
                let d = ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
                minDistance = min(minDistance, d)
                XCTAssertGreaterThanOrEqual(d, TestPattern.minimumPaletteDistance, "颜色 \(i) 与 \(j) 距离 \(d) 小于阈值")
            }
        }
        print("调色板最小两两距离：\(minDistance)（阈值 \(TestPattern.minimumPaletteDistance)）")
        // 不含纯黑纯白（黑场 / 过曝帧不能误解成某路输入）
        XCTAssertFalse(p.contains(RGB8(red: 0, green: 0, blue: 0)))
        XCTAssertFalse(p.contains(RGB8(red: 255, green: 255, blue: 255)))
        // 每个颜色自己能解回自己；加 ±10 噪声也能
        for (i, color) in p.enumerated() {
            let y = TestPattern.ycbcr(of: color)
            XCTAssertEqual(TestPattern.paletteIndex(nearestTo: y), i)
            XCTAssertEqual(TestPattern.paletteIndex(nearestTo: YCbCr(y: y.y + 10, cb: y.cb - 10, cr: y.cr + 10)), i)
        }
        // 离谁都远的颜色解成 nil
        XCTAssertNil(TestPattern.paletteIndex(nearestTo: YCbCr(y: 16, cb: 128, cr: 128)))
    }

    // MARK: - 闪光节奏与 CVPixelBuffer 便利接口

    func testP1_pattern_flashTick() {
        XCTAssertTrue(TestPattern.isFlashTick(.zero, frameRate: .fps5994))
        XCTAssertTrue(TestPattern.isFlashTick(Tick(60), frameRate: .fps5994))
        XCTAssertFalse(TestPattern.isFlashTick(Tick(59), frameRate: .fps5994))
        XCTAssertTrue(TestPattern.isFlashTick(Tick(30), frameRate: .fps30))
        XCTAssertTrue(TestPattern.isFlashTick(Tick(-60), frameRate: .fps60))
        XCTAssertEqual(TestPattern.flashPeriodTicks(frameRate: .fps5994), 60)
        XCTAssertEqual(TestPattern.flashPeriod(frameRate: .fps5994), Rational(1001, 1000))
        XCTAssertEqual(TestPattern.flashPeriod(frameRate: .fps60), .one)
    }

    func testP1_pattern_contentFromHostTime() {
        let tb = MachTimebase(numer: 1, denom: 1)
        let t = HostTime(nanoseconds: 123_456_789_012, timebase: tb)   // 123456.789 ms
        let c = TestPattern.Content(frameNumber: 1, hostTime: t, inputID: 0, flash: false, timebase: tb)
        XCTAssertEqual(c.hostTimeMs, 123_456)
        XCTAssertEqual(TestPattern.Content(frameNumber: 0xFFFF_FFFF, hostTimeMs: 0xFFFF_FFFF, inputID: 15, flash: false).frameNumber, TestPattern.dataMask)
    }

    func testP1_pattern_cvPixelBufferRoundTrip() throws {
        for (fmt, name) in [(kCVPixelFormatType_32BGRA, "BGRA"), (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "NV12")] {
            var pb: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, fmt, attrs as CFDictionary, &pb), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pb)
            let c = TestPattern.Content(frameNumber: 777_777, hostTimeMs: 42, inputID: 3, flash: true, background: .gray(level: 192))
            XCTAssertTrue(TestPattern.draw(c, into: buffer), name)
            let d = try XCTUnwrap(TestPattern.decode(pixelBuffer: buffer), name)
            XCTAssertEqual(d, TestPattern.Decoded(frameNumber: 777_777, hostTimeMs: 42, inputID: 3, flash: true), name)
        }
        var bad: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_422YpCbCr8, nil, &bad)
        XCTAssertFalse(TestPattern.draw(.init(frameNumber: 0, hostTimeMs: 0, inputID: 0, flash: false), into: try XCTUnwrap(bad)), "UYVY 不支持画图案")
    }

    // MARK: - 工具

    static func randomContent(_ rng: inout SystemRandomNumberGenerator, background: TestPattern.Background) -> TestPattern.Content {
        TestPattern.Content(frameNumber: UInt32.random(in: 0...TestPattern.dataMask, using: &rng),
                            hostTimeMs: UInt32.random(in: 0...TestPattern.dataMask, using: &rng),
                            inputID: Int.random(in: 0...15, using: &rng),
                            flash: Bool.random(using: &rng),
                            background: background)
    }

    /// 独立实现的 BT.709 limited-range 变换（和契约里的实现分开写，互相印证）。
    static func ycbcr709(_ c: RGB8) -> (Double, Double, Double) {
        let r = Double(c.red), g = Double(c.green), b = Double(c.blue)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (16 + 219 * y / 255, 128 + 224 * (b - y) / 1.8556 / 255, 128 + 224 * (r - y) / 1.5748 / 255)
    }

    /// BGRA → 平面 YCbCr → 高斯模糊 σ → 色度 2×2 平均（4:2:0）→ ±noise 均匀噪声 → NV12。
    /// 只处理顶部 `bandHeight` 行：图案的四样东西都在 y < 176（1080p），其余画面解码不读，处理它只是浪费时间。
    static func degrade(bgra src: Image, intoNV12 dst: Image, sigma: Double, noise: Int, rng: inout SystemRandomNumberGenerator, bandHeight: Int = 208) {
        let w = src.width, h = min(src.height, bandHeight)
        var yPlane = [Float](repeating: 0, count: w * h)
        var cbPlane = [Float](repeating: 0, count: w * h)
        var crPlane = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = src.bgraPixel(x: x, y: y)
                let c = RGB8(red: UInt8((p >> 16) & 0xFF), green: UInt8((p >> 8) & 0xFF), blue: UInt8(p & 0xFF))
                let (yy, cb, cr) = ycbcr709(c)
                yPlane[y * w + x] = Float(yy); cbPlane[y * w + x] = Float(cb); crPlane[y * w + x] = Float(cr)
            }
        }
        // 高斯核（半径 4，σ = 1.5）
        let radius = 4
        var kernel1D: [Float] = (-radius...radius).map { (i: Int) -> Float in
            let x = Double(i)
            return Float(Darwin.exp(-(x * x) / (2 * sigma * sigma)))
        }
        let sum = kernel1D.reduce(0, +); kernel1D = kernel1D.map { $0 / sum }
        var kernel2D = [Float](repeating: 0, count: (2 * radius + 1) * (2 * radius + 1))
        for i in 0...(2 * radius) { for j in 0...(2 * radius) { kernel2D[i * (2 * radius + 1) + j] = kernel1D[i] * kernel1D[j] } }
        func blur(_ plane: inout [Float]) {
            var out = [Float](repeating: 0, count: w * h)
            plane.withUnsafeMutableBufferPointer { s in
                out.withUnsafeMutableBufferPointer { d in
                    var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    let err = vImageConvolve_PlanarF(&sb, &db, nil, 0, 0, kernel2D, UInt32(2 * radius + 1), UInt32(2 * radius + 1), 0, vImage_Flags(kvImageEdgeExtend))
                    precondition(err == kvImageNoError)
                }
            }
            plane = out
        }
        blur(&yPlane); blur(&cbPlane); blur(&crPlane)
        func noisy(_ v: Float) -> UInt8 { UInt8(clamping: Int(v.rounded()) + Int.random(in: -noise...noise, using: &rng)) }
        for y in 0..<h {
            for x in 0..<w { dst.setLuma(x: x, y: y, noisy(yPlane[y * w + x])) }
        }
        for cy in 0..<(h / 2) {
            for cx in 0..<(w / 2) {
                let i0 = (2 * cy) * w + 2 * cx, i1 = i0 + 1, i2 = i0 + w, i3 = i2 + 1
                let cb = (cbPlane[i0] + cbPlane[i1] + cbPlane[i2] + cbPlane[i3]) / 4
                let cr = (crPlane[i0] + crPlane[i1] + crPlane[i2] + crPlane[i3]) / 4
                dst.setChroma(cx: cx, cy: cy, cb: noisy(cb), cr: noisy(cr))
            }
        }
    }
}

/// 测试用像素缓冲：自己分配，对齐 64，行距按 CVPixelBuffer 的习惯补到 64 的倍数。
final class Image {
    let width: Int, height: Int
    let planes: TestPattern.PixelPlanes
    private let storage: [UnsafeMutableRawPointer]
    private let bytesPerRow: Int, chromaBytesPerRow: Int

    private init(width: Int, height: Int, planes: TestPattern.PixelPlanes, storage: [UnsafeMutableRawPointer], bpr: Int, cbpr: Int) {
        self.width = width; self.height = height; self.planes = planes; self.storage = storage; bytesPerRow = bpr; chromaBytesPerRow = cbpr
    }
    deinit { storage.forEach { $0.deallocate() } }

    static func bgra(width: Int, height: Int) -> Image {
        let bpr = (width * 4 + 63) & ~63
        let p = UnsafeMutableRawPointer.allocate(byteCount: bpr * height, alignment: 64)
        p.initializeMemory(as: UInt8.self, repeating: 0, count: bpr * height)
        return Image(width: width, height: height, planes: .bgra(base: p, bytesPerRow: bpr), storage: [p], bpr: bpr, cbpr: 0)
    }
    static func nv12(width: Int, height: Int) -> Image {
        let bpr = (width + 63) & ~63
        let y = UnsafeMutableRawPointer.allocate(byteCount: bpr * height, alignment: 64)
        let c = UnsafeMutableRawPointer.allocate(byteCount: bpr * (height / 2), alignment: 64)
        y.initializeMemory(as: UInt8.self, repeating: 0, count: bpr * height)
        c.initializeMemory(as: UInt8.self, repeating: 128, count: bpr * (height / 2))
        return Image(width: width, height: height, planes: .nv12(luma: y, lumaBytesPerRow: bpr, chroma: c, chromaBytesPerRow: bpr), storage: [y, c], bpr: bpr, cbpr: bpr)
    }
    func bgraPixel(x: Int, y: Int) -> UInt32 {
        guard case .bgra(let base, let bpr) = planes else { fatalError() }
        return base.load(fromByteOffset: y * bpr + x * 4, as: UInt32.self)
    }
    func lumaPixel(x: Int, y: Int) -> UInt8 {
        guard case .nv12(let luma, let bpr, _, _) = planes else { fatalError() }
        return luma.load(fromByteOffset: y * bpr + x, as: UInt8.self)
    }
    func setLuma(x: Int, y: Int, _ v: UInt8) {
        guard case .nv12(let luma, let bpr, _, _) = planes else { fatalError() }
        luma.storeBytes(of: v, toByteOffset: y * bpr + x, as: UInt8.self)
    }
    func setChroma(cx: Int, cy: Int, cb: UInt8, cr: UInt8) {
        guard case .nv12(_, _, let chroma?, let cbpr) = planes else { fatalError() }
        chroma.storeBytes(of: cb, toByteOffset: cy * cbpr + cx * 2, as: UInt8.self)
        chroma.storeBytes(of: cr, toByteOffset: cy * cbpr + cx * 2 + 1, as: UInt8.self)
    }
    func fill(_ pixel: UInt32) {
        guard case .bgra(let base, let bpr) = planes else { fatalError() }
        for y in 0..<height { (base + y * bpr).assumingMemoryBound(to: UInt32.self).update(repeating: pixel, count: width) }
    }
}
