// V6 / V7 的量法：输出 NV12 的亮度平面 → 覆盖率 / 纯帧判定 / 边缘位置。
// 输入 A 灰 64 → Y 71，输入 B 灰 192 → Y 181（BGRA → BT.709 limited，P1 报告的换算），与 frameprobe 的 V7 口径同一组数。
import CoreVideo
import Foundation

struct LumaPlane {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        width = CVPixelBufferGetWidth(pb)
        height = CVPixelBufferGetHeight(pb)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { memcpy(&out[y * width], base + y * bpr, width) }
        bytes = out
    }

    subscript(x: Int, y: Int) -> Int { Int(bytes[y * width + x]) }

    /// 整幅均值。
    var mean: Double { Double(bytes.reduce(0) { $0 + Int($1) }) / Double(bytes.count) }

    /// 某个矩形（像素）的均值。
    func mean(x: Int, y: Int, width w: Int, height h: Int) -> Double {
        var sum = 0
        for yy in y..<(y + h) { for xx in x..<(x + w) { sum += self[xx, yy] } }
        return Double(sum) / Double(w * h)
    }

    /// 每个像素都等于 value（± tolerance）。
    func isUniform(_ value: Int, tolerance: Int = 1) -> Bool {
        bytes.allSatisfy { abs(Int($0) - value) <= tolerance }
    }

    /// 某个矩形里每个像素都等于 value（± tolerance）。
    func isUniform(_ value: Int, x: Int, y: Int, width w: Int, height h: Int, tolerance: Int = 1) -> Bool {
        for yy in y..<(y + h) { for xx in x..<(x + w) where abs(self[xx, yy] - value) > tolerance { return false } }
        return true
    }

    /// 第 y 行里"更接近 newValue 而不是 oldValue"的像素数（Zoom 的尺度量法：新画面在中心行的宽度）。
    func countNearer(to newValue: Int, than oldValue: Int, row y: Int) -> Int {
        var n = 0
        for x in 0..<width where abs(self[x, y] - newValue) < abs(self[x, y] - oldValue) { n += 1 }
        return n
    }
}

/// 灰 64 / 192 两路的换算。
enum GrayLevels {
    /// 输入 A（旧画面）。
    static let oldLuma = 71
    /// 输入 B（新画面）。
    static let newLuma = 181
    /// 均值 → 新画面占比（面积覆盖率 / 混合比例，两者在这组输入上是同一个数）。
    static func coverage(mean: Double) -> Double { (mean - Double(oldLuma)) / Double(newLuma - oldLuma) }
}
