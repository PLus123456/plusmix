// 多画面纹理里每个格子的位置：输入缩略图（W2-B）就是 MetalDisplayView 以 target = .multiview、sourceRect = 某个格子来画的。
// 几何与 CompositorPasses.encodeMultiview 用的是同一份 MultiviewGeometry / MultiviewLayoutTable（那边 Float 像素坐标，这边 Double 归一化）；
// App 的测试用 OfflineRenderer 画一张多画面对着采样，改了那边的布局这边会红。
// W3-B：布局可配（预设 / 自定义格子，正式字段 `OutputSettings.multiview`，见 MultiviewLayoutTable.swift 头注释），
// `placements(settings:…)` 给任意布局的格子；`grid` / `inputCell` / `monitorCell` 仍是默认布局（pgmPvw+grid）的几何，W2-B 的缩略图接线继续用。
// W3-B2 删了过渡键 `extra["layout"]` 的读取（`layoutValue(in:)`、`placements(layout:…)` 两个 API 一起删，仓库里没有别的调用方）。
// 名字标签只在渲染器里画（CompositorPasses.drawCellLabel），这里的显示视图只贴多画面纹理的一块，不另画名字。
import SwitcherContracts

/// 多画面里一个格子：源、外框（含 tally 边框）、内框（画内容的那块），都归一化到纹理尺寸。
public struct MultiviewCellPlacement: Hashable, Sendable {
    /// program / preview / input(number:)。
    public let source: OutputSource
    /// 外框。
    public let outer: NormalizedRect
    /// 内框（外框收进 tally 边框）。
    public let inner: NormalizedRect
    public init(source: OutputSource, outer: NormalizedRect, inner: NormalizedRect) {
        self.source = source
        self.outer = outer
        self.inner = inner
    }
}

/// 多画面布局（与 CompositorPasses.encodeMultiview 相同的规则）。
public enum MultiviewLayout {
    /// 预设名：pgmPvw+grid（默认）、pgmPvw+4x2、pgmPvw+2x2、3x3、4x4。
    public static var presetNames: [String] { MultiviewPreset.names.map(\.0) }

    /// 解析好的表 → 格子（按绘制顺序）。正式字段版的入口 `placements(settings:inputs:width:height:)` 在 MultiviewLayoutTable.swift。
    static func placements(table: MultiviewLayoutTable, width: Int, height: Int) -> [MultiviewCellPlacement] {
        let w = Double(width), h = Double(height)
        let border = MultiviewGeometry.border(height: h)
        var result: [MultiviewCellPlacement] = []
        result.reserveCapacity(table.cellCount)
        // 默认 / 预设几何用 Double 重算一遍（与 inputCell / monitorCell 逐位相同）；自定义格子按归一化值反推
        for i in 0..<table.cellCount {
            let c = table.cells[i]
            let r = c.rect
            let outer = NormalizedRect(x: Double(r.x) / w, y: Double(r.y) / h, width: Double(r.width) / w, height: Double(r.height) / h)
            let inner = NormalizedRect(x: (Double(r.x) + border) / w, y: (Double(r.y) + border) / h,
                                       width: max(0, Double(r.width) - 2 * border) / w, height: max(0, Double(r.height) - 2 * border) / h)
            let source: OutputSource
            switch c.kind {
            case .program: source = .program
            case .preview: source = .preview
            case .input: source = .input(number: Int(c.input))
            }
            result.append(MultiviewCellPlacement(source: source, outer: outer, inner: inner))
        }
        return result
    }

    /// 默认布局输入格子的列 / 行数：≤ 8 路 4×2，≤ 18 路 6×3，否则 8×4（每格接近 16:9，没用到的格子留黑）。
    public static func grid(inputCount count: Int) -> (columns: Int, rows: Int) {
        MultiviewGeometry.autoGrid(inputCount: count)
    }

    /// 默认布局第 index 路（按 MixerState.inputs 的顺序，从 0 起）的格子内框（去掉 tally 边框之后画输入的那块），归一化到纹理尺寸。
    /// 超出格子数（index ≥ 列 × 行）返回 nil。
    public static func inputCell(index: Int, inputCount count: Int, width: Int, height: Int) -> NormalizedRect? {
        let w = Double(width), h = Double(height)
        let border = MultiviewGeometry.border(height: h)
        let (columns, rows) = grid(inputCount: count)
        guard index >= 0, index < columns * rows else { return nil }
        let (x, y, cellW, cellH) = MultiviewGeometry.gridCell(index: index, columns: columns, rows: rows, width: w, height: h)
        return NormalizedRect(x: (x + border) / w, y: (y + border) / h, width: max(0, cellW - 2 * border) / w, height: max(0, cellH - 2 * border) / h)
    }

    /// 默认布局上半的 PVW（左）/ PGM（右）格子内框。
    public static func monitorCell(program: Bool, width: Int, height: Int) -> NormalizedRect {
        let w = Double(width), h = Double(height)
        let border = MultiviewGeometry.border(height: h)
        let (x, y, topW, topH) = MultiviewGeometry.monitor(program: program, width: w, height: h)
        return NormalizedRect(x: (x + border) / w, y: (y + border) / h, width: (topW - 2 * border) / w, height: (topH - 2 * border) / h)
    }
}
