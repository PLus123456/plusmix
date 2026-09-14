import Foundation
import SwitcherContracts

/// frameprobe 逐帧解码出的一行（`frames` 子命令的元素）。
public struct ProbeFrame: Hashable, Codable, Sendable {
    /// 在输出文件 / 目录里的序号，从 0 起。
    public var index: Int
    /// 文件时间线上的显示时刻（秒）。
    public var ptsSeconds: Double
    /// 图案里的帧号；CRC 不对为 nil。
    public var frameNumber: UInt32?
    /// 图案里的输入 ID（调色板索引）；混合 / 黑场为 nil。
    public var inputID: Int?
    /// 图案里的生成时刻（host time 毫秒 mod 2²⁸）；CRC 不对为 nil。
    public var genTimeMs: UInt32?
    /// 闪光块是否为白。
    public var flash: Bool
    /// 画面中心采样区（宽高各 1/4）的平均灰度，full-range RGB 电平 0–255；NV12 由 limited Y 换算。
    public var gray: Double

    public init(index: Int, ptsSeconds: Double, frameNumber: UInt32?, inputID: Int?, genTimeMs: UInt32?, flash: Bool, gray: Double) {
        self.index = index
        self.ptsSeconds = ptsSeconds
        self.frameNumber = frameNumber
        self.inputID = inputID
        self.genTimeMs = genTimeMs
        self.flash = flash
        self.gray = gray
    }

    public init(index: Int, ptsSeconds: Double, decoded: TestPattern.Decoded, gray: Double) {
        self.init(index: index, ptsSeconds: ptsSeconds, frameNumber: decoded.frameNumber, inputID: decoded.inputID,
                  genTimeMs: decoded.hostTimeMs, flash: decoded.flash, gray: gray)
    }
}

/// 音轨里找到的一个 click。
public struct ClickEvent: Hashable, Codable, Sendable {
    /// 音轨样本序号（从音轨第一个样本起）。
    public var sampleIndex: Int64
    /// 文件时间线上的时刻（秒）= 音轨起点 + sampleIndex / 采样率。
    public var timeSeconds: Double
    /// 检测窗口内的峰值绝对值。
    public var peak: Float
    public init(sampleIndex: Int64, timeSeconds: Double, peak: Float) {
        self.sampleIndex = sampleIndex
        self.timeSeconds = timeSeconds
        self.peak = peak
    }
}

/// 一个输入源的元信息（视频轨）。
public struct ProbeVideoInfo: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int
    /// 容器标称帧率（原始 NV12 目录 = 用户给的）。
    public var nominalFps: Double
    /// 轨道时长（秒）。
    public var durationSeconds: Double
    /// 像素格式描述（"bgra" / "nv12"）。
    public var pixelFormat: String
    public init(width: Int, height: Int, nominalFps: Double, durationSeconds: Double, pixelFormat: String) {
        self.width = width
        self.height = height
        self.nominalFps = nominalFps
        self.durationSeconds = durationSeconds
        self.pixelFormat = pixelFormat
    }
}

/// 音轨元信息。
public struct ProbeAudioInfo: Hashable, Codable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    /// 音轨第一个样本在文件时间线上的时刻（秒）。
    public var startSeconds: Double
    public var sampleCount: Int
    public init(sampleRate: Double, channels: Int, startSeconds: Double, sampleCount: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.startSeconds = startSeconds
        self.sampleCount = sampleCount
    }
}

/// 报告共用的 JSON 编码：键排序（快照稳定）、缩进、不转义斜杠。
public enum ProbeJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()
    /// 编成字符串。
    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
