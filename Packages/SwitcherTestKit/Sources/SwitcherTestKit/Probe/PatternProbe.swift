import CoreVideo
import Foundation
import SwitcherContracts

/// frameprobe 侧的图案读取：解出契约 `TestPattern.decode` 的四样东西，另外带回"这一帧是不是两路合成"的证据（W1-A3）。
///
/// 为什么不直接用契约的 `decode`：转场中间帧（Wipe / Zoom / Fade 的中段）在解码区里是两路的混合，
/// 光看解出来的值判不出真假——32 个块的 28 位 + CRC-4 有 1/16 的概率把半新半旧的码字放过（问题单 G4-…-wipe-zoom-progress）。
/// 这里在读每个块的时候顺手记下三样证据，`SelfCheck` 再把它们和跨帧的节奏对起来：
/// - `blockImpurity`：64 个码字块里最"不纯"的那个离黑（16）/ 白（235）的距离。两路的同一个块在一帧里被混合过就不是纯黑纯白。
/// - `idSpread`：ID 块四象限之间最大的颜色距离。擦边扫过 ID 块时这个块一半新一半旧。
/// - `idDistance`：ID 块颜色离最近调色板色的距离（契约的判据是 ≤ 24；自证用更紧的阈值，见 `SelfCheck.Options.idDistance`）。
/// 外加两块背景灰度：`centerGray`（中心 1/4，与 `ProbeFrame.gray` 同一个数）和 `cornerGray`（ID 块正下方那条）。
/// 这两块是测试图案与节目文件都保证干净的位置（测试标准 §2.1；G4 的叠加与 Stinger PNG 都特意避开图案区和中心采样区）。
///
/// 采样口径与契约逐字对齐：块与 ID 取矩形中心的一半（`Geometry.sampleRect`），亮度按 limited-range Y（BGRA 走 BT.709），
/// 背景灰度按 full-range 电平（BGRA 取 (R+G+B)/3，NV12 由 limited Y 换算）——和 `MediaReader.grayLevel` 同一个公式。
public enum PatternProbe {
    /// 一帧的解码结果 + 证据。
    public struct Reading: Hashable, Sendable {
        /// 契约口径的解码结果（CRC / 调色板距离 24 的判据）。
        public var decoded: TestPattern.Decoded
        /// 64 个码字块里最不纯的那个离黑 / 白更近者的距离（limited-range Y 电平；纯帧 ≈ 0）。
        public var blockImpurity: Double
        /// ID 块四象限两两之间最大的 YCbCr 距离（纯帧 ≈ 0）。
        public var idSpread: Double
        /// ID 块平均色到最近调色板色的距离；读不出色度时 .infinity。
        public var idDistance: Double
        /// 中心采样区（宽高各 1/4）的平均灰度，full-range 电平。
        public var centerGray: Double
        /// ID 块下方那条背景的平均灰度，full-range 电平。
        public var cornerGray: Double
        /// 闪光块离黑 / 白更近者的距离（limited-range Y）。两路的闪光状态不同又被混在一起时它落在中间；
        /// 两路同时闪（合成源共用 t0 时就是这样）则照样是纯白，闪光位仍然可信（A2 的配对不因为转场丢掉）。
        public var flashImpurity: Double

        public init(decoded: TestPattern.Decoded, blockImpurity: Double, idSpread: Double, idDistance: Double,
                    centerGray: Double, cornerGray: Double, flashImpurity: Double) {
            self.decoded = decoded
            self.blockImpurity = blockImpurity
            self.idSpread = idSpread
            self.idDistance = idDistance
            self.centerGray = centerGray
            self.cornerGray = cornerGray
            self.flashImpurity = flashImpurity
        }
        /// 解不出（不支持的像素格式）时的占位。
        public static let unreadable = Reading(decoded: TestPattern.Decoded(frameNumber: nil, hostTimeMs: nil, inputID: nil, flash: false),
                                               blockImpurity: .infinity, idSpread: .infinity, idDistance: .infinity,
                                               centerGray: 0, cornerGray: 0, flashImpurity: .infinity)
    }

    /// 黑块的 limited-range Y。
    public static let blackLevel = 16.0
    /// 白块的 limited-range Y。
    public static let whiteLevel = 235.0

