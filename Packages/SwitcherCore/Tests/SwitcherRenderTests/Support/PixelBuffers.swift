// 测试用像素缓冲：三种输入格式（BGRA / NV12 / UYVY）的 IOSurface 缓冲，能写能读。
import CoreVideo
import IOSurface
import SwitcherContracts

enum PixelBuffers {
    /// IOSurface 背后、Metal 兼容的像素缓冲。
    static func make(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb)
        precondition(st == kCVReturnSuccess, "CVPixelBufferCreate 失败 \(st)")
        return pb!
    }

    static func bgra(width: Int, height: Int) -> CVPixelBuffer { make(width: width, height: height, format: kCVPixelFormatType_32BGRA) }
    static func nv12(width: Int, height: Int, full: Bool = false) -> CVPixelBuffer {
        make(width: width, height: height, format: full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    static func uyvy(width: Int, height: Int) -> CVPixelBuffer { make(width: width, height: height, format: kCVPixelFormatType_422YpCbCr8) }

    /// 逐像素填 BGRA：closure 给 (x, y) → (r, g, b, a)，a 非 255 时按预乘写。
    static func fillBGRA(_ pb: CVPixelBuffer, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<h {
            let row = (base + y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let (r, g, b, a) = pixel(x, y)
                func pm(_ v: UInt8) -> UInt8 { a == 255 ? v : UInt8((Int(v) * Int(a) + 127) / 255) }
                row[x * 4] = pm(b); row[x * 4 + 1] = pm(g); row[x * 4 + 2] = pm(r); row[x * 4 + 3] = a
            }
        }
    }

    /// 逐样本填 NV12：luma(x, y) 和 chroma(cx, cy) → (cb, cr)。
    static func fillNV12(_ pb: CVPixelBuffer, luma: (Int, Int) -> UInt8, chroma: (Int, Int) -> (UInt8, UInt8)) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let y0 = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let c0 = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for y in 0..<h {
            let row = (y0 + y * ybpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { row[x] = luma(x, y) }
        }
        for cy in 0..<(h / 2) {
            let row = (c0 + cy * cbpr).assumingMemoryBound(to: UInt8.self)
            for cx in 0..<(w / 2) {
                let (cb, cr) = chroma(cx, cy)
                row[cx * 2] = cb; row[cx * 2 + 1] = cr
            }
        }
    }

    /// 逐样本填 UYVY（每两个像素 [Cb, Y0, Cr, Y1]）。
    static func fillUYVY(_ pb: CVPixelBuffer, luma: (Int, Int) -> UInt8, chroma: (Int, Int) -> (UInt8, UInt8)) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<h {
            let row = (base + y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w, by: 2) {
                let (cb, cr) = chroma(x / 2, y)
                row[x * 2] = cb; row[x * 2 + 1] = luma(x, y); row[x * 2 + 2] = cr; row[x * 2 + 3] = luma(x + 1, y)
            }
        }
    }

    /// 读 NV12 的一个亮度样本 / 一个色度样本。
    static func nv12Luma(_ pb: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        return (base + y * bpr).assumingMemoryBound(to: UInt8.self)[x]
    }
    static func nv12Chroma(_ pb: CVPixelBuffer, cx: Int, cy: Int) -> (UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let row = (base + cy * bpr).assumingMemoryBound(to: UInt8.self)
        return (row[cx * 2], row[cx * 2 + 1])
    }

    /// 整个 NV12 缓冲拷成数组（luma, chroma 交错），比一次次锁快。
    static func nv12Planes(_ pb: CVPixelBuffer) -> (luma: [UInt8], chroma: [UInt8], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let y0 = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let c0 = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        var luma = [UInt8](repeating: 0, count: w * h)
        var chroma = [UInt8](repeating: 0, count: w * (h / 2))
        for y in 0..<h { memcpy(&luma[y * w], y0 + y * ybpr, w) }
        for cy in 0..<(h / 2) { memcpy(&chroma[cy * w], c0 + cy * cbpr, w) }
        return (luma, chroma, w, h)
    }

    /// 读 BGRA 像素 (r, g, b, a)。
    static func bgraPixel(_ pb: CVPixelBuffer, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!, bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = (base + y * bpr).assumingMemoryBound(to: UInt8.self) + x * 4
        return (p[2], p[1], p[0], p[3])
    }
}
