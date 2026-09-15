// PSNR / SSIM（V8 的判据）和 PNG 读写、参考图路径。
import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 8-bit BGRA 位图（按行连续，bytesPerRow = width × 4）。
struct Bitmap {
    let width: Int
    let height: Int
    var bgra: [UInt8]

    init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    /// 任意 CGImage 画进 sRGB 预乘 BGRA。
    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bgra = bytes
    }

    /// (r, g, b, a)。
    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]), Int(bgra[i + 3]))
    }

    /// BT.709 亮度（0–255，full range），SSIM 用。
    func luma() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let b = Float(bgra[i * 4]), g = Float(bgra[i * 4 + 1]), r = Float(bgra[i * 4 + 2])
            out[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return out
    }
}

enum ImageMetrics {
    /// 三个颜色通道一起算的 PSNR（dB）；完全一致返回 +∞。
    static func psnr(_ a: Bitmap, _ b: Bitmap) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        var se: Double = 0
        var n = 0
        for i in stride(from: 0, to: a.bgra.count, by: 4) {
            for c in 0..<3 {
                let d = Double(a.bgra[i + c]) - Double(b.bgra[i + c])
                se += d * d
            }
            n += 3
        }
        let mse = se / Double(n)
        return mse == 0 ? .infinity : 10 * log10(255.0 * 255.0 / mse)
    }

    /// 标准 SSIM（Wang 2004）：亮度通道，11×11 高斯窗 σ = 1.5，C1 = (0.01·255)²，C2 = (0.03·255)²，取全图均值。vDSP 做卷积。
    static func ssim(_ a: Bitmap, _ b: Bitmap) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        let w = a.width, h = a.height
        let x = a.luma(), y = b.luma()
        let mu1 = gaussianBlur(x, w, h), mu2 = gaussianBlur(y, w, h)
        var xx = [Float](repeating: 0, count: w * h), yy = xx, xy = xx
        vDSP.multiply(x, x, result: &xx)
        vDSP.multiply(y, y, result: &yy)
        vDSP.multiply(x, y, result: &xy)
        let s11 = gaussianBlur(xx, w, h), s22 = gaussianBlur(yy, w, h), s12 = gaussianBlur(xy, w, h)
        let c1: Float = (0.01 * 255) * (0.01 * 255), c2: Float = (0.03 * 255) * (0.03 * 255)
        var sum: Double = 0
        for i in 0..<(w * h) {
            let m1 = mu1[i], m2 = mu2[i]
            let v1 = s11[i] - m1 * m1, v2 = s22[i] - m2 * m2, cov = s12[i] - m1 * m2
            let ssim = ((2 * m1 * m2 + c1) * (2 * cov + c2)) / ((m1 * m1 + m2 * m2 + c1) * (v1 + v2 + c2))
            sum += Double(ssim)
        }
        return sum / Double(w * h)
    }

    /// 可分离高斯（11 抽头 σ 1.5），边缘按复制处理（先扩边再卷）。
    static func gaussianBlur(_ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        let radius = 5
        var kernel = (0...(2 * radius)).map { i -> Float in
            let d = Float(i - radius)
            return exp(-d * d / (2 * 1.5 * 1.5))
        }
        let ksum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / ksum }
        // 横向
        let pw = w + 2 * radius
        var padded = [Float](repeating: 0, count: pw * h)
        for yy in 0..<h {
            for xx in 0..<pw { padded[yy * pw + xx] = src[yy * w + min(max(xx - radius, 0), w - 1)] }
        }
        var tmp = [Float](repeating: 0, count: w * h)
        padded.withUnsafeBufferPointer { p in
            tmp.withUnsafeMutableBufferPointer { t in
                for yy in 0..<h {
                    vDSP_conv(p.baseAddress! + yy * pw, 1, kernel, 1, t.baseAddress! + yy * w, 1, vDSP_Length(w), vDSP_Length(kernel.count))
                }
            }
        }
        // 纵向：转置一下再横向卷
        var transposed = [Float](repeating: 0, count: w * h)
        vDSP_mtrans(tmp, 1, &transposed, 1, vDSP_Length(w), vDSP_Length(h))
        let ph = h + 2 * radius
        var padded2 = [Float](repeating: 0, count: ph * w)
        for xx in 0..<w {
            for yy in 0..<ph { padded2[xx * ph + yy] = transposed[xx * h + min(max(yy - radius, 0), h - 1)] }
        }
        var tmp2 = [Float](repeating: 0, count: w * h)
        padded2.withUnsafeBufferPointer { p in
            tmp2.withUnsafeMutableBufferPointer { t in
                for xx in 0..<w {
                    vDSP_conv(p.baseAddress! + xx * ph, 1, kernel, 1, t.baseAddress! + xx * h, 1, vDSP_Length(h), vDSP_Length(kernel.count))
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        vDSP_mtrans(tmp2, 1, &out, 1, vDSP_Length(h), vDSP_Length(w))
        return out
    }
}

enum PNG {
    /// 写 PNG（ImageIO）。
    static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PNG", code: 1, userInfo: [NSLocalizedDescriptionKey: "建不出 \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "PNG", code: 2, userInfo: [NSLocalizedDescriptionKey: "写不了 \(url.path)"])
        }
    }

    /// 读 PNG；不存在返回 nil。
    static func read(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

enum RepoPaths {
    /// 仓库根：本文件在 Packages/SwitcherCore/Tests/SwitcherRenderTests/Support/ 下。
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()
    /// Tests/References/。
    static let references = root.appendingPathComponent("Tests/References")
    /// 测试输出（不入库）：仓库根 .build/render-test-output/。
    static let output = root.appendingPathComponent(".build/render-test-output")

    /// SWITCHER_GEN_REFERENCES=1 时测试改为写参考图。
    static var generatingReferences: Bool { ProcessInfo.processInfo.environment["SWITCHER_GEN_REFERENCES"] == "1" }
}
