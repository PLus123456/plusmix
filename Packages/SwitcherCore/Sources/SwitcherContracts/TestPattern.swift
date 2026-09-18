import CoreVideo

/// 合成视频图案（测试标准 §2.1）的 CPU 参考实现：能写、能读 BGRA 和 NV12。
/// 引擎内置合成源（W1-A）、frameprobe（W1-A）、编码测试（W1-E）都用这一份代码，所以布局在这里冻结。
///
/// 布局（以 1920×1080 定义；其他尺寸所有坐标按 width / 1920 缩放并取偶，见 `Geometry`）：
/// - 行 1（y = 16）：帧号，32 个 32×32 黑白块 = 28 位数据 + 4 位 CRC-4；块 0 在最左，是码字的最高位。
/// - 行 2（y = 64）：生成时 host time 的毫秒（mod 2^28），同样编码。
/// - 输入 ID：(16, 112) 起 64×64 纯色块，16 色调色板（`palette`），任意两色 BT.709 limited YCbCr 距离 ≥ `minimumPaletteDistance`。
/// - 闪光：右上角 (width − 80, 16) 起 64×64；tick % 整数帧率 == 0 的帧全白，其余全黑（`isFlashTick`）。
/// - 其余画面：纯灰（V7 用 64 / 192，值是 full-range RGB 电平）、水平渐变，或灰底叠零均值噪声（`.noise`，提案 006：让 E2 在长跑里有东西可压）。
/// 解码：每块取中心一半区域（1080p 下 16×16）的均值，limited-range Y > 128 记 1；CRC 不对返回 nil。
///
/// 与测试标准 §2.1 的唯一偏离：帧号从 16 块 12 位扩到 32 块 28 位。12 位 68 秒就回绕，8 小时长稳会歧义；
/// 28 位在 60 fps 下能撑 51 天。这是 P1 唯一允许偏离测试标准的地方（落地方案 §1.3 第 4 条）。
public enum TestPattern {
    /// 定义布局用的参考宽。
    public static let referenceWidth = 1920
    /// 参考高。
    public static let referenceHeight = 1080
    /// 每行块数。
    public static let blockCount = 32
    /// 数据位数。
    public static let dataBits = 28
    /// 校验位数。
    public static let checkBits = 4
    /// 28 位数据掩码。
    public static let dataMask: UInt32 = (1 << 28) - 1
    /// 调色板颜色数。
    public static let paletteSize = 16
    /// 调色板两两 YCbCr 距离的下限；解码时离最近颜色超过它的一半就判 nil。
    public static let minimumPaletteDistance: Double = 48

    // MARK: 内容

    /// 画面底色。
    public enum Background: Hashable, Codable, Sendable {
        /// 纯灰，level 是 full-range RGB 电平（写 NV12 时换算成 limited Y）。
        case gray(level: UInt8)
        /// 水平渐变 0 → 255。
        case gradient
        /// 灰底 level 上叠零均值噪声（提案 006，P2 落地）：每个像素 = level + n，n 在 −amplitude…+amplitude 上均匀（full-range 电平，越出 0…255 截断），
        /// 三个通道同值（灰噪声；NV12 只动亮度平面，色度保持 128）。确定性伪随机：seed、帧号、行号、列号决定（`noiseValue`），
        /// 同一 (seed, frameNumber) 画两次逐像素相同，帧号变了整幅噪声就变——码率控制才真的工作。
        /// 帧号 / 时间戳 / 输入 ID / 闪光块区域不加噪声（四样东西盖在噪声上面，解码规则不变）；
        /// 中心 1/4 区域的均值 ≈ level（V6 / V7 不受影响）；level ± amplitude 越出 0…255 时截断会让均值偏离 level，V7 用 64 / 192 配 amplitude ≤ 63 没事。
        /// JSON：`{"noise": {"level": 128, "amplitude": 24, "seed": 7}}`。
        case noise(level: UInt8, amplitude: UInt8, seed: UInt64)
    }

    /// 一帧要烧进去的内容。
    public struct Content: Hashable, Sendable {
        /// 帧号，28 位。
        public var frameNumber: UInt32
        /// 生成时刻的毫秒数，28 位。
        public var hostTimeMs: UInt32
        /// 调色板索引 0–15。
        public var inputID: Int
        /// 是否闪光帧。
        public var flash: Bool
        /// 底色。
        public var background: Background