    // MARK: 采样区

    /// 中心采样区：宽高各 1/4（`MediaReader.grayLevel` 用的同一块）。
    public static func centerRect(width w: Int, height h: Int) -> TestPattern.Rect {
        TestPattern.Rect(x: w / 2 - w / 8, y: h / 2 - h / 8, width: max(1, w / 4), height: max(1, h / 4))
    }

    /// ID 块下方的背景条：与 ID 块同高起、下移一个块高，宽 4 个 ID 块。
    /// 挑这个位置的理由：它在测试图案自己的左上角区域里（节目文件的叠加按 G4Factory 的规矩避开图案区），
    /// 又离 ID 块有一个块高的间隔（H.264 的块边振铃不会渗进来），1080p 上是 y ∈ [192, 224]、x ∈ [16, 272]，
    /// 正好在 Stinger PNG 左立柱（图像 22% 高度起）上方。
    public static func cornerRect(geometry g: TestPattern.Geometry, width w: Int, height h: Int) -> TestPattern.Rect {
        let top = min(h - g.blockSize, g.idRect.y + g.idRect.height + g.blockSize / 2)
        let width = min(w - g.idRect.x, g.idRect.width * 4)
        return TestPattern.Rect(x: g.idRect.x, y: top, width: max(1, width), height: max(1, g.blockSize))
    }

    /// 解码依赖的矩形：帧号行、时间戳行、ID 块、中心采样区、ID 邻域条。擦边切开其中任何一个，这一帧就没有单一输入身份。
    public static func decodeRects(geometry g: TestPattern.Geometry, width w: Int, height h: Int) -> [TestPattern.Rect] {
        let rowWidth = TestPattern.blockCount * g.blockSize
        return [
            TestPattern.Rect(x: g.originX, y: g.row1Y, width: rowWidth, height: g.blockSize),
            TestPattern.Rect(x: g.originX, y: g.row2Y, width: rowWidth, height: g.blockSize),
            g.idRect,
            centerRect(width: w, height: h),
            cornerRect(geometry: g, width: w, height: h),
        ]
    }

    // MARK: 读

