// 多画面纹理里每个格子的位置：输入缩略图（W2-B）就是 MetalDisplayView 以 target = .multiview、sourceRect = 某个格子来画的。
// 这里的几何必须与 CompositorPasses.encodeMultiview 逐字一致（那边是渲染线程的像素坐标，这边换算成归一化矩形）；
// App 的测试用 OfflineRenderer 画一张多画面对着采样，改了那边的布局这边会红。
import SwitcherContracts

/// 多画面布局（与 CompositorPasses.encodeMultiview 相同的规则）。
public enum MultiviewLayout {
    /// 输入格子的列 / 行数：≤ 8 路 4×2，≤ 18 路 6×3，否则 8×4（每格接近 16:9，没用到的格子留黑）。
    public static func grid(inputCount count: Int) -> (columns: Int, rows: Int) {
        count <= 8 ? (4, 2) : (count <= 18 ? (6, 3) : (8, 4))
    }

    /// 第 index 路（按 MixerState.inputs 的顺序，从 0 起）的格子内框（去掉 tally 边框之后画输入的那块），归一化到纹理尺寸。
    /// 超出格子数（index ≥ 列 × 行）返回 nil。
    public static func inputCell(index: Int, inputCount count: Int, width: Int, height: Int) -> NormalizedRect? {
        let w = Double(width), h = Double(height)
        let margin = (h / 135).rounded()          // 1080 → 8
        let border = max(2, (h / 270).rounded())  // 1080 → 4
        let (columns, rows) = grid(inputCount: count)
        guard index >= 0, index < columns * rows else { return nil }
        let areaY = h / 2 + margin / 2
        let areaH = h / 2 - 1.5 * margin
        let cellW = (w - Double(columns + 1) * margin) / Double(columns)
        let cellH = (areaH - Double(rows - 1) * margin) / Double(rows)
        let col = index % columns, row = index / columns
        let x = margin + Double(col) * (cellW + margin) + border
        let y = areaY + Double(row) * (cellH + margin) + border
        return NormalizedRect(x: x / w, y: y / h, width: max(0, cellW - 2 * border) / w, height: max(0, cellH - 2 * border) / h)
    }

    /// 上半的 PVW（左）/ PGM（右）格子内框。
    public static func monitorCell(program: Bool, width: Int, height: Int) -> NormalizedRect {
        let w = Double(width), h = Double(height)
        let margin = (h / 135).rounded()
        let border = max(2, (h / 270).rounded())
        let topH = h / 2 - 1.5 * margin
        let topW = (w - 3 * margin) / 2
        let x = (program ? 2 * margin + topW : margin) + border
        let y = margin + border
        return NormalizedRect(x: x / w, y: y / h, width: (topW - 2 * border) / w, height: (topH - 2 * border) / h)
    }
}