        public init(frameNumber: UInt32, hostTimeMs: UInt32, inputID: Int, flash: Bool, background: Background = .gray(level: 128)) {
            precondition((0..<TestPattern.paletteSize).contains(inputID), "inputID 必须在 0…15")
            self.frameNumber = frameNumber & TestPattern.dataMask
            self.hostTimeMs = hostTimeMs & TestPattern.dataMask
            self.inputID = inputID
            self.flash = flash
            self.background = background
        }

        /// 用 host time 直接填毫秒字段。
        public init(frameNumber: UInt32, hostTime: HostTime, inputID: Int, flash: Bool, background: Background = .gray(level: 128),
                    timebase: MachTimebase = HostClock.timebase) {
            let ms = UInt32(truncatingIfNeeded: hostTime.nanoseconds(timebase: timebase) / 1_000_000)
            self.init(frameNumber: frameNumber, hostTimeMs: ms, inputID: inputID, flash: flash, background: background)
        }
    }

    /// 解码结果；解不出的字段为 nil。
    public struct Decoded: Hashable, Sendable {
        /// 帧号；CRC 不对为 nil。
        public var frameNumber: UInt32?
        /// 时间戳毫秒；CRC 不对为 nil。
        public var hostTimeMs: UInt32?
        /// 输入 ID；离调色板太远为 nil。
        public var inputID: Int?
        /// 闪光块是否为白。
        public var flash: Bool
        public init(frameNumber: UInt32?, hostTimeMs: UInt32?, inputID: Int?, flash: Bool) {
            self.frameNumber = frameNumber
            self.hostTimeMs = hostTimeMs
            self.inputID = inputID
            self.flash = flash
        }
    }

    // MARK: 几何

    /// 像素矩形。
    public struct Rect: Hashable, Sendable {
        /// 左上 x（像素）。
        public var x: Int
        /// 左上 y（像素）。
        public var y: Int
        /// 宽（像素）。
        public var width: Int
        /// 高（像素）。
        public var height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// 某个尺寸下的实际坐标。1080p 单位值 v 映射为 (v × width / 1920) 向下取偶，所以 4:2:0 的色度块永远对齐。
    public struct Geometry: Hashable, Sendable {
        /// 画面宽。
        public let width: Int
        /// 画面高。
        public let height: Int
        /// 块边长。
        public let blockSize: Int
        /// 每行第一块的 x。
        public let originX: Int
        /// 帧号行的 y。
        public let row1Y: Int
        /// 时间戳行的 y。
        public let row2Y: Int
        /// 输入 ID 色块。
        public let idRect: Rect
        /// 闪光块。
        public let flashRect: Rect
        /// 采样时每边收进的像素数（块的 1/4）。
        public let sampleInset: Int

        public init(width: Int, height: Int) {
            precondition(width >= 320 && height >= 180, "图案最小 320×180")
            func s(_ v: Int) -> Int { max(2, (v * width / TestPattern.referenceWidth) & ~1) }
            self.width = width
            self.height = height
            blockSize = s(32)
            originX = s(16)
            row1Y = s(16)
            row2Y = s(64)
            idRect = Rect(x: s(16), y: s(112), width: s(64), height: s(64))
            flashRect = Rect(x: width - s(16) - s(64), y: s(16), width: s(64), height: s(64))
            sampleInset = max(1, blockSize / 4)
        }

        /// 第 row 行（0 = 帧号，1 = 时间戳）第 index 块（0 = 最左）的矩形。
        public func blockRect(row: Int, index: Int) -> Rect {
            Rect(x: originX + index * blockSize, y: row == 0 ? row1Y : row2Y, width: blockSize, height: blockSize)
        }

        /// 解码采样区：矩形中心的一半（每边收进 1/4）。
        public func sampleRect(of r: Rect) -> Rect {
            let ix = r.width / 4, iy = r.height / 4
            return Rect(x: r.x + ix, y: r.y + iy, width: r.width - 2 * ix, height: r.height - 2 * iy)
        }
    }

    // MARK: 码字