    /// 读一帧（BGRA / NV12）。
    public static func read(_ planes: TestPattern.PixelPlanes, width w: Int, height h: Int) -> Reading {
        let g = TestPattern.Geometry(width: w, height: h)
        var impurity = 0.0
        var words: [UInt32] = [0, 0]
        for row in 0..<2 {
            var word: UInt32 = 0
            for i in 0..<TestPattern.blockCount {
                let v = meanLuma(planes, g.sampleRect(of: g.blockRect(row: row, index: i)))
                if v > 128 { word |= 1 << UInt32(31 - i) }
                impurity = max(impurity, min(abs(v - blackLevel), abs(v - whiteLevel)))
            }
            words[row] = word
        }
        let idSample = g.sampleRect(of: g.idRect)
        let idColor = meanColor(planes, idSample)
        var spread = 0.0
        if idColor != nil {
            // 四象限：擦边扫过 ID 块时一半是新画面的色
            let qw = max(1, idSample.width / 2), qh = max(1, idSample.height / 2)
            var quads: [YCbCr] = []
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let r = TestPattern.Rect(x: idSample.x + dx * qw, y: idSample.y + dy * qh, width: qw, height: qh)
                    if let c = meanColor(planes, r) { quads.append(c) }
                }
            }
            for a in 0..<quads.count {
                for b in (a + 1)..<quads.count { spread = max(spread, quads[a].distance(to: quads[b])) }
            }
        }
        let idIndex = idColor.flatMap { TestPattern.paletteIndex(nearestTo: $0) }
        let idDistance = idColor.map { c in TestPattern.palette.map { TestPattern.ycbcr(of: $0).distance(to: c) }.min() ?? .infinity } ?? .infinity
        let flashLuma = meanLuma(planes, g.sampleRect(of: g.flashRect))
        let decoded = TestPattern.Decoded(frameNumber: TestPattern.decodeWord(words[0]),
                                          hostTimeMs: TestPattern.decodeWord(words[1]),
                                          inputID: idIndex,
                                          flash: flashLuma > 128)
        return Reading(decoded: decoded, blockImpurity: impurity, idSpread: spread, idDistance: idDistance,
                       centerGray: grayLevel(planes, centerRect(width: w, height: h)),
                       cornerGray: grayLevel(planes, cornerRect(geometry: g, width: w, height: h)),
                       flashImpurity: min(abs(flashLuma - blackLevel), abs(flashLuma - whiteLevel)))
    }

    /// 读一个 CVPixelBuffer（BGRA / NV12）；别的格式返回 nil。
    public static func read(pixelBuffer pb: CVPixelBuffer) -> Reading? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let planes = planes(of: pb) else { return nil }
        return read(planes, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
    }

    // MARK: - 像素

    /// CVPixelBuffer → 契约的平面枚举（BGRA / NV12）。
    public static func planes(of pb: CVPixelBuffer) -> TestPattern.PixelPlanes? {
        switch PixelFormat(cvPixelFormatType: CVPixelBufferGetPixelFormatType(pb)) {
        case .bgra:
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            return .bgra(base: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        case .nv12:
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
            return .nv12(luma: luma, lumaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                         chroma: CVPixelBufferGetBaseAddressOfPlane(pb, 1), chromaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
        default:
            return nil
        }
    }

    /// 区域平均 limited-range 亮度（与契约 `TestPattern.decode` 的判据同一个口径）。
    public static func meanLuma(_ planes: TestPattern.PixelPlanes, _ r: TestPattern.Rect) -> Double {
        switch planes {
        case .bgra:
            return meanColor(planes, r)?.y ?? 0
        case .nv12(let luma, let bpr, _, _):
            var sum = 0
            for y in r.y..<(r.y + r.height) {
                let row = (luma + y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in r.x..<(r.x + r.width) { sum += Int(row[x]) }
            }
            return Double(sum) / Double(r.width * r.height)
        }
    }

    /// 区域平均色（YCbCr）；NV12 没有色度平面时 nil。
    public static func meanColor(_ planes: TestPattern.PixelPlanes, _ r: TestPattern.Rect) -> YCbCr? {
        let n = Double(r.width * r.height)
        switch planes {
        case .bgra(let base, let bpr):
            var rs = 0, gs = 0, bs = 0
            for y in r.y..<(r.y + r.height) {
                let row = (base + y * bpr).assumingMemoryBound(to: UInt32.self)
                for x in r.x..<(r.x + r.width) {
                    let p = row[x]
                    rs += Int((p >> 16) & 0xFF); gs += Int((p >> 8) & 0xFF); bs += Int(p & 0xFF)
                }
            }
            return TestPattern.ycbcr(r: Double(rs) / n, g: Double(gs) / n, b: Double(bs) / n)
        case .nv12(_, _, let chroma, let cbpr):
            guard let chroma else { return nil }
            let y = meanLuma(planes, r)
            var cbs = 0, crs = 0, count = 0
            for cy in (r.y / 2)..<max(r.y / 2 + 1, (r.y + r.height) / 2) {
                let row = (chroma + cy * cbpr).assumingMemoryBound(to: UInt8.self)
                for cx in (r.x / 2)..<max(r.x / 2 + 1, (r.x + r.width) / 2) {
                    cbs += Int(row[2 * cx]); crs += Int(row[2 * cx + 1]); count += 1
                }
            }
            guard count > 0 else { return nil }
            return YCbCr(y: y, cb: Double(cbs) / Double(count), cr: Double(crs) / Double(count))
        }
    }

    /// 区域平均 full-range 灰度电平（BGRA 取 (R+G+B)/3，NV12 由 limited Y 换算）。
    public static func grayLevel(_ planes: TestPattern.PixelPlanes, _ r: TestPattern.Rect) -> Double {
        switch planes {
        case .bgra(let base, let bpr):
            var sum = 0
            for y in r.y..<(r.y + r.height) {
                let row = (base + y * bpr).assumingMemoryBound(to: UInt32.self)
                for x in r.x..<(r.x + r.width) {
                    let p = row[x]
                    sum += Int((p >> 16) & 0xFF) + Int((p >> 8) & 0xFF) + Int(p & 0xFF)
                }
            }
            return Double(sum) / Double(3 * r.width * r.height)
        case .nv12:
            return (meanLuma(planes, r) - 16) * 255 / 219
        }
    }
}
