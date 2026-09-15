import AVFoundation
import CoreVideo

/// 测试素材：用 AVAssetWriter 写一段带 alpha 的短片（ProRes 4444 或 HEVC alpha），画面是 alpha 0.5 的纯红。
/// 探针（reports/w2-inputs.md §5）：编码器不改 RGB 值，只给 alpha 模式打标——ProRes 4444 默认 StraightAlpha、HEVC alpha 默认
/// PremultipliedAlpha（输入缓冲带 kCVImageBufferAlphaChannelModeKey 附件时跟附件走）。所以按各自默认口径写像素：
/// ProRes 直通 (B0 G0 R255 A128)，HEVC 预乘 (B0 G0 R128 A128)。
enum AlphaMovieWriter {
    static func write(to url: URL, codec: AVVideoCodecType, width: Int, height: Int, frames: Int, fps: Int32 = 30) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw NSError(domain: "AlphaMovieWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "writer 不接受 \(codec.rawValue)"]) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "AlphaMovieWriter", code: 2) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "AlphaMovieWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有像素池"]) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw NSError(domain: "AlphaMovieWriter", code: 4) }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<height {
                let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width { row[x] = codec == .hevcWithAlpha ? 0x8080_0000 : 0x80FF_0000 }   // 小端 B G R A
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: fps)) else {
                throw writer.error ?? NSError(domain: "AlphaMovieWriter", code: 5)
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "AlphaMovieWriter", code: 6) }
    }
}
