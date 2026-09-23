// 多画面布局（设计方案 §5 步骤 6；W3-B 交付 4）。
//
// 布局从哪来：状态里第一个 kind = multiview 的输出的 `settings.multiview`（提案 010 的正式字段 `MultiviewLayoutSettings`：
// preset / custom / safeArea / meters）；nil、预设名认不出、custom 里没有一个合法格子 → 默认布局
// （pgmPvw+grid：上 PVW / PGM、下按路数 4×2 / 6×3 / 8×4，= W1-C 的几何）。
// 过渡键 `settings.extra["layout"]` 的后备读取 P3 保留了一个版本，W3-B2 删掉（P3 报告 §4 第 1 条）：旧节目文件由 `Show.load`
// 一次性搬进正式字段；没经过 load 的内存状态里的过渡键不再起作用（渲染成默认布局）。
// 解析结果放进预分配的定长表：渲染线程只在快照 sequence 变了时解析一次，解析本身零分配（下标循环、枚举载荷只 retain）。
// App 的几何 API（MultiviewLayout.placements）走同一份 `Geometry`，用 Double 算；渲染表用 Float，与 W1-C 的像素算式逐字相同。
import simd
import SwitcherContracts

/// 一个格子的解析结果（像素坐标）。
struct MultiviewCellSpec {
    enum Kind: Int32 { case program = 0, preview = 1, input = 2 }
    var kind: Kind = .program
    /// kind = input 时的输入编号。
    var input: Int32 = 0
    /// 外框（含 tally 边框），像素。
    var rect = PixelRect(x: 0, y: 0, width: 0, height: 0)
}

/// 布局几何（对 Float / Double 各实例化一次）。
enum MultiviewGeometry {
    /// 默认几何的常量：外边距（1080 → 8）、tally 边框（1080 → 4）。
    static func margin<F: BinaryFloatingPoint>(height h: F) -> F { (h / 135).rounded() }
    static func border<F: BinaryFloatingPoint>(height h: F) -> F { max(2, (h / 270).rounded()) }

    /// 上半 PVW（左）/ PGM（右）两格：返回 (x, y, w, h)。
    static func monitor<F: BinaryFloatingPoint>(program: Bool, width w: F, height h: F) -> (F, F, F, F) {
        let m = margin(height: h)
        let topH = h / 2 - F(1.5) * m
        let topW = (w - 3 * m) / 2
        return (program ? 2 * m + topW : m, m, topW, topH)
    }

    /// 下半网格第 index 格（columns × rows）：返回 (x, y, w, h)。
    static func gridCell<F: BinaryFloatingPoint>(index: Int, columns: Int, rows: Int, width w: F, height h: F) -> (F, F, F, F) {
        let m = margin(height: h)
        let areaY = h / 2 + m / 2
        let areaH = h / 2 - F(1.5) * m
        let cellW = (w - F(columns + 1) * m) / F(columns)
        let cellH = (areaH - F(rows - 1) * m) / F(rows)
        let col = index % columns, row = index / columns
        return (m + F(col) * (cellW + m), areaY + F(row) * (cellH + m), cellW, cellH)
    }

    /// 整幅 n×n 网格第 index 格。
    static func fullGridCell<F: BinaryFloatingPoint>(index: Int, n: Int, width w: F, height h: F) -> (F, F, F, F) {
        let m = margin(height: h)
        let cellW = (w - F(n + 1) * m) / F(n)
        let cellH = (h - F(n + 1) * m) / F(n)
        let col = index % n, row = index / n
        return (m + F(col) * (cellW + m), m + F(row) * (cellH + m), cellW, cellH)
    }

    /// 默认布局下半的列 / 行数：≤ 8 路 4×2，≤ 18 路 6×3，否则 8×4。
    static func autoGrid(inputCount count: Int) -> (columns: Int, rows: Int) {
        count <= 8 ? (4, 2) : (count <= 18 ? (6, 3) : (8, 4))
    }
}

/// 预设名。
enum MultiviewPreset: Equatable {
    case pgmPvwGrid
    case pgmPvw4x2
    case pgmPvw2x2
    case grid3x3
    case grid4x4

    static let names: [(String, MultiviewPreset)] = [
        ("pgmPvw+grid", .pgmPvwGrid), ("pgmPvw+4x2", .pgmPvw4x2), ("pgmPvw+2x2", .pgmPvw2x2), ("3x3", .grid3x3), ("4x4", .grid4x4),
    ]

    /// 按名字找；认不出给 nil。下标循环（渲染线程调用）。
    static func named(_ s: String) -> MultiviewPreset? {
        var i = 0
        while i < names.count {
            if names[i].0 == s { return names[i].1 }
            i += 1
        }
        return nil
    }
}

/// 渲染线程用的定长表。
final class MultiviewLayoutTable {
    static let capacity = 64
    private(set) var cells: [MultiviewCellSpec]
    private(set) var cellCount = 0
    /// PGM / PVW 格画安全框。
    private(set) var safeArea = false
    /// 输入格画电平表占位。
    private(set) var meters = false
    /// tally 边框宽（像素）。
    private(set) var border: Float = 4

    init() {
        cells = Array(repeating: MultiviewCellSpec(), count: MultiviewLayoutTable.capacity)
    }

    /// 状态里第一个 kind = multiview 的输出的正式布局字段；没有为 nil。下标循环（渲染线程也调它）。
    static func settings(in state: MixerState) -> MultiviewLayoutSettings? {
        let outputs = state.outputs
        var i = 0
        while i < outputs.count {
            if outputs[i].kind == .multiview { return outputs[i].settings.multiview }
            i += 1
        }
        return nil
    }

