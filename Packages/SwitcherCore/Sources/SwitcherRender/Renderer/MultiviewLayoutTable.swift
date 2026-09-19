// 多画面布局（设计方案 §5 步骤 6；W3-B 交付 4）。
//
// 布局从哪来（提案 009 的过渡做法）：状态里第一个 kind = multiview 的输出的 `settings.extra["layout"]`：
//   - 字符串 = 预设名：pgmPvw+grid（默认：上 PVW / PGM、下按路数 4×2 / 6×3 / 8×4，= W1-C 的几何）、pgmPvw+4x2、pgmPvw+2x2、3x3、4x4
//   - 对象 {"preset": "3x3", "safeArea": true, "meters": true} = 预设 + 装饰开关
//   - 对象 {"cells": [{"source": "program" | "preview" | 3, "rect": {x, y, width, height}}], "safeArea": …, "meters": …} = 自定义
//   - 没有 / 认不出 / cells 为空 → 默认布局
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

    /// 从状态解析（渲染线程；零分配）。
    func parse(state: MixerState, width: Int, height: Int) {
        let inputs = state.inputs
        parse(layout: MultiviewLayout.layoutValue(in: state), inputCount: inputs.count, width: width, height: height) { inputs[$0].number }
    }

    /// 核心：layout 值 + 输入编号 → 表。
    func parse(layout: JSONValue?, inputCount: Int, width: Int, height: Int, inputNumber: (Int) -> Int) {
        let w = Float(width), h = Float(height)
        border = MultiviewGeometry.border(height: h)
        cellCount = 0
        safeArea = false
        meters = false
        var preset = MultiviewPreset.pgmPvwGrid
        var custom = false
        if let layout {
            switch layout {
            case .string(let name):
                preset = MultiviewPreset.named(name) ?? .pgmPvwGrid
            case .object(let o):
                if case .bool(let b)? = o["safeArea"] { safeArea = b }
                if case .bool(let b)? = o["meters"] { meters = b }
                if case .array(let arr)? = o["cells"], !arr.isEmpty {
                    custom = true
                    parseCustom(arr, width: w, height: h)
                    if cellCount == 0 { custom = false }
                } else if case .string(let name)? = o["preset"] {
                    preset = MultiviewPreset.named(name) ?? .pgmPvwGrid
                }
            default:
                break
            }
        }
        if custom { return }
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

    /// 自定义格子：source 是 "program" / "preview" / 数字；rect 归一化，钳到画面内；缺 rect 或 source 的格子忽略。
    private func parseCustom(_ arr: [JSONValue], width w: Float, height h: Float) {
        var i = 0
        while i < arr.count && cellCount < MultiviewLayoutTable.capacity {
            defer { i += 1 }
            guard case .object(let c) = arr[i], case .object(let r)? = c["rect"] else { continue }
            var kind = MultiviewCellSpec.Kind.input
            var input = 0
            switch c["source"] {
            case .string(let s)?:
                if s == "program" { kind = .program } else if s == "preview" { kind = .preview } else { continue }
            case .number(let n)?:
                guard n >= 1, n < 1_000_000 else { continue }
                input = Int(n)
            default:
                continue
            }
            var x = 0.0, y = 0.0, width = 0.0, height = 0.0
            if case .number(let v)? = r["x"] { x = v }
            if case .number(let v)? = r["y"] { y = v }
            if case .number(let v)? = r["width"] { width = v }
            if case .number(let v)? = r["height"] { height = v }
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
            width = min(max(width, 0), 1 - x)
            height = min(max(height, 0), 1 - y)
            guard width > 0, height > 0 else { continue }
            append(kind, input, (Float(x) * w, Float(y) * h, Float(width) * w, Float(height) * h))
        }
    }
}