    /// CRC-4：多项式 x⁴ + x + 1（0x3），初值 0xF，MSB 先，不反射，无 xorout；输入 28 位。
    /// 任意单比特翻转都能发现；全 0 / 全 1 的 32 位字都不是合法码字（全黑 / 全白画面不会误判成帧号）。
    public static func crc4(_ data: UInt32) -> UInt8 {
        var reg: UInt32 = 0xF
        var i = dataBits - 1
        while i >= 0 {
            let bit = (data >> UInt32(i)) & 1
            let feedback = ((reg >> 3) & 1) ^ bit
            reg = (reg << 1) & 0xF
            if feedback == 1 { reg ^= 0x3 }
            i -= 1
        }
        return UInt8(reg)
    }

    /// 28 位数据 → 32 位码字（数据在高 28 位，CRC 在低 4 位）。
    public static func encodeWord(_ data: UInt32) -> UInt32 {
        let d = data & dataMask
        return (d << 4) | UInt32(crc4(d))
    }

    /// 32 位码字 → 28 位数据；CRC 不对返回 nil。
    public static func decodeWord(_ word: UInt32) -> UInt32? {
        let d = word >> 4
        return crc4(d) == UInt8(word & 0xF) ? d : nil
    }

    // MARK: 调色板

    /// 16 色，索引 = 输入 ID。不含纯黑、纯白和任何灰（黑场 / 过曝 / 灰底画面不会被误解成某路输入）。
    public static let palette: [RGB8] = [
        RGB8(red: 255, green: 0, blue: 0),      // 0 红
        RGB8(red: 0, green: 255, blue: 0),      // 1 绿
        RGB8(red: 0, green: 0, blue: 255),      // 2 蓝
        RGB8(red: 0, green: 255, blue: 255),    // 3 青
        RGB8(red: 255, green: 0, blue: 255),    // 4 品红
        RGB8(red: 255, green: 192, blue: 0),    // 5 金
        RGB8(red: 128, green: 255, blue: 0),    // 6 黄绿
        RGB8(red: 0, green: 128, blue: 255),    // 7 天蓝
        RGB8(red: 128, green: 0, blue: 128),    // 8 紫
        RGB8(red: 0, green: 128, blue: 0),      // 9 深绿
        RGB8(red: 0, green: 0, blue: 128),      // 10 深蓝
        RGB8(red: 128, green: 64, blue: 0),     // 11 棕
        RGB8(red: 255, green: 128, blue: 128),  // 12 肉粉
        RGB8(red: 128, green: 255, blue: 128),  // 13 浅绿
        RGB8(red: 128, green: 192, blue: 255),  // 14 浅蓝
        RGB8(red: 0, green: 128, blue: 128),    // 15 蓝绿
    ]

    /// full-range RGB（0–255 实数）→ BT.709 limited Y'CbCr。
    public static func ycbcr(r: Double, g: Double, b: Double) -> YCbCr {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return YCbCr(y: 16 + 219 * y / 255,
                     cb: 128 + 224 * (b - y) / 1.8556 / 255,
                     cr: 128 + 224 * (r - y) / 1.5748 / 255)
    }
    /// RGB8 → BT.709 limited YCbCr。
    public static func ycbcr(of c: RGB8) -> YCbCr { ycbcr(r: Double(c.red), g: Double(c.green), b: Double(c.blue)) }

