import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import SwitcherContracts

/// 测试素材：用 AVAssetWriter 现场写一段视频 + AAC 的小短片（循环泄漏测试 S2、W2-A4 的循环点 / 高速率用例：几十帧，不依赖摄像头 / 权限 / ffmpeg）。
/// 视频默认是 H.264 的逐帧变色纯色画面（320×240、30 fps），也可以是 ProRes 422 HQ 等别的编码、画测试图案（帧号 = 帧序号，解码后能读回来；
/// 噪声底色让 ProRes 每帧都重，接近 E4 源的 430 Mb/s）；音频是 440 Hz 正弦（立体声 float32 交错 → AAC 48 kHz）。
/// 视频 / 音频按时间交错喂（AVAssetWriter 有多路输入时会等落后的那路，只喂一路会卡在 isReadyForMoreMediaData）。
enum LoopClipWriter {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// 每帧画什么。
    enum FrameContent {
        /// 逐帧变色的纯色（默认）。
        case solidColor
        /// 测试图案（TestPattern）：帧号 = 帧序号，输入 ID 0，不闪光；底色自选。
        case testPattern(background: TestPattern.Background)
    }

    static func write(to url: URL, width: Int = 320, height: Int = 240, fps: Int32 = 30, frames: Int = 30,
                      sampleRate: Int = 48_000, channels: Int = 2, codec: AVVideoCodecType = .h264,
                      content: FrameContent = .solidColor) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(video), writer.canAdd(audio) else { throw Failure(description: "writer 不接受 \(codec.rawValue) / AAC 输入") }
        writer.add(video)
        writer.add(audio)

        var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var audioFormat: CMAudioFormatDescription?
        let fs = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                extensions: nil, formatDescriptionOut: &audioFormat)
        guard fs == noErr, let audioFormat else { throw Failure(description: "音频格式描述 \(fs)") }

        guard writer.startWriting() else { throw writer.error ?? Failure(description: "startWriting 失败") }
        writer.startSession(atSourceTime: .zero)

        let totalAudio = frames * sampleRate / Int(fps)
        var audioWritten = 0
        let chunk = 4096
        var pcm = [Float](repeating: 0, count: chunk * channels)

        /// 把音频写到 `seconds`（不超过总长）；输入没 ready 就先回来。
        func feedAudio(upTo seconds: Double) throws {
            while audioWritten < totalAudio, Double(audioWritten) / Double(sampleRate) < seconds, audio.isReadyForMoreMediaData {
                let n = min(chunk, totalAudio - audioWritten)
                for i in 0..<n {
                    let v = sinf(Float(2 * Double.pi * 440 * Double(audioWritten + i) / Double(sampleRate))) * 0.5
                    for c in 0..<channels { pcm[i * channels + c] = v }
                }
                let bytes = n * 4 * channels
                var block: CMBlockBuffer?
                let bs = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
                guard bs == noErr, let block else { throw Failure(description: "CMBlockBuffer \(bs)") }
                try pcm.withUnsafeBytes { raw in
                    let r = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
                    guard r == noErr else { throw Failure(description: "ReplaceDataBytes \(r)") }
                }
                var sample: CMSampleBuffer?
                let pts = CMTime(value: Int64(audioWritten), timescale: CMTimeScale(sampleRate))
                let ss = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat,
                                                                              sampleCount: n, presentationTimeStamp: pts, packetDescriptions: nil,
                                                                              sampleBufferOut: &sample)
                guard ss == noErr, let sample else { throw Failure(description: "音频样本 \(ss)") }
                guard audio.append(sample) else { throw writer.error ?? Failure(description: "append audio 失败") }
                audioWritten += n
            }
        }

        for i in 0..<frames {
            while !video.isReadyForMoreMediaData {
                try feedAudio(upTo: Double(i + 1) / Double(fps))
                usleep(500)
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure(description: "没有像素池") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw Failure(description: "像素池给不出缓冲") }
            switch content {
            case .solidColor:
                CVPixelBufferLockBaseAddress(pb, [])
                let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
                let color: UInt32 = 0xFF00_0000 | UInt32((i * 37) & 0xff) << 16 | UInt32((i * 91) & 0xff) << 8 | UInt32((i * 53) & 0xff)
                for y in 0..<height {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width { row[x] = color }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
            case .testPattern(let background):
                let c = TestPattern.Content(frameNumber: UInt32(i), hostTimeMs: 0, inputID: 0, flash: false, background: background)
                guard TestPattern.draw(c, into: pb) else { throw Failure(description: "图案画不进像素缓冲") }
            }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: fps)) else {
                throw writer.error ?? Failure(description: "append video 失败")
            }
            try feedAudio(upTo: Double(i + 1) / Double(fps))
        }
        video.markAsFinished()
        while audioWritten < totalAudio {
            try feedAudio(upTo: .infinity)
            if audioWritten < totalAudio { usleep(500) }
        }
        audio.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? Failure(description: "finishWriting \(writer.status.rawValue)") }
    }
}
