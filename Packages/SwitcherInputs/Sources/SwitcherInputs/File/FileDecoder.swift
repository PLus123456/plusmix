import AVFoundation
import CoreMedia
import CoreVideo
import SwitcherContracts

/// 打开的媒体文件：轨道信息 + 按需建 AVAssetReader（每次 seek / 循环重开一个；探针实测重开 2 ms + 从关键帧解到目标帧）。
/// 解码走 AVAssetReaderTrackOutput（内部是 VideoToolbox；macOS 26 探针：H.264 1080p60 解 2700 fps，硬解）。
/// 输出 NV12 '420v'（源是 full range 时 '420f'），带 alpha 的源（ProRes 4444 / HEVC alpha：格式描述 ContainsAlphaChannel）输出 BGRA。
/// 视频轨的 `preferredTransform`（手机竖拍的方向矩阵）归成 `FileOrientation`，`FileReader.nextVideo` 出的帧已按它转正（`PixelRotator`，D15）。
/// 打开后的文件信息。
public struct FileInfo: Sendable, Hashable {
        /// 视频时长（秒，视频轨的 timeRange）。
        public let duration: Rational
        /// 一帧时长（秒，minFrameDuration；没有时按 nominalFrameRate）。
        public let frameDuration: Rational
        public let nominalFrameRate: Double
        /// 编码宽（解码器原样给的像素宽；转正之前）。
        public let width: Int
        /// 编码高。
        public let height: Int
        /// 视频轨方向矩阵归成的方向（D15）；FileInput 出的帧已按它转正。认不出的矩阵（任意角度）按 `.identity`（原样出）。
        public let orientation: FileOrientation
        /// 转正后的宽 = FileInput 出帧的宽。
        public var displayWidth: Int { orientation.swapsAxes ? height : width }
        /// 转正后的高。
        public var displayHeight: Int { orientation.swapsAxes ? width : height }
        public let hasAlpha: Bool
        public let fullRange: Bool
        public let color: ColorInfo
        public let hasAudio: Bool
        public let audioChannels: Int
        public let codec: String
    }

final class FileAsset: @unchecked Sendable {
    typealias Info = FileInfo
    let url: URL
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let info: Info
    /// 转正器（方向不是 identity 时有；只在解码线程用）。
    let rotator: PixelRotator?
    /// 方向矩阵认不出（任意角度）或转正器建不出来时的一句话（按原样出帧）；FileInput 放进 lastError 的提示。
    let orientationNote: String?

    enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        case noVideoTrack(String)
        case load(String, String)
        var description: String {
            switch self {
            case .notFound(let p): "文件不存在：\(p)"
            case .noVideoTrack(let p): "文件里没有视频轨：\(p)"
            case .load(let p, let e): "打不开文件 \(p)：\(e)"
            }
        }
    }

    /// 同步打开（start() 在普通线程，允许阻塞）。
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.notFound(url.path) }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset
        let loaded = FileAsset.blocking { () -> LoadedTracks in
            let out = LoadedTracks()
            out.video = try await asset.loadTracks(withMediaType: .video).first
            out.audio = try await asset.loadTracks(withMediaType: .audio).first
            guard let v = out.video else { return out }
            out.range = try await v.load(.timeRange)
            out.minDur = try await v.load(.minFrameDuration)
            out.nominal = try await v.load(.nominalFrameRate)
            out.transform = try await v.load(.preferredTransform)
            out.vdesc = try await v.load(.formatDescriptions)
            out.adesc = try await out.audio?.load(.formatDescriptions) ?? []
            return out
        }
        let t: LoadedTracks
        switch loaded {
        case .success(let l): t = l
        case .failure(let e): throw Failure.load(url.path, "\(e)")
        }
        guard let v = t.video else { throw Failure.noVideoTrack(url.path) }
        let (a, range, minDur, nominal, vdesc, adesc) = (t.audio, t.range, t.minDur, t.nominal, t.vdesc, t.adesc)
        videoTrack = v
        audioTrack = a
        var hasAlpha = false, fullRange = false, width = 0, height = 0, codec = "?"
        var color = ColorInfo.bt709Limited
        if let d = vdesc.first {
            let dims = CMVideoFormatDescriptionGetDimensions(d)
            width = Int(dims.width); height = Int(dims.height)
            let sub = CMFormatDescriptionGetMediaSubType(d)
            codec = String(format: "%c%c%c%c", (sub >> 24) & 0xff, (sub >> 16) & 0xff, (sub >> 8) & 0xff, sub & 0xff)
            let ext = CMFormatDescriptionGetExtensions(d) as? [String: Any] ?? [:]
            if let v = ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool { hasAlpha = v }
            else if let n = ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? NSNumber { hasAlpha = n.boolValue }
            if !hasAlpha, let depth = ext[kCMFormatDescriptionExtension_Depth as String] as? Int, depth == 32 { hasAlpha = true }
            if let fr = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool { fullRange = fr }
            else if let n = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber { fullRange = n.boolValue }
            if let m = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
                if m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String) { color.matrix = .bt601 }
                else if m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) { color.matrix = .bt2020 }
            }
            if let p = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String {
                if p == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) { color.primaries = .bt2020 }
                else if p == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) { color.primaries = .displayP3 }
            }
            color.range = fullRange ? .full : .limited
        }
        var channels = 0
        if let d = adesc.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) { channels = Int(asbd.pointee.mChannelsPerFrame) }
        let duration = Rational(range.duration.value, Int64(max(range.duration.timescale, 1)))
        var frameDuration: Rational
        if minDur.isValid, minDur.value > 0 { frameDuration = Rational(minDur.value, Int64(minDur.timescale)) }
        else if nominal > 0 { frameDuration = Rational(approximating: 1 / Double(nominal), maxDenominator: 60_000) }
        else { frameDuration = Rational(1, 30) }
        // 方向（D15）：只认轴对齐的八种；认不出的按原样出、说一句
        let t0 = t.transform
        let recognized = FileOrientation(transform: t0)
        let orientation = recognized ?? .identity
        rotator = PixelRotator(orientation: orientation)
        if recognized == nil {
            orientationNote = "视频方向矩阵 (\(t0.a), \(t0.b), \(t0.c), \(t0.d)) 不是 90° 的整数倍，按编码方向原样出"
        } else if orientation != .identity && rotator == nil {
            orientationNote = "建不出转正用的 VTPixelRotationSession，按编码方向原样出（方向 \(orientation.rawValue)）"
        } else {
            orientationNote = nil
        }
        info = Info(duration: duration, frameDuration: frameDuration, nominalFrameRate: Double(nominal), width: width, height: height,
                    orientation: rotator == nil ? .identity : orientation,
                    hasAlpha: hasAlpha, fullRange: fullRange, color: hasAlpha ? .sRGBFull : color,
                    hasAudio: a != nil && channels > 0, audioChannels: channels, codec: codec)
    }

    /// 视频输出像素格式。
    var videoPixelFormat: OSType {
        if info.hasAlpha { return kCVPixelFormatType_32BGRA }
        return info.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// 从媒体位置 start（秒，文件内）建一个 reader。
    func makeReader(from start: Rational) throws -> FileReader {
        try FileReader(asset: self, start: start)
    }

    /// 在普通线程同步等一个 async 任务。
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, any Error> {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    final class ResultBox<T: Sendable>: @unchecked Sendable {
        var value: Result<T, any Error>?
    }

    /// 异步加载的结果箱（AVAssetTrack 不是 Sendable，装箱后只在打开线程读）。
    final class LoadedTracks: @unchecked Sendable {
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var range = CMTimeRange.zero
        var minDur = CMTime.zero
        var nominal: Float = 0
        var transform = CGAffineTransform.identity
        var vdesc: [CMFormatDescription] = []
        var adesc: [CMFormatDescription] = []
    }
}

/// 一个 AVAssetReader：从某个位置读到结尾。视频 / 音频各一个 track output，各自 copyNextSampleBuffer（阻塞解码）。
final class FileReader: @unchecked Sendable {
    let reader: AVAssetReader
    let video: AVAssetReaderTrackOutput
    let audio: AVAssetReaderTrackOutput?
    let start: Rational
    private let assetInfo: FileAsset.Info
    private let rotator: PixelRotator?

    init(asset: FileAsset, start: Rational) throws {
        self.start = start
        assetInfo = asset.info
        rotator = asset.rotator
        reader = try AVAssetReader(asset: asset.asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: asset.videoPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        video = AVAssetReaderTrackOutput(track: asset.videoTrack, outputSettings: settings)
        video.alwaysCopiesSampleData = false
        reader.add(video)
        if let a = asset.audioTrack, asset.info.hasAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioFormat.sampleRate,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let out = AVAssetReaderTrackOutput(track: a, outputSettings: audioSettings)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            audio = out
        } else {
            audio = nil
        }
        if start.numerator > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(value: start.numerator, timescale: Int32(clamping: start.denominator)), duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw FileAsset.Failure.load(asset.url.path, reader.error.map { "\($0)" } ?? "startReading 失败")
        }
    }

    /// 下一帧视频：(文件内媒体位置, 像素缓冲)；结尾 / 出错返回 nil。方向不是 identity 的已转正（D15）；转不了的这一帧原样出（`rotator.failures`）。
    func nextVideo() -> (Rational, CVPixelBuffer)? {
        while let sb = video.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard let pb = CMSampleBufferGetImageBuffer(sb), pts.isValid else { continue }
            let t = Rational(pts.value, Int64(pts.timescale))
            // 有的 reader 配置会在结尾多给一个 pts == 时长的样本（探针：supportsRandomAccess 时），跳过
            if t >= assetInfo.duration { continue }
            if let rotator, let upright = rotator.rotate(pb) { return (t, upright) }
            return (t, pb)
        }
        return nil
    }

    /// 下一块音频。
    func nextAudio() -> CMSampleBuffer? { audio?.copyNextSampleBuffer() }

    var error: (any Error)? { reader.error }
    var status: AVAssetReader.Status { reader.status }

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
    }
}