    /// 从状态解析（渲染线程；零分配）。只读正式字段 `settings.multiview`，过渡键 `extra["layout"]` 忽略。
    func parse(state: MixerState, width: Int, height: Int) {
        let inputs = state.inputs
        parse(settings: MultiviewLayoutTable.settings(in: state), inputCount: inputs.count, width: width, height: height) { inputs[$0].number }
    }

    /// 核心：正式字段 + 输入编号 → 表（提案 010）。下标循环、只 retain，渲染线程可调。
    func parse(settings: MultiviewLayoutSettings?, inputCount: Int, width: Int, height: Int, inputNumber: (Int) -> Int) {
        let w = Float(width), h = Float(height)
        reset(width: w, height: h)
        var preset = MultiviewPreset.pgmPvwGrid
        guard let settings else { return applyPreset(preset, inputCount: inputCount, width: w, height: h, inputNumber: inputNumber) }
        safeArea = settings.safeArea
        meters = settings.meters
        if !settings.custom.isEmpty {
            parseCustom(settings.custom, width: w, height: h)
            if cellCount > 0 { return }
        }
        preset = MultiviewPreset.named(settings.preset) ?? .pgmPvwGrid
        applyPreset(preset, inputCount: inputCount, width: w, height: h, inputNumber: inputNumber)
    }

    private func reset(width w: Float, height h: Float) {
        border = MultiviewGeometry.border(height: h)
        cellCount = 0
        safeArea = false
        meters = false
    }

    /// 预设布局 → 表。
    private func applyPreset(_ preset: MultiviewPreset, inputCount: Int, width w: Float, height h: Float, inputNumber: (Int) -> Int) {
        switch preset {
        case .pgmPvwGrid, .pgmPvw4x2, .pgmPvw2x2:
            let pvw = MultiviewGeometry.monitor(program: false, width: w, height: h)
            let pgm = MultiviewGeometry.monitor(program: true, width: w, height: h)
            append(.preview, 0, pvw)
            append(.program, 0, pgm)
            guard inputCount > 0 else { return }
            let (columns, rows): (Int, Int)
            switch preset {
            case .pgmPvw4x2: (columns, rows) = (4, 2)
            case .pgmPvw2x2: (columns, rows) = (2, 2)
            default: (columns, rows) = MultiviewGeometry.autoGrid(inputCount: inputCount)
            }
            var i = 0
            while i < inputCount && i < columns * rows {
                append(.input, inputNumber(i), MultiviewGeometry.gridCell(index: i, columns: columns, rows: rows, width: w, height: h))
                i += 1
            }
        case .grid3x3, .grid4x4:
            let n = preset == .grid3x3 ? 3 : 4
            append(.program, 0, MultiviewGeometry.fullGridCell(index: 0, n: n, width: w, height: h))
            append(.preview, 0, MultiviewGeometry.fullGridCell(index: 1, n: n, width: w, height: h))
            var i = 0
            while i < inputCount && i + 2 < n * n {
                append(.input, inputNumber(i), MultiviewGeometry.fullGridCell(index: i + 2, n: n, width: w, height: h))
                i += 1
            }
        }
    }

    private func append(_ kind: MultiviewCellSpec.Kind, _ input: Int, _ r: (Float, Float, Float, Float)) {
        guard cellCount < MultiviewLayoutTable.capacity else { return }
        cells[cellCount] = MultiviewCellSpec(kind: kind, input: Int32(input), rect: PixelRect(x: r.0, y: r.1, width: r.2, height: r.3))
        cellCount += 1
    }

    /// 自定义格子（正式字段）：`OutputSource.multiview` 的格子忽略（格子不能套自己）；rect 钳到画面内，空格子忽略。
    private func parseCustom(_ cells: [MultiviewCell], width w: Float, height h: Float) {
        var i = 0
        while i < cells.count && cellCount < MultiviewLayoutTable.capacity {
            let c = cells[i]
            i += 1
            var kind = MultiviewCellSpec.Kind.program
            var input = 0
            switch c.source {
            case .program: kind = .program
            case .preview: kind = .preview
            case .input(let n):
                guard n >= 1 else { continue }
                kind = .input
                input = n
            case .multiview:
                continue
            }
            let x = min(max(c.rect.x, 0), 1)
            let y = min(max(c.rect.y, 0), 1)
            let width = min(max(c.rect.width, 0), 1 - x)
            let height = min(max(c.rect.height, 0), 1 - y)
            guard width > 0, height > 0 else { continue }
            // 先转 Float 再乘：W3-B 过渡键那条路径的算式，参考图 v8-multiview-custom 的像素坐标靠它逐位不变（P3 报告 §5 第 4 条）
            append(kind, input, (Float(x) * w, Float(y) * h, Float(width) * w, Float(height) * h))
        }
    }
}

extension MultiviewLayout {
    /// 状态里第一个 kind = multiview 的输出的正式布局字段（提案 010）；没有为 nil。
    public static func layoutSettings(in state: MixerState) -> MultiviewLayoutSettings? {
        MultiviewLayoutTable.settings(in: state)
    }

    /// 正式字段版的全部格子（提案 010）。settings nil = 默认布局。
    public static func placements(settings: MultiviewLayoutSettings?, inputs: [Int], width: Int, height: Int) -> [MultiviewCellPlacement] {
        let table = MultiviewLayoutTable()
        table.parse(settings: settings, inputCount: inputs.count, width: width, height: height) { inputs[$0] }
        return placements(table: table, width: width, height: height)
    }
}
