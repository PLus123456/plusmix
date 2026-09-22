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

    /// 由 `PatternProbe` 的读数建（灰度取中心采样区，与老口径同一个数）。
    public init(index: Int, ptsSeconds: Double, reading: PatternProbe.Reading) {
        self.init(index: index, ptsSeconds: ptsSeconds, decoded: reading.decoded, gray: reading.centerGray)
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
    /// 音轨第一个（解码输出的）样本在文件时间线上的时刻（秒）：AVFoundation 的解码起点 + `timeline.correctionSeconds`。
    public var startSeconds: Double
    public var sampleCount: Int
    /// 起点是怎么算出来的（容器偏移、priming、口径）；老版本 JSON 没有。
    public var timeline: AudioTimeline?
    public init(sampleRate: Double, channels: Int, startSeconds: Double, sampleCount: Int, timeline: AudioTimeline? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.startSeconds = startSeconds
        self.sampleCount = sampleCount
        self.timeline = timeline
    }
}

/// 音轨时间轴的修正（W1-A2，问题单 W2D-w1-testkit-frameprobe-av-on-stream-recordings）：
/// AVFoundation 对没有编辑列表的分片文件把每条轨各自归零、又对 AAC 按 2112 样本裁 priming 而不挪时间轴，推流落盘文件的 click 就早了 44–64 ms。
/// 两种口径：**AVFoundation 原生**（不修正）；**ffmpeg 口径**（`aresample=first_pts=0`、不裁 priming：第 k 个包的时间戳 = 非裁剪解码器输出的时刻，
/// RTMP / SRT 的行业约定，W2-D 按它送包）= 加上容器里音轨相对视频的起始偏移，再把裁掉的 priming 加回时间轴。
/// `--aac-priming auto`（默认）：有编辑列表就信 AVFoundation（它按 elst 裁并挪，是对的），没有就按 ffmpeg 口径；`0` = 只加容器偏移不加回 priming；`N` = 加回 N 样本。
public struct AudioTimeline: Hashable, Codable, Sendable {
    /// "auto" / "0" / "N"。
    public var mode: String
    /// 实际采用的口径："ffmpeg" / "avfoundation" / "custom"。
    public var applied: String
    /// 音轨编码（"aac" / "lpcm" / …）。
    public var codec: String
    public var isFragmented: Bool
    public var hasEditList: Bool
    /// 有编辑列表时第一个非空条目的 media_time（AAC 录制文件 = 2112）。
    public var editListMediaTime: Int64?
    /// AVFoundation 解码输出第一个样本的 PTS（秒）。
    public var avfoundationStartSeconds: Double
    /// 容器里音轨第一个样本相对视频轨第一个样本的时刻（秒）：分片、无编辑列表时 = tfdt 之差；其他情况 0。
    public var containerOffsetSeconds: Double
    /// AVFoundation 裁掉的样本数。
    public var primingTrimmedSamples: Int
    /// 按 mode 加回时间轴的样本数。
    public var primingAddedBackSamples: Int
    /// 实际加到 AVFoundation 起点上的修正（秒）= containerOffset + addedBack / 采样率。
    public var correctionSeconds: Double
    /// ffmpeg 口径的修正（秒）；`auto` 就是它。
    public var ffmpegCorrectionSeconds: Double
    public init(mode: String, applied: String, codec: String, isFragmented: Bool, hasEditList: Bool, editListMediaTime: Int64?,
                avfoundationStartSeconds: Double, containerOffsetSeconds: Double, primingTrimmedSamples: Int, primingAddedBackSamples: Int,
                correctionSeconds: Double, ffmpegCorrectionSeconds: Double) {
        self.mode = mode
        self.applied = applied
        self.codec = codec
        self.isFragmented = isFragmented
        self.hasEditList = hasEditList
        self.editListMediaTime = editListMediaTime
        self.avfoundationStartSeconds = avfoundationStartSeconds
        self.containerOffsetSeconds = containerOffsetSeconds
        self.primingTrimmedSamples = primingTrimmedSamples
        self.primingAddedBackSamples = primingAddedBackSamples
        self.correctionSeconds = correctionSeconds
        self.ffmpegCorrectionSeconds = ffmpegCorrectionSeconds
    }
}

/// `--aac-priming` 的取值。
public enum PrimingMode: Hashable, Sendable {
    /// 有编辑列表信 AVFoundation，没有就按 ffmpeg 口径把裁掉的 priming 加回时间轴。
    case auto
    /// 加回固定的样本数（0 = 只加容器偏移，不加回 priming）。
    case samples(Int)

    public var label: String {
        switch self {
        case .auto: "auto"
        case .samples(let n): "\(n)"
        }
    }
    /// 解析命令行值：auto / 0 / N。
    public init?(_ s: String) {
        if s == "auto" { self = .auto; return }
        guard let n = Int(s), n >= 0 else { return nil }
        self = .samples(n)
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
