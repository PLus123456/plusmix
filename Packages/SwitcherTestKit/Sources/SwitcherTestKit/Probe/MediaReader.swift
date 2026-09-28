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
        /// 每帧的图案读数（自证解码要的证据，见 `SelfCheck`）；与 `frames` 一一对应。
        public var readings: [PatternProbe.Reading] = []
        /// 灰度剖面，键是帧序号；只有 `profileAt` 说要的那几帧有（Wipe / Zoom 的进度量法要，见 `ScanProfile`）。
        public var profiles: [Int: ScanProfile] = [:]
    }
    public struct AudioResult: Sendable {
        /// `startSeconds` 是 AVFoundation 解码输出第一个样本的 PTS（编排层按容器 / priming 修正后再改）。
        public var info: ProbeAudioInfo
        /// 单声道（多声道取平均）。
        public var samples: [Float]
        /// 编码（直通样本格式描述的子类型："aac " / "lpcm" / …）。
        public var codec: String
        /// AVFoundation 从解码输出头上裁掉的样本数（直通第一个样本的 TrimDurationAtStart；容器有 elst 时按 elst，没有时它对 AAC 自己按 2112 裁）。
        public var primingTrimmedSamples: Int
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
    /// - Parameter profileAt: 给定 pts（秒）返回 true 的帧另外算一遍灰度剖面（`ScanProfile`）；默认一帧都不算。
    public static func readVideo(url: URL, profileAt: (@Sendable (Double) -> Bool)? = nil,
                                 progress: (@Sendable (Int) -> Void)? = nil) async throws -> VideoResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReaderError.noVideoTrack }
        let (size, nominal, timeRange) = try await track.load(.naturalSize, .nominalFrameRate, .timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ReaderError.readerFailed(reader.error?.localizedDescription ?? "startReading") }
        var frames: [ProbeFrame] = []
        var readings: [PatternProbe.Reading] = []
        var profiles: [Int: ScanProfile] = [:]
        var index = 0
        var more = true
        repeat {
            // 每帧一个自动释放池（见 `readAudio` 循环前的说明）
            more = autoreleasepool { () -> Bool in
                guard let sb = output.copyNextSampleBuffer() else { return false }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return true }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                let reading = PatternProbe.read(pixelBuffer: pb) ?? .unreadable
                frames.append(ProbeFrame(index: index, ptsSeconds: pts, reading: reading))
                readings.append(reading)
                if profileAt?(pts) == true, let p = ScanProfile.measure(pixelBuffer: pb) { profiles[index] = p }
                index += 1
                if index % 100 == 0 { progress?(index) }
                return true
            }
        } while more
        if reader.status == .failed { throw ReaderError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        let info = ProbeVideoInfo(width: Int(size.width), height: Int(size.height), nominalFps: Double(nominal),
                                  durationSeconds: timeRange.duration.seconds, pixelFormat: "bgra")
        return VideoResult(info: info, frames: frames, readings: readings, profiles: profiles)
    }

    /// 只读容器标称帧率（不解帧）：算"哪几帧要做灰度剖面"时要先知道拍号怎么换算。
    public static func nominalFps(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReaderError.noVideoTrack }
        return Double(try await track.load(.nominalFrameRate))
    }

    /// 原始 NV12 帧目录：`*.nv12` 按文件名排序，每个 width × height × 3/2 字节（Y 平面接 CbCr 平面，无 padding）。
    public static func readRawNV12Directory(url: URL, width: Int, height: Int, fps: Double,
                                            profileAt: (@Sendable (Double) -> Bool)? = nil) throws -> VideoResult {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".nv12") }.sorted()
        let expected = width * height * 3 / 2
        var frames: [ProbeFrame] = []
        var readings: [PatternProbe.Reading] = []
        var profiles: [Int: ScanProfile] = [:]
        for (i, name) in names.enumerated() {
            try autoreleasepool {
                let data = try Data(contentsOf: url.appendingPathComponent(name))
                guard data.count == expected else { throw ReaderError.badRawFrame("\(name) 是 \(data.count) 字节，\(width)×\(height) NV12 应为 \(expected)") }
                let pts = Double(i) / fps
                var copy = data
                let (reading, profile) = copy.withUnsafeMutableBytes { raw -> (PatternProbe.Reading, ScanProfile?) in
                    let base = raw.baseAddress!
                    let planes = TestPattern.PixelPlanes.nv12(luma: base, lumaBytesPerRow: width, chroma: base + width * height, chromaBytesPerRow: width)
                    return (PatternProbe.read(planes, width: width, height: height),
                            profileAt?(pts) == true ? ScanProfile.measure(planes, width: width, height: height) : nil)
                }
                frames.append(ProbeFrame(index: i, ptsSeconds: pts, reading: reading))
                readings.append(reading)
                if let profile { profiles[i] = profile }
            }
        }
        let info = ProbeVideoInfo(width: width, height: height, nominalFps: fps, durationSeconds: Double(frames.count) / fps, pixelFormat: "nv12")
        return VideoResult(info: info, frames: frames, readings: readings, profiles: profiles)
    }

    // MARK: 音频

    /// 读第一条音轨为单声道 float；没有音轨返回 nil。时间线：第 0 个样本 = 第一个解码块的 PTS（AVFoundation 口径；
    /// 没有编辑列表的分片文件它会把轨归零并裁 2112 样本 priming，编排层 `FrameProbe.load` 按 `MP4Index` 修正——见 MP4Index 的说明）。
    public static func readAudio(url: URL) async throws -> AudioResult? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let trackSeconds = try await track.load(.timeRange).duration.seconds
        // 直通读第一个样本：编码类型与 AVFoundation 打算裁掉的 priming 样本数
        var codec = ""
        var trimmed = 0
        try autoreleasepool {
            let pass = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            pass.add(out)
            if pass.startReading(), let sb = out.copyNextSampleBuffer() {
                if let fd = CMSampleBufferGetFormatDescription(sb) { codec = fourCC(CMFormatDescriptionGetMediaSubType(fd)) }
                if let att = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) {
                    let t = CMTimeMakeFromDictionary(att as! CFDictionary)
                    if t.isValid, t.timescale > 0 { trimmed = Int(t.value) }
                }
            }
            pass.cancelReading()
        }
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
        // 每块一个自动释放池：整条文件的循环在一个 async 函数里一口气跑完（中间没有挂起点），取样本时 AVFoundation / CoreMedia
        // 若往调用线程 autorelease 东西，没有这层池就要攒到整个循环结束。macOS 27 上量过，这两个循环每块往调用线程放的是 0 个
        // （每块一条的 NSKVONotifying_AVAssetReaderTrackOutput 在 AVFoundation 自己的线程上，我们管不着），内存涨是上面
        // expectedSampleCount 那一条；池留着防别的系统版本 / 以后在循环里查 reader.status 之类（W1-A4，W2-A3 在裸线程上撞过）。
        var more = true
        repeat {
            more = try autoreleasepool { () throws -> Bool in
                guard let sb = output.copyNextSampleBuffer() else { return false }
                guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return true }
                sampleRate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
                if start == nil {
                    start = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    samples.reserveCapacity(expectedSampleCount(trackSeconds: trackSeconds, sampleRate: sampleRate))
                }
                guard let block = CMSampleBufferGetDataBuffer(sb) else { return true }
                let length = CMBlockBufferGetDataLength(block)
                let frameCount = length / (4 * channels)
                var raw = [Float](repeating: 0, count: frameCount * channels)
                let status = raw.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw ReaderError.readerFailed("CMBlockBufferCopyDataBytes \(status)") }
                if channels == 1 {
                    samples.append(contentsOf: raw)
                } else {
                    let scale = 1 / Float(channels)
                    for i in 0..<frameCount {
                        var s: Float = 0
                        for c in 0..<channels { s += raw[i * channels + c] }
                        samples.append(s * scale)
                    }
                }
                return true
            }
        } while more
        if reader.status == .failed { throw ReaderError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        let info = ProbeAudioInfo(sampleRate: sampleRate, channels: channels, startSeconds: start ?? 0, sampleCount: samples.count)
        // 直通样本的 trim 是按格式描述的采样率计的；解码输出采样率相同（AAC-LC 48 kHz 就是 48 kHz），不换算
        return AudioResult(info: info, samples: samples, codec: codec, primingTrimmedSamples: trimmed)
    }

    /// 整条音轨的样本数预估（轨长 × 采样率，多留 1 s），读第一块时一次预留。
    ///
    /// 为什么不逐块 `reserveCapacity(count + frameCount)`：Swift 的 reserveCapacity 按"刚好够"分配、不按倍数长，
    /// 每块（约 8192 帧）都把整个数组重新分配、整条拷一遍（O(n²)），放掉的旧块也不还给系统（phys_footprint 不回落）——
    /// 立体声 1 分钟峰值 0.7 GB、10 分钟 7.6 GB、1 小时 41 GB，耗时也跟着平方涨（W1-A4，问题单 W4A-…-memory-grows-with-length）。
    /// 预估偏小也没关系，超出的部分 append 照常按倍数长；轨长读不出或离谱（超过 2^31 个样本）就不预留。
    static func expectedSampleCount(trackSeconds: Double, sampleRate: Double) -> Int {
        let expected = (trackSeconds + 1) * sampleRate
        guard trackSeconds > 0, expected.isFinite, expected > 0, expected < Double(Int32.max) else { return 0 }
        return Int(expected.rounded(.up))
    }

    static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
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
