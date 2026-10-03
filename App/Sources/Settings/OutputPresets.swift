// 输出设置页的预设（W5-I，prompt 95；01a K8 / L6–L9，04 Q30 / Q31）：
// - 新建录制输出的默认值跟节目格式走（Q30：1080p30 ≈ 10、1080p60 ≈ 18、1440p60 ≈ 32、2160p30 ≈ 36 Mb/s，其余按每像素每帧约 0.15 bit 取整；AAC 256k）；
// - 推流的质量档（我们自己的档位，Q30 (i)：封顶 1080p，60 fps 6 Mb/s / 30 fps 4.5 Mb/s，关键帧 2 s，AAC 160k；带一个 720p 档）；
// - 推流服务预设表（Q31 (a)）：App 资源 StreamServices.json，只是填地址的快捷方式——节目里只存完整地址，服务按地址开头认；
// - 关键帧按秒显示、按节目帧率换成帧数存（L8）。
// 契约默认值不动：这些只在 App 新建 / 用户选档时写进输出设置。
import Foundation
import SwitcherContracts

/// 新建录制输出的默认值（K8 / Q30）。
enum RecordDefaults {
    /// 音频：AAC 256 kb/s（比推流的 160k 高）。
    static let audioBitrateBps = 256_000

    /// 视频码率：Q30 列出的四档按表，其余按 0.15 bit / 像素 / 帧取整到 Mb/s（至少 4 Mb/s）。
    static func videoBitrateBps(for format: ProgramFormat) -> Int {
        let fps = format.frameRate.nominalFramesPerSecond
        switch (format.width, format.height, fps) {
        case (1920, 1080, 30): return 10_000_000
        case (1920, 1080, 60): return 18_000_000
        case (2560, 1440, 60): return 32_000_000
        case (3840, 2160, 30): return 36_000_000
        default:
            let bps = Double(format.width * format.height) * format.frameRate.approximateFramesPerSecond * 0.15
            return max(4, Int((bps / 1_000_000).rounded())) * 1_000_000
        }
    }

    static func video(for format: ProgramFormat) -> VideoEncodeSettings {
        VideoEncodeSettings(codec: .h264, bitrateBps: videoBitrateBps(for: format))
    }

    static func audio() -> AudioEncodeSettings { AudioEncodeSettings(codec: .aac, bitrateBps: audioBitrateBps) }

    /// 一个新的 PGM 录制输出（编号、名字由调用方给；enabled = false，由录制按钮起）。
    static func output(number: Int, name: String, format: ProgramFormat, directory: String, source: OutputSource = .program) -> OutputState {
        OutputState(number: number, kind: .record, name: name, enabled: false,
                    settings: OutputSettings(source: source, video: video(for: format), audio: audio(), record: RecordSettings(directory: directory)))
    }
}

/// 关键帧：界面按秒，存储按帧（L8）。
enum KeyframeInterval {
    /// 新建推流目的地的关键帧间隔（秒）。
    static let defaultSeconds = 2.0

    /// 秒 → 按节目帧率的帧数（59.94 × 2 = 119.88 → 120）。
    static func frames(seconds: Double, rate: FrameRate) -> Int {
        max(1, Int((seconds * rate.approximateFramesPerSecond).rounded()))
    }

    /// 帧 → 秒。
    static func seconds(frames: Int, rate: FrameRate) -> Double {
        Double(frames) / rate.approximateFramesPerSecond
    }

    /// "2 s（= 60 帧）"：秒数保留到 0.1（整数不带小数）。
    static func text(frames: Int, rate: FrameRate) -> String {
        let s = seconds(frames: frames, rate: rate)
        let rounded = (s * 10).rounded() / 10
        let secondsText = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return L("outputSettings.keyframe.text", secondsText, frames)
    }
}

/// 推流质量档（L7 / Q30）。档位是我们自己的；选中即把编码字段写成这一档，任何一项和档位对不上就显示"自定义"。
struct StreamQualityTier: Identifiable, Equatable {
    let id: String
    let width: Int
    let height: Int
    /// 节目 ≥ 48 fps（50 / 59.94 / 60）用的码率。
    let highRateBps: Int
    /// 节目 < 48 fps（24 / 25 / 29.97 / 30）用的码率。
    let lowRateBps: Int
    let audioBps: Int

    static let all: [StreamQualityTier] = [
        StreamQualityTier(id: "1080p", width: 1920, height: 1080, highRateBps: 6_000_000, lowRateBps: 4_500_000, audioBps: 160_000),
        StreamQualityTier(id: "720p", width: 1280, height: 720, highRateBps: 3_000_000, lowRateBps: 3_000_000, audioBps: 128_000),
    ]

    static func tier(id: String) -> StreamQualityTier? { all.first { $0.id == id } }

    static func isHighRate(_ rate: FrameRate) -> Bool { rate.approximateFramesPerSecond >= 48 }

    func videoBitrateBps(for format: ProgramFormat) -> Int { Self.isHighRate(format.frameRate) ? highRateBps : lowRateBps }

    /// 这一档的编码设置（H.264、关键帧 2 s 按节目帧率换帧数、AAC）。
    func video(for format: ProgramFormat) -> VideoEncodeSettings {
        VideoEncodeSettings(codec: .h264, bitrateBps: videoBitrateBps(for: format),
                            keyframeIntervalFrames: KeyframeInterval.frames(seconds: KeyframeInterval.defaultSeconds, rate: format.frameRate),
                            width: width, height: height)
    }

