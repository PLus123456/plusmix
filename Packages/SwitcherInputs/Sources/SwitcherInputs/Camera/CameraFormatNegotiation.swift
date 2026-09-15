import CoreMedia
import SwitcherContracts

/// 摄像头格式协商（W2-A 第 1 条 "分辨率 / 帧率优先匹配节目帧率"）。纯函数，好测：
/// 1. 帧率：能锁到节目帧率的最好（帧率范围包含它）；否则取最大帧率 ≤ 节目帧率里最高的；再否则取最小的高于节目帧率的；
/// 2. 分辨率：与节目相同最好；否则两边都 ≥ 节目的里最小的（缩小比放大好看）；再否则最大的；
/// 3. 像素格式：原生 '420v' / '420f' 优先（不用 AVFoundation 转换）；
/// 4. 同分先出现的优先（设备列表的顺序一般是"越靠后越大"，所以取靠前的）。
public enum CameraFormatNegotiation {
    /// 一个候选格式（从 AVCaptureDevice.Format 抽出来的字段）。
    public struct Candidate: Hashable, Sendable {
        /// 在 device.formats 里的下标。
        public var index: Int
        /// 媒体子类型（'420v'、'420f'、'yuvs'、'2vuy'、'dmb1'……）。
        public var mediaSubType: OSType
        public var width: Int
        public var height: Int
        /// 支持的帧率范围（可能多段）。
        public var frameRateRanges: [ClosedRange<Double>]
        public init(index: Int, mediaSubType: OSType, width: Int, height: Int, frameRateRanges: [ClosedRange<Double>]) {
            self.index = index
            self.mediaSubType = mediaSubType
            self.width = width
            self.height = height
            self.frameRateRanges = frameRateRanges
        }
        /// 是否原生 NV12。
        public var isNativeNV12: Bool {
            mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        var maxFrameRate: Double { frameRateRanges.map(\.upperBound).max() ?? 0 }
        func supports(fps: Double) -> Bool { frameRateRanges.contains { $0.lowerBound - 0.01 <= fps && fps <= $0.upperBound + 0.01 } }
    }

    /// 协商结果。
    public struct Choice: Hashable, Sendable {
        public var candidate: Candidate
        /// 要锁定的帧率（节目帧率，或格式能给的最接近值）。
        public var frameRate: Double
        /// 帧率是否与节目一致。
        public var matchesProgramFrameRate: Bool
    }

    public static func choose(_ candidates: [Candidate], program: ProgramFormat) -> Choice? {
        guard !candidates.isEmpty else { return nil }
        let target = program.frameRate.approximateFramesPerSecond
        // 帧率等级：0 = 能锁到节目帧率；1 = 低于节目帧率（差值越小越好）；2 = 高于节目帧率（差值越小越好）
        func rateKey(_ c: Candidate) -> (Int, Double) {
            if c.supports(fps: target) { return (0, 0) }
            let below = c.frameRateRanges.map(\.upperBound).filter { $0 < target }.max()
            if let b = below { return (1, target - b) }
            let above = c.frameRateRanges.map(\.lowerBound).filter { $0 > target }.min() ?? c.maxFrameRate
            return (2, above - target)
        }
        // 分辨率等级：0 = 相同；1 = 两边都 ≥（越小越好）；2 = 其他（越大越好）
        func sizeKey(_ c: Candidate) -> (Int, Int) {
            if c.width == program.width && c.height == program.height { return (0, 0) }
            if c.width >= program.width && c.height >= program.height { return (1, c.width * c.height) }
            return (2, -(c.width * c.height))
        }
        let best = candidates.min { a, b in
            let ra = rateKey(a), rb = rateKey(b)
            if ra.0 != rb.0 { return ra.0 < rb.0 }
            if ra.1 != rb.1 { return ra.1 < rb.1 }
            let sa = sizeKey(a), sb = sizeKey(b)
            if sa.0 != sb.0 { return sa.0 < sb.0 }
            if sa.1 != sb.1 { return sa.1 < sb.1 }
            if a.isNativeNV12 != b.isNativeNV12 { return a.isNativeNV12 }
            return a.index < b.index
        }!
        let key = rateKey(best)
        let fps: Double
        switch key.0 {
        case 0: fps = target
        case 1: fps = target - key.1
        default: fps = target + key.1
        }
        return Choice(candidate: best, frameRate: fps, matchesProgramFrameRate: key.0 == 0)
    }
}
