import CoreVideo
import Foundation
import SwitcherContracts

/// 一帧的三条灰度剖面：Wipe / Zoom 的进度量法要的就是"某一列 / 某一行有多亮"（W1-A3）。
///
/// 只对要量的那几拍算（`FrameProbe.Options.transitionAt` / `transitionDuration` 圈出来的窗口），
/// 一帧 1080p 约 70 万次采样，25 帧的窗口可以忽略；全片每帧都算会让 10 分钟的文件慢一倍。
///
/// 取样带特意避开测试图案的四样东西（帧号行、时间戳行、ID 块、闪光块）：
/// - `columns[x]`：第 x 列在 y ∈ [ID 块下缘 + 一个块高, 画面底] 上的平均灰度 —— 左右方向的 Wipe 用。
/// - `rows[y]`：第 y 行在 x ∈ [码字行右缘 + 一个块高, 闪光块左缘 − 一个块高] 上的平均灰度 —— 上下方向的 Wipe 用。
/// - `centerColumns[x]`：第 x 列在画面中心那条高 h/32 的带上的平均灰度 —— Zoom 用（新画面在中心行上的宽度）。
public struct ScanProfile: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// 每列的平均灰度（长度 = width）。
    public var columns: [Double]
    /// 每行的平均灰度（长度 = height）。
    public var rows: [Double]
    /// 每列在中心行带上的平均灰度（长度 = width）。
    public var centerColumns: [Double]
    /// `columns` 取样的行范围（含起、不含止）。
    public var columnBand: ClosedRange<Int>
    /// `rows` 取样的列范围。
    public var rowBand: ClosedRange<Int>

    public init(width: Int, height: Int, columns: [Double], rows: [Double], centerColumns: [Double],
                columnBand: ClosedRange<Int>, rowBand: ClosedRange<Int>) {
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.centerColumns = centerColumns
        self.columnBand = columnBand
        self.rowBand = rowBand
    }

    /// 从像素平面算三条剖面。`stride` 是垂直于剖面方向上的取样步长（4 = 每 4 行 / 4 列取一条）。
    public static func measure(_ planes: TestPattern.PixelPlanes, width w: Int, height h: Int, stride step: Int = 4) -> ScanProfile {
        let g = TestPattern.Geometry(width: w, height: h)
        let colTop = min(h - 2, g.idRect.y + g.idRect.height + g.blockSize)
        let rowLeft = min(w - 2, g.originX + TestPattern.blockCount * g.blockSize + g.blockSize)
        let rowRight = max(rowLeft + 1, g.flashRect.x - g.blockSize)
        let halfBand = max(2, h / 64)
        var columns = [Double](repeating: 0, count: w)
        var rows = [Double](repeating: 0, count: h)
        var center = [Double](repeating: 0, count: w)
        for x in 0..<w {
            columns[x] = mean(planes, x: x, x2: x + 1, y: colTop, y2: h, strideY: step)
            center[x] = mean(planes, x: x, x2: x + 1, y: h / 2 - halfBand, y2: h / 2 + halfBand, strideY: 1)
        }
        for y in 0..<h {
            rows[y] = mean(planes, x: rowLeft, x2: rowRight, y: y, y2: y + 1, strideX: step)
        }
        return ScanProfile(width: w, height: h, columns: columns, rows: rows, centerColumns: center,
                           columnBand: colTop...(h - 1), rowBand: rowLeft...(rowRight - 1))
    }

    /// 矩形内的平均 full-range 灰度电平（带步长）。
    static func mean(_ planes: TestPattern.PixelPlanes, x: Int, x2: Int, y: Int, y2: Int, strideX: Int = 1, strideY: Int = 1) -> Double {
        let x0 = max(0, x), y0 = max(0, y)
        var sum = 0.0, count = 0
        switch planes {
        case .bgra(let base, let bpr):
            var yy = y0
            while yy < y2 {
                let row = (base + yy * bpr).assumingMemoryBound(to: UInt32.self)
                var xx = x0
                while xx < x2 {
                    let p = row[xx]
                    sum += Double(Int((p >> 16) & 0xFF) + Int((p >> 8) & 0xFF) + Int(p & 0xFF)) / 3
                    count += 1
                    xx += strideX
                }
                yy += strideY
            }
        case .nv12(let luma, let bpr, _, _):
            var yy = y0
            while yy < y2 {
                let row = (luma + yy * bpr).assumingMemoryBound(to: UInt8.self)
                var xx = x0
                while xx < x2 {
                    sum += (Double(row[xx]) - 16) * 255 / 219
                    count += 1
                    xx += strideX
                }
                yy += strideY
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// 从 CVPixelBuffer 算。
    public static func measure(pixelBuffer pb: CVPixelBuffer, stride step: Int = 4) -> ScanProfile? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let planes = PatternProbe.planes(of: pb) else { return nil }
        return measure(planes, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), stride: step)
    }
}
