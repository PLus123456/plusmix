import CoreVideo

// MARK: - 像素格式与色彩

/// 引擎接受的三种像素格式（设计方案 §5、W1-C）。
public enum PixelFormat: String, Codable, Sendable, CaseIterable {
    /// 4:2:0 双平面 Y + 交错 CbCr。摄像头 / 采集卡 / 引擎输出（IOSurface）用它。
    case nv12
    /// 8-bit BGRA，字节序 B G R A。合成工作格式、图片 / 带 alpha 的文件输入用它。
    case bgra
    /// 4:2:2 打包 UYVY（'2vuy'）。DeckLink 8-bit 给的就是它。
    case uyvy

    /// 对应的 CoreVideo 类型。NV12 按色彩范围分 '420v' / '420f'。
    public func cvPixelFormatType(range: ColorRange) -> OSType {
        switch self {
        case .nv12: range == .full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .bgra: kCVPixelFormatType_32BGRA
        case .uyvy: kCVPixelFormatType_422YpCbCr8
        }
    }

    /// 从 CoreVideo 类型识别；不认识的返回 nil。
    public init?(cvPixelFormatType: OSType) {
        switch cvPixelFormatType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .nv12
        case kCVPixelFormatType_32BGRA: self = .bgra
        case kCVPixelFormatType_422YpCbCr8: self = .uyvy
        default: return nil
        }
    }

    /// 平面数（NV12 = 2）。
    public var planeCount: Int { self == .nv12 ? 2 : 1 }
}

/// 色域。
public enum ColorPrimaries: String, Codable, Sendable { case bt709, bt2020, displayP3 }
/// 传递函数。
public enum TransferFunction: String, Codable, Sendable { case bt709, sRGB, linear }
/// YCbCr 矩阵。
public enum YCbCrMatrix: String, Codable, Sendable { case bt601, bt709, bt2020 }
/// 电平范围：limited = 16–235（视频），full = 0–255。
public enum ColorRange: String, Codable, Sendable { case limited, full }

/// 一帧的色彩描述。第一版工作色彩空间是 BT.709 gamma 域（设计方案 §5）；第二版换线性 float16 时接口不变。
public struct ColorInfo: Hashable, Codable, Sendable {
    /// 色域。
    public var primaries: ColorPrimaries
    /// 传递函数。
    public var transfer: TransferFunction
    /// YCbCr 矩阵。
    public var matrix: YCbCrMatrix
    /// 电平范围。
    public var range: ColorRange

    public init(primaries: ColorPrimaries = .bt709, transfer: TransferFunction = .bt709, matrix: YCbCrMatrix = .bt709, range: ColorRange = .limited) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
    }

    /// 视频路径默认：BT.709，limited。引擎输出的 NV12 永远是它（V9 的口径）。
    public static let bt709Limited = ColorInfo()
    /// BT.709，full range。
    public static let bt709Full = ColorInfo(range: .full)
    /// 图片 / 屏幕这类 RGB 源。
    public static let sRGBFull = ColorInfo(primaries: .bt709, transfer: .sRGB, matrix: .bt709, range: .full)
}

/// 8-bit RGB 颜色（full range）。调色板、抠像键色用它。
public struct RGB8: Hashable, Codable, Sendable {
    /// 红 0–255。
    public var red: UInt8
    /// 绿 0–255。
    public var green: UInt8
    /// 蓝 0–255。
    public var blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// BT.709 limited-range 的 Y'CbCr 值（0–255 标尺上的实数）。测试图案的调色板判别用它。
public struct YCbCr: Hashable, Sendable {
    /// Y'（16–235）。
    public var y: Double
    /// Cb（16–240）。
    public var cb: Double
    /// Cr（16–240）。
    public var cr: Double
    public init(y: Double, cb: Double, cr: Double) {
        self.y = y
        self.cb = cb
        self.cr = cr
    }
    /// 欧氏距离。
    public func distance(to other: YCbCr) -> Double {
        let dy = y - other.y, dcb = cb - other.cb, dcr = cr - other.cr
        return (dy * dy + dcb * dcb + dcr * dcr).squareRoot()
    }
}

// MARK: - 帧

/// 一帧视频（设计方案 §4）。值类型，只持有一个 CVPixelBuffer 引用；拷贝 Frame 只是 retain，不拷像素。
///
/// 为什么 `@unchecked Sendable` 是安全的：
/// - `CVPixelBuffer` 没有标 Sendable，但这里的用法是"写完即冻结"：生产者（输入线程）在 `push` 进帧槽之前写完像素，
///   之后任何线程都只读它；池子回收靠 CVPixelBufferPool 的引用计数，最后一个引用释放前不会被复用。
/// - 其余字段全是值类型。
/// 谁违反"push 之后不再写"就是违反契约，不是这里的问题。
public struct Frame: @unchecked Sendable {
    /// IOSurface 背后的像素，NV12 / BGRA / UYVY 之一。
    public let pixelBuffer: CVPixelBuffer
    /// 入口打的戳：这帧对应的采集时刻，已换算成 host time（铁律 5）。挑帧规则比的就是它。
    public let pts: HostTime
    /// 这帧的标称时长（输入帧率的倒数）。
    public let duration: HostDuration
    /// 色彩描述。
    public let color: ColorInfo
    /// 来源输入编号；0 保留给引擎自己输出的帧（PGM / PVW / 多画面）。
    public let inputNumber: Int
    /// 该输入内单调递增的帧序号，由输入自己计数；用于统计重复 / 丢弃。
    public let sequence: UInt64
    /// 这帧进入帧槽那一刻的 host time（`HostClock.now()`）。L1 内部延迟 = 编码器入口时刻 − ingressTime。
    public let ingressTime: HostTime

    public init(pixelBuffer: CVPixelBuffer, pts: HostTime, duration: HostDuration, color: ColorInfo,
                inputNumber: Int, sequence: UInt64, ingressTime: HostTime) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
        self.color = color
        self.inputNumber = inputNumber
        self.sequence = sequence
        self.ingressTime = ingressTime
    }

    /// 像素格式；不认识的为 nil。
    public var pixelFormat: PixelFormat? { PixelFormat(cvPixelFormatType: CVPixelBufferGetPixelFormatType(pixelBuffer)) }
    /// 宽（像素）。
    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    /// 高（像素）。
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

// MARK: - 节目格式

/// 节目（PGM）的分辨率与帧率。引擎、渲染器、编码器、合成源都按它配置；改它等于重启管线。
public struct ProgramFormat: Hashable, Codable, Sendable {
    /// 节目宽（像素）。
    public var width: Int
    /// 节目高（像素）。
    public var height: Int
    /// 节目帧率。
    public var frameRate: FrameRate

    public init(width: Int, height: Int, frameRate: FrameRate) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// 1920×1080 @ 60。
    public static let hd1080p60 = ProgramFormat(width: 1920, height: 1080, frameRate: .fps60)
    /// 1920×1080 @ 59.94。
    public static let hd1080p5994 = ProgramFormat(width: 1920, height: 1080, frameRate: .fps5994)
    /// 1920×1080 @ 30。
    public static let hd1080p30 = ProgramFormat(width: 1920, height: 1080, frameRate: .fps30)
    /// 1280×720 @ 60。
    public static let hd720p60 = ProgramFormat(width: 1280, height: 720, frameRate: .fps60)
    /// 3840×2160 @ 30。
    public static let uhd2160p30 = ProgramFormat(width: 3840, height: 2160, frameRate: .fps30)

    /// 一拍的时长（秒）。
    public var frameDuration: Rational { frameRate.frameDuration }
}