    func audio() -> AudioEncodeSettings { AudioEncodeSettings(codec: .aac, bitrateBps: audioBps) }

    /// 下拉里的一行："1080p · 6 Mb/s · 音频 160k"。
    func title(for format: ProgramFormat) -> String {
        L("outputSettings.stream.quality.tier", "\(height)p", Self.mbps(videoBitrateBps(for: format)), audioBps / 1000)
    }

    /// 码率写成 "6" / "4.5"。
    static func mbps(_ bps: Int) -> String {
        let v = Double(bps) / 1_000_000
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// 编码设置正好是哪一档（宽高 nil = 节目尺寸）；对不上 = nil（"自定义"）。
    static func matching(video: VideoEncodeSettings?, audio: AudioEncodeSettings?, format: ProgramFormat) -> StreamQualityTier? {
        guard let video, let audio else { return nil }
        let w = video.width ?? format.width, h = video.height ?? format.height
        return all.first { t in
            let v = t.video(for: format), a = t.audio()
            return video.codec == v.codec && w == t.width && h == t.height && video.bitrateBps == v.bitrateBps
                && video.keyframeIntervalFrames == v.keyframeIntervalFrames && audio.codec == a.codec && audio.bitrateBps == a.bitrateBps
        }
    }

    /// 新建目的地的默认档（封顶 1080p、不放大）：不高于节目的最大一档，节目比所有档都小就用最小的一档。
    static func defaultTier(for format: ProgramFormat) -> StreamQualityTier {
        all.filter { $0.height <= format.height }.max { $0.height < $1.height } ?? all.min { $0.height < $1.height }!
    }
}

/// 推流服务预设（L6 / Q31）。表在 App 资源 StreamServices.json，随版本更新；节目里只存完整地址。
struct StreamService: Identifiable, Decodable, Equatable {
    enum Kind: String, Decodable {
        /// 自定义：不填地址。
        case custom
        /// 平台每场发地址 + 推流码：不填地址，只给一句去哪拿。
        case perSession
        /// 入口固定：选中即填 url（可改）。
        case fixed
    }

    let id: String
    let kind: Kind
    /// 这个服务能用的协议（rtmp / rtmps / srt）。
    let schemes: [String]
    /// 入口地址（kind = fixed）。
    let url: String?
    /// 认地址用的前缀 / 片段（没有就用 url 去掉路径之后的部分）。
    let match: [String]?
    /// 备用入口（YouTube 的 b 入口，当第二个目的地用）。
    let backupURL: String?
    let name: [String: String]
    let hint: [String: String]

    var title: String { Self.localized(name) }
    var hintText: String { Self.localized(hint) }

    /// 按界面语言取（zh-Hans / en，缺了退英文）。
    static func localized(_ table: [String: String]) -> String {
        let lang = L10n.languageOverride ?? Bundle.main.preferredLocalizations.first ?? "en"
        let key = lang.hasPrefix("zh") ? "zh-Hans" : "en"
        return table[key] ?? table["en"] ?? table.values.first ?? ""
    }

    /// 这个地址是不是这个服务的（fixed：match 里任一片段出现在地址里；自定义按协议认）。
    func matches(url address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty else { return false }
        switch kind {
        case .fixed:
            let patterns = match ?? url.map { [$0] } ?? []
            return patterns.contains { a.contains($0.lowercased()) }
        case .custom:
            guard let scheme = a.components(separatedBy: "://").first, a.contains("://") else { return false }
            return schemes.contains(scheme)
        case .perSession:
            // 每场发的地址一般认不出；表里给了域名片段的（哔哩哔哩）照认
            return (match ?? []).contains { a.contains($0.lowercased()) }
        }
    }
}

/// 预设表（读 App 资源；读不到就只有两个自定义，界面照常能用）。
enum StreamServiceCatalog {
    struct File: Decodable {
        let version: Int
        let services: [StreamService]
    }

    static let fileName = "StreamServices"

    /// 主 bundle 里的表。
    static let all: [StreamService] = load(bundle: .main) ?? fallback

    static func load(bundle: Bundle) -> [StreamService]? {
        guard let url = bundle.url(forResource: fileName, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data).services
    }

    static func load(data: Data) throws -> [StreamService] { try JSONDecoder().decode(File.self, from: data).services }

    /// 资源丢了的兜底：两个自定义。
    static let fallback: [StreamService] = [
        StreamService(id: "customRTMP", kind: .custom, schemes: ["rtmp", "rtmps"], url: nil, match: nil, backupURL: nil, name: ["en": "Custom (RTMP / RTMPS)"], hint: [:]),
        StreamService(id: "customSRT", kind: .custom, schemes: ["srt"], url: nil, match: nil, backupURL: nil, name: ["en": "Custom (SRT)"], hint: [:]),
    ]

    static func service(id: String) -> StreamService? { all.first { $0.id == id } }

    /// 地址是哪个服务的：平台优先（按 match），再按协议落到自定义；空地址 = 自定义 RTMP。
    static func service(forURL url: String) -> StreamService {
        if let platform = all.first(where: { $0.kind != .custom && $0.matches(url: url) }) { return platform }
        if let custom = all.first(where: { $0.kind == .custom && $0.matches(url: url) }) { return custom }
        return all.first { $0.id == "customRTMP" } ?? fallback[0]
    }
}
