import CoreVideo
import IOSurface
import SwitcherContracts

/// 像素缓冲的小工具：建 IOSurface 背后的缓冲、黑场、alpha 预乘。都在输入线程用（允许分配）。
enum PixelBuffers {
    enum Failure: Error, Equatable {
        case createFailed(CVReturn)
    }

    /// 建一个 IOSurface 背后、Metal 可用的缓冲。
    static func make(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let r = CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb)
        guard r == kCVReturnSuccess, let pb else { throw Failure.createFailed(r) }
        return pb
    }

    /// 全黑：NV12 写 Y 16 / CbCr 128（limited）；BGRA 写 0,0,0,255。
    static func fill(black pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let format = CVPixelBufferGetPixelFormatType(pb)
        if format == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let stride = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            for y in 0..<h {
                let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<w { row[x] = 0xFF00_0000 }
            }
        } else {
            for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { continue }
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane)
                let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                memset(base, plane == 0 ? (full ? 0 : 16) : 128, bytes)
            }
        }
    }

    /// 直通 alpha → 预乘 alpha，就地（渲染器的 BGRA 约定是预乘，Compositor.metal 头注释）。
    static func premultiplyInPlace(_ pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        for y in 0..<h {
            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < w * 4 {
                let a = UInt32(row[x + 3])
                if a != 255 {
                    row[x] = UInt8((UInt32(row[x]) * a + 127) / 255)
                    row[x + 1] = UInt8((UInt32(row[x + 1]) * a + 127) / 255)
                    row[x + 2] = UInt8((UInt32(row[x + 2]) * a + 127) / 255)
                }
                x += 4
            }
        }
    }

    /// 缓冲的 alpha 模式附件（kCVImageBufferAlphaChannelModeKey）：解码器标了 StraightAlpha 才需要预乘。
    static func isStraightAlpha(_ pb: CVPixelBuffer) -> Bool {
        guard let v = CVBufferCopyAttachment(pb, kCVImageBufferAlphaChannelModeKey, nil) else { return false }
        return CFEqual(v, kCVImageBufferAlphaChannelMode_StraightAlpha)
    }

    /// 从缓冲附件推 ColorInfo（摄像头 / 采集卡可能是 601；范围由像素格式定）。
    static func colorInfo(of pb: CVPixelBuffer, default fallback: ColorInfo) -> ColorInfo {
        var c = fallback
        let format = CVPixelBufferGetPixelFormatType(pb)
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { c.range = .full }
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { c.range = .limited }
        if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) {
            if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_601_4) { c.matrix = .bt601 }
            else if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_2020) { c.matrix = .bt2020 }
            else if CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_709_2) { c.matrix = .bt709 }
        }
        if let p = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) {
            if CFEqual(p, kCVImageBufferColorPrimaries_ITU_R_2020) { c.primaries = .bt2020 }
            else if CFEqual(p, kCVImageBufferColorPrimaries_P3_D65) { c.primaries = .displayP3 }
            else if CFEqual(p, kCVImageBufferColorPrimaries_ITU_R_709_2) { c.primaries = .bt709 }
        }
        return c
    }
}
