import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwitcherContracts

/// 把 .mov / .mp4 或原始 NV12 帧目录读成 `ProbeFrame` 序列、把音轨读成单声道 float 样本。
public enum MediaReader {
    public struct VideoResult: Sendable {
        public var info: ProbeVideoInfo
        public var frames: [ProbeFrame]
    }
    public struct AudioResult: Sendable {
        public var info: ProbeAudioInfo
        /// 单声道（多声道取平均）。
        public var samples: [Float]
    }

    public enum ReaderError: Error, CustomStringConvertible {
        case noVideoTrack
        case readerFailed(String)
        case badRawFrame(String)
        public var description: String {
            switch self {
            case .noVideoTrack: "文件里没有视频轨"
            case .readerFailed(let s): "读取失败：\(s)"
            case .badRawFrame(let s): "原始帧不对：\(s)"
            }
        }
    }

    // MARK: 视频

    /// 用 AVAssetReader 解成 BGRA，逐帧解码图案并采样中心灰度。
    public static func readVideo(url: URL, progress: (@Sendable (Int) -> Void)? = nil) async throws -> VideoResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReaderError.noVideoTrack }
        let (size, nominal, timeRange) = try await track.load(.naturalSize, .nominalFrameRate, .timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ReaderError.readerFailed(reader.error?.localizedDescription ?? "startReading") }
        var frames: [ProbeFrame] = []
        var index = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if let d = TestPattern.decode(pixelBuffer: pb) {
                frames.append(ProbeFrame(index: index, ptsSeconds: pts, decoded: d, gray: grayLevel(of: pb)))
            } else {
                frames.append(ProbeFrame(index: index, ptsSeconds: pts, frameNumber: nil, inputID: nil, genTimeMs: nil, flash: false, gray: 0))
            }
            index += 1
            if index % 100 == 0 { progress?(index) }
        }
        if reader.status == .failed { throw ReaderError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        let info = ProbeVideoInfo(width: Int(size.width), height: Int(size.height), nominalFps: Double(nominal),
                                  durationSeconds: timeRange.duration.seconds, pixelFormat: "bgra")
        return VideoResult(info: info, frames: frames)
    }

    /// 原始 NV12 帧目录：`*.nv12` 按文件名排序，每个 width × height × 3/2 字节（Y 平面接 CbCr 平面，无 padding）。
    public static func readRawNV12Directory(url: URL, width: Int, height: Int, fps: Double) throws -> VideoResult {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".nv12") }.sorted()
        let expected = width * height * 3 / 2
        var frames: [ProbeFrame] = []
        for (i, name) in names.enumerated() {
            let data = try Data(contentsOf: url.appendingPathComponent(name))
            guard data.count == expected else { throw ReaderError.badRawFrame("\(name) 是 \(data.count) 字节，\(width)×\(height) NV12 应为 \(expected)") }
            var copy = data
            let (decoded, gray) = copy.withUnsafeMutableBytes { raw -> (TestPattern.Decoded, Double) in
                let base = raw.baseAddress!
                let planes = TestPattern.PixelPlanes.nv12(luma: base, lumaBytesPerRow: width, chroma: base + width * height, chromaBytesPerRow: width)
                let d = TestPattern.decode(planes, width: width, height: height)
                return (d, grayLevel(nv12Luma: base, bytesPerRow: width, width: width, height: height))
            }
            frames.append(ProbeFrame(index: i, ptsSeconds: Double(i) / fps, decoded: decoded, gray: gray))
        }
        let info = ProbeVideoInfo(width: width, height: height, nominalFps: fps, durationSeconds: Double(frames.count) / fps, pixelFormat: "nv12")
        return VideoResult(info: info, frames: frames)
    }

    // MARK: 音频

    /// 读第一条音轨为单声道 float；没有音轨返回 nil。时间线：第 0 个样本 = 第一个解码块的 PTS。
    public static func readAudio(url: URL) async throws -> AudioResult? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ReaderError.readerFailed(reader.error?.localizedDescription ?? "startReading") }
        var samples: [Float] = []
        var sampleRate = 0.0, channels = 1
        var start: Double?
        while let sb = output.copyNextSampleBuffer() {
            guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { continue }
            sampleRate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
            if start == nil { start = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frameCount = length / (4 * channels)
            var raw = [Float](repeating: 0, count: frameCount * channels)
            let status = raw.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw ReaderError.readerFailed("CMBlockBufferCopyDataBytes \(status)") }
            if channels == 1 {
                samples.append(contentsOf: raw)
            } else {
                samples.reserveCapacity(samples.count + frameCount)
                let scale = 1 / Float(channels)
                for i in 0..<frameCount {
                    var s: Float = 0
                    for c in 0..<channels { s += raw[i * channels + c] }
                    samples.append(s * scale)
                }
            }
        }
        if reader.status == .failed { throw ReaderError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        let info = ProbeAudioInfo(sampleRate: sampleRate, channels: channels, startSeconds: start ?? 0, sampleCount: samples.count)
        return AudioResult(info: info, samples: samples)
    }

    // MARK: 灰度采样

    /// 画面中心宽高各 1/4 的区域的平均灰度（full-range RGB 电平）。BGRA 取 (R+G+B)/3；NV12 由 limited Y 换算。
    public static func grayLevel(of pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        switch PixelFormat(cvPixelFormatType: CVPixelBufferGetPixelFormatType(pb)) {
        case .bgra:
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let r = centerRect(width: w, height: h)
            var sum = 0
            for y in r.y..<(r.y + r.height) {
                let row = (base + y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in r.x..<(r.x + r.width) {
                    let p = row + 4 * x
                    sum += Int(p[0]) + Int(p[1]) + Int(p[2])
                }
            }
            return Double(sum) / Double(3 * r.width * r.height)
        case .nv12:
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
            return grayLevel(nv12Luma: luma, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pb, 0), width: w, height: h)
        default:
            return 0
        }
    }

    /// NV12 亮度平面的中心区均值 → full-range 电平：(Y − 16) × 255 / 219。
    public static func grayLevel(nv12Luma luma: UnsafeRawPointer, bytesPerRow: Int, width w: Int, height h: Int) -> Double {
        let r = centerRect(width: w, height: h)
        var sum = 0
        for y in r.y..<(r.y + r.height) {
            let row = (luma + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in r.x..<(r.x + r.width) { sum += Int(row[x]) }
        }
        let meanY = Double(sum) / Double(r.width * r.height)
        return (meanY - 16) * 255 / 219
    }

    static func centerRect(width w: Int, height h: Int) -> TestPattern.Rect {
        TestPattern.Rect(x: w / 2 - w / 8, y: h / 2 - h / 8, width: max(1, w / 4), height: max(1, h / 4))
    }
}