    /// 最近的调色板索引；离最近颜色超过 minimumPaletteDistance / 2 返回 nil。
    public static func paletteIndex(nearestTo c: YCbCr) -> Int? {
        var best = -1
        var bestDistance = Double.infinity
        for (i, p) in paletteYCbCr.enumerated() {
            let d = c.distance(to: p)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return bestDistance <= minimumPaletteDistance / 2 ? best : nil
    }
    static let paletteYCbCr: [YCbCr] = palette.map { ycbcr(of: $0) }

    // MARK: 闪光节奏

    /// 闪光周期（拍）= 四舍五入后的整数帧率（59.94 → 60 拍 = 1.001 s）。
    public static func flashPeriodTicks(frameRate: FrameRate) -> Int { frameRate.nominalFramesPerSecond }
    /// 闪光周期（秒，有理数）；合成音频的 click 周期用它。
    public static func flashPeriod(frameRate: FrameRate) -> Rational {
        frameRate.frameDuration.scaled(by: Int64(frameRate.nominalFramesPerSecond))
    }
    /// 这一拍是否闪光帧：tick % 周期 == 0（负拍同样取模）。
    public static func isFlashTick(_ tick: Tick, frameRate: FrameRate) -> Bool {
        let p = Int64(flashPeriodTicks(frameRate: frameRate))
        return ((tick.rawValue % p) + p) % p == 0
    }

    // MARK: 像素平面

    /// 要写 / 读的像素。decode 只读，指针类型用可变是为了两个方向共用一个枚举。bytesPerRow 须是 4 的倍数（BGRA）/ 2 的倍数（NV12）。
    public enum PixelPlanes {
        case bgra(base: UnsafeMutableRawPointer, bytesPerRow: Int)
        case nv12(luma: UnsafeMutableRawPointer, lumaBytesPerRow: Int, chroma: UnsafeMutableRawPointer?, chromaBytesPerRow: Int)
    }

    // MARK: 画

    /// 把整幅图案画进平面（先铺底色，再画四样东西）。
    public static func draw(_ c: Content, into planes: PixelPlanes, width: Int, height: Int) {
        let g = Geometry(width: width, height: height)
        switch planes {
        case .bgra(let base, let bpr):
            drawBGRA(c, g, base: base, bytesPerRow: bpr)
        case .nv12(let luma, let lbpr, let chroma, let cbpr):
            drawNV12(c, g, luma: luma, lumaBytesPerRow: lbpr, chroma: chroma, chromaBytesPerRow: cbpr)
        }
    }

    /// 画进 CVPixelBuffer（BGRA 或 NV12）；其他格式返回 false。
    @discardableResult
    public static func draw(_ c: Content, into pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let planes = planes(of: pixelBuffer) else { return false }
        draw(c, into: planes, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return true
    }

    // MARK: 读

    /// 读整幅图案；解不出的字段为 nil。
    public static func decode(_ planes: PixelPlanes, width: Int, height: Int) -> Decoded {
        let g = Geometry(width: width, height: height)
        let frameNumber = decodeWord(readWord(planes, g, row: 0))
        let hostTimeMs = decodeWord(readWord(planes, g, row: 1))
        let inputID = meanColor(planes, g.sampleRect(of: g.idRect)).flatMap { paletteIndex(nearestTo: $0) }
        let flash = meanLuma(planes, g.sampleRect(of: g.flashRect)) > 128
        return Decoded(frameNumber: frameNumber, hostTimeMs: hostTimeMs, inputID: inputID, flash: flash)
    }

    /// 从 CVPixelBuffer 读（BGRA 或 NV12）；其他格式返回 nil。
    public static func decode(pixelBuffer: CVPixelBuffer) -> Decoded? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let planes = planes(of: pixelBuffer) else { return nil }
        return decode(planes, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }

    // MARK: - 实现细节

    static func planes(of pb: CVPixelBuffer) -> PixelPlanes? {
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

    @inline(__always)
    static func bgraPixel(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        0xFF00_0000 | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }
    @inline(__always)
    static func limitedLuma(_ level: UInt8) -> UInt8 { UInt8((16 + 219 * Double(level) / 255).rounded()) }
    @inline(__always)
    static func clampByte(_ v: Double) -> UInt8 { UInt8(min(max(v.rounded(), 0), 255)) }

    static func fillBGRA(_ base: UnsafeMutableRawPointer, _ bpr: Int, _ r: Rect, _ pixel: UInt32) {
        for y in r.y..<(r.y + r.height) {
            ((base + y * bpr).assumingMemoryBound(to: UInt32.self) + r.x).update(repeating: pixel, count: r.width)
        }
    }
    static func fillLuma(_ base: UnsafeMutableRawPointer, _ bpr: Int, _ r: Rect, _ v: UInt8) {
        for y in r.y..<(r.y + r.height) {
            ((base + y * bpr).assumingMemoryBound(to: UInt8.self) + r.x).update(repeating: v, count: r.width)
        }
    }
    /// 色度平面按半分辨率填 (Cb, Cr)。
    static func fillChroma(_ base: UnsafeMutableRawPointer, _ bpr: Int, _ r: Rect, cb: UInt8, cr: UInt8) {
        let pair = UInt16(cb) | (UInt16(cr) << 8)
        for cy in (r.y / 2)..<((r.y + r.height) / 2) {
            ((base + cy * bpr).assumingMemoryBound(to: UInt16.self) + r.x / 2).update(repeating: pair, count: r.width / 2)
        }
    }

    // MARK: 噪声底纹（提案 006）

    /// 噪声序列：SplitMix64。行种子由 seed、帧号、行号混合而来，所以每行、每帧、每个 seed 的序列都不同，而且任何一行都能独立生成（并行画也确定）。
    struct NoiseRow {
        private var state: UInt64
        private let level: Int32
        private let amplitude: Int32
        private let range: UInt64

        @inline(__always)
        static func mix(_ x: UInt64) -> UInt64 {
            var z = x
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        init(seed: UInt64, frameNumber: UInt32, row: Int, level: UInt8, amplitude: UInt8) {
            state = NoiseRow.mix(seed ^ NoiseRow.mix(UInt64(frameNumber) | (UInt64(UInt32(truncatingIfNeeded: row)) << 32) &+ 0x9E37_79B9_7F4A_7C15))
            self.level = Int32(level)
            self.amplitude = Int32(amplitude)
            range = UInt64(2 * Int(amplitude) + 1)
        }

        /// 下一对像素的 full-range 灰值（一次 64 位输出给两个像素，各用 32 位做 [0, 2·amplitude] 的无偏映射，偏差 < 2⁻²⁶）。
        @inline(__always)
        mutating func next2() -> (UInt8, UInt8) {
            state &+= 0x9E37_79B9_7F4A_7C15
            let r = NoiseRow.mix(state)
            let lo = UInt64(UInt32(truncatingIfNeeded: r)), hi = r >> 32
            let a = level + Int32((lo &* range) >> 32) - amplitude
            let b = level + Int32((hi &* range) >> 32) - amplitude
            return (UInt8(clamping: a), UInt8(clamping: b))
        }
    }

    /// 参考定义：(seed, frameNumber, x, y) 处的噪声灰值（full-range），与 `draw` 画出来的逐像素相同；别的实现（GPU / 预生成平面）拿它当对照。
    public static func noiseValue(level: UInt8, amplitude: UInt8, seed: UInt64, frameNumber: UInt32, x: Int, y: Int) -> UInt8 {
        var gen = NoiseRow(seed: seed, frameNumber: frameNumber & dataMask, row: y, level: level, amplitude: amplitude)
        var pair = gen.next2()
        var i = 0
        while i + 2 <= x { pair = gen.next2(); i += 2 }
        return x & 1 == 0 ? pair.0 : pair.1
    }

    /// limited-range Y 查表（noise 每像素一次换算，不重复算浮点）。
    static let limitedLumaTable: [UInt8] = (0...255).map { limitedLuma(UInt8($0)) }

    static func drawBGRA(_ c: Content, _ g: Geometry, base: UnsafeMutableRawPointer, bytesPerRow bpr: Int) {
        let w = g.width, h = g.height
        switch c.background {
        case .gray(let level):
            let px = bgraPixel(level, level, level)
            for y in 0..<h { (base + y * bpr).assumingMemoryBound(to: UInt32.self).update(repeating: px, count: w) }
        case .gradient:
            let row0 = base.assumingMemoryBound(to: UInt32.self)
            for x in 0..<w {
                let l = UInt8(x * 255 / max(1, w - 1))
                row0[x] = bgraPixel(l, l, l)
            }
            for y in 1..<h { (base + y * bpr).assumingMemoryBound(to: UInt32.self).update(from: row0, count: w) }
        case .noise(let level, let amplitude, let seed):
            for y in 0..<h {
                var gen = NoiseRow(seed: seed, frameNumber: c.frameNumber, row: y, level: level, amplitude: amplitude)
                let row = (base + y * bpr).assumingMemoryBound(to: UInt32.self)
                var x = 0
                while x + 2 <= w {
                    let (a, b) = gen.next2()
                    row[x] = bgraPixel(a, a, a)
                    row[x + 1] = bgraPixel(b, b, b)
                    x += 2
                }
                if x < w { let (a, _) = gen.next2(); row[x] = bgraPixel(a, a, a) }
            }
        }
        let white = bgraPixel(255, 255, 255), black = bgraPixel(0, 0, 0)
        for (row, word) in [(0, encodeWord(c.frameNumber)), (1, encodeWord(c.hostTimeMs))] {
            for i in 0..<blockCount {
                let bit = (word >> UInt32(31 - i)) & 1
                fillBGRA(base, bpr, g.blockRect(row: row, index: i), bit == 1 ? white : black)
            }
        }
        let p = palette[c.inputID]
        fillBGRA(base, bpr, g.idRect, bgraPixel(p.red, p.green, p.blue))
        fillBGRA(base, bpr, g.flashRect, c.flash ? white : black)
    }

    static func drawNV12(_ c: Content, _ g: Geometry, luma: UnsafeMutableRawPointer, lumaBytesPerRow lbpr: Int,
                         chroma: UnsafeMutableRawPointer?, chromaBytesPerRow cbpr: Int) {
        let w = g.width, h = g.height
        switch c.background {
        case .gray(let level):
            let v = limitedLuma(level)
            for y in 0..<h { (luma + y * lbpr).assumingMemoryBound(to: UInt8.self).update(repeating: v, count: w) }
        case .gradient:
            let row0 = luma.assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { row0[x] = limitedLuma(UInt8(x * 255 / max(1, w - 1))) }
            for y in 1..<h { (luma + y * lbpr).assumingMemoryBound(to: UInt8.self).update(from: row0, count: w) }
        case .noise(let level, let amplitude, let seed):
            limitedLumaTable.withUnsafeBufferPointer { table in
                for y in 0..<h {
                    var gen = NoiseRow(seed: seed, frameNumber: c.frameNumber, row: y, level: level, amplitude: amplitude)
                    let row = (luma + y * lbpr).assumingMemoryBound(to: UInt8.self)
                    var x = 0
                    while x + 2 <= w {
                        let (a, b) = gen.next2()
                        row[x] = table[Int(a)]
                        row[x + 1] = table[Int(b)]
                        x += 2
                    }
                    if x < w { let (a, _) = gen.next2(); row[x] = table[Int(a)] }
                }
            }
        }
        if let chroma {
            for cy in 0..<(h / 2) { (chroma + cy * cbpr).assumingMemoryBound(to: UInt16.self).update(repeating: 0x8080, count: w / 2) }
        }
        let white: UInt8 = 235, black: UInt8 = 16
        for (row, word) in [(0, encodeWord(c.frameNumber)), (1, encodeWord(c.hostTimeMs))] {
            for i in 0..<blockCount {
                let bit = (word >> UInt32(31 - i)) & 1
                fillLuma(luma, lbpr, g.blockRect(row: row, index: i), bit == 1 ? white : black)
            }
        }
        let p = paletteYCbCr[c.inputID]
        fillLuma(luma, lbpr, g.idRect, clampByte(p.y))
        if let chroma { fillChroma(chroma, cbpr, g.idRect, cb: clampByte(p.cb), cr: clampByte(p.cr)) }
        fillLuma(luma, lbpr, g.flashRect, c.flash ? white : black)
    }

    /// 区域内的平均 limited-range 亮度。
    static func meanLuma(_ planes: PixelPlanes, _ r: Rect) -> Double {
        switch planes {
        case .bgra:
            guard let c = meanColor(planes, r) else { return 0 }
            return c.y
        case .nv12(let luma, let bpr, _, _):
            var sum = 0
            for y in r.y..<(r.y + r.height) {
                let row = (luma + y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in r.x..<(r.x + r.width) { sum += Int(row[x]) }
            }
            return Double(sum) / Double(r.width * r.height)
        }
    }

    /// 区域内的平均颜色（YCbCr）；NV12 没有色度平面时为 nil。
    static func meanColor(_ planes: PixelPlanes, _ r: Rect) -> YCbCr? {
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
            return ycbcr(r: Double(rs) / n, g: Double(gs) / n, b: Double(bs) / n)
        case .nv12(_, _, let chroma, let cbpr):
            guard let chroma else { return nil }
            let y = meanLuma(planes, r)
            var cbs = 0, crs = 0, count = 0
            for cy in (r.y / 2)..<((r.y + r.height) / 2) {
                let row = (chroma + cy * cbpr).assumingMemoryBound(to: UInt8.self)
                for cx in (r.x / 2)..<((r.x + r.width) / 2) {
                    cbs += Int(row[2 * cx]); crs += Int(row[2 * cx + 1]); count += 1
                }
            }
            guard count > 0 else { return nil }
            return YCbCr(y: y, cb: Double(cbs) / Double(count), cr: Double(crs) / Double(count))
        }
    }

    static func readWord(_ planes: PixelPlanes, _ g: Geometry, row: Int) -> UInt32 {
        var word: UInt32 = 0
        for i in 0..<blockCount where meanLuma(planes, g.sampleRect(of: g.blockRect(row: row, index: i))) > 128 {
            word |= 1 << UInt32(31 - i)
        }
        return word
    }
}
