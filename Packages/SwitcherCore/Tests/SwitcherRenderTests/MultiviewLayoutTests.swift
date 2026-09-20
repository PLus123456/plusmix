// 多画面布局（设计方案 §5 步骤 6；W3-B 交付 4）：预设 / 自定义 JSON、tally 边框、名字、电平表占位、安全框，以及给 App 用的几何 API。
import CoreGraphics
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class MultiviewLayoutTests: XCTestCase {
    static let size = CGSize(width: 1920, height: 1080)
    nonisolated(unsafe) static let renderer: OfflineRenderer = {
        do { return try OfflineRenderer() } catch { fatalError("建不出离线渲染器：\(error)") }
    }()
    static let inputs = TestImages.phase2ReferenceInputs()
    static let inputBitmaps: [Int: Bitmap] = inputs.mapValues { Bitmap($0) }

    func render(_ state: MixerState) throws -> OfflineRenderResult {
        try Self.renderer.render(state: state, inputs: Self.inputs, size: Self.size)
    }

    static func close(_ a: (r: Int, g: Int, b: Int, a: Int), _ b: (r: Int, g: Int, b: Int, a: Int), tolerance: Int) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    /// 格子里的内容按 16:9 fit 进内框：算出内容矩形，取它 (0.8, 0.8) 处的像素，应等于源图 (0.8, 0.8) 处的像素
    /// （不取中心：棋盘 / 纯色块 / 画中画的边都过中心）；外框左边中点是 tally 色。
    static func contentRect(_ inner: NormalizedRect, width: Int, height: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let iw = inner.width * Double(width), ih = inner.height * Double(height)
        let cw = min(iw, ih * 16 / 9), ch = min(ih, iw * 9 / 16)
        return (inner.x * Double(width) + (iw - cw) / 2, inner.y * Double(height) + (ih - ch) / 2, cw, ch)
    }

    func checkCells(_ state: MixerState, layout: JSONValue?, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try render(state)
        let mv = Bitmap(r.multiview)
        let pgm = Bitmap(r.program), pvw = Bitmap(r.preview)
        let placements = MultiviewLayout.placements(layout: layout, inputs: state.inputs.map(\.number), width: 1920, height: 1080)
        XCTAssertFalse(placements.isEmpty, file: file, line: line)
        let sx = Int(0.8 * 1920), sy = Int(0.8 * 1080)
        for (i, cell) in placements.enumerated() {
            let c = Self.contentRect(cell.inner, width: 1920, height: 1080)
            let cx = Int(c.x + c.w * 0.8), cy = Int(c.y + c.h * 0.8)
            let got = mv.pixel(cx, cy)
            let want: (r: Int, g: Int, b: Int, a: Int)
            let expectedBorder: (r: Int, g: Int, b: Int, a: Int)
            switch cell.source {
            case .program:
                want = pgm.pixel(sx, sy)
                expectedBorder = (230, 26, 26, 255)
            case .preview:
                want = pvw.pixel(sx, sy)
                expectedBorder = (26, 204, 26, 255)
            case .input(let n):
                want = Self.inputBitmaps[n]?.pixel(sx, sy) ?? (0, 0, 0, 255)
                let t = state.tally(ofInput: n)
                expectedBorder = t.program ? (230, 26, 26, 255) : (t.preview ? (26, 204, 26, 255) : (71, 71, 71, 255))
            case .multiview:
                continue
            }
            // 绿幕图带 ±6 噪声，缩略图是 4×4 盒式平均，放宽一点
            let tolerance = cell.source == .input(number: 5) ? 14 : 8
            XCTAssertTrue(Self.close(got, want, tolerance: tolerance), "格子 \(i)（\(cell.source)）内容 (\(cx),\(cy)) 采到 \(got)，期望 \(want)", file: file, line: line)
            let bx = Int(cell.outer.x * 1920) + 1, by = Int((cell.outer.y + cell.outer.height / 2) * 1080)
            let border = mv.pixel(bx, by)
            XCTAssertTrue(Self.close(border, expectedBorder, tolerance: 8), "格子 \(i)（\(cell.source)）左边框 (\(bx),\(by)) 采到 \(border)，期望 \(expectedBorder)", file: file, line: line)
        }
    }

    /// 没有布局 / 认不出的布局 → 默认布局（= W1-C 的几何，MultiviewLayout.inputCell / monitorCell 仍然有效）。
    func testMultiview_defaultLayoutUnchangedAndUsedAsFallback() throws {
        let s = ReferenceStates.fixed8()
        try checkCells(s, layout: nil)
        let bogus = ReferenceStates.withMultiviewLayout(s, "nonsense")
        try checkCells(bogus, layout: "nonsense")
        XCTAssertEqual(try render(s).multiview.width, 1920)
        XCTAssertEqual(Bitmap(try render(bogus).multiview).bgra, Bitmap(try render(s).multiview).bgra, "认不出的布局应退回默认，与没布局逐像素一致")
        // 默认布局的几何 API 与 placements 一致
        let p = MultiviewLayout.placements(layout: nil, inputs: s.inputs.map(\.number), width: 1920, height: 1080)
        XCTAssertEqual(p[0].source, .preview)
        XCTAssertEqual(p[1].source, .program)
        XCTAssertEqual(p[0].inner, MultiviewLayout.monitorCell(program: false, width: 1920, height: 1080))
        XCTAssertEqual(p[1].inner, MultiviewLayout.monitorCell(program: true, width: 1920, height: 1080))
        for i in 0..<8 {
            XCTAssertEqual(p[2 + i].source, .input(number: i + 1))
            XCTAssertEqual(p[2 + i].inner, MultiviewLayout.inputCell(index: i, inputCount: 8, width: 1920, height: 1080))
        }
        // 多画面输出的 extra["layout"] 从状态里找
        XCTAssertNil(MultiviewLayout.layoutValue(in: s))
        XCTAssertEqual(MultiviewLayout.layoutValue(in: bogus), "nonsense")
    }

    /// 预设 pgmPvw+2x2：上半 PVW / PGM，下半 2×2 放前 4 路。
    func testV8_multiviewPreset_pgmPvw2x2() throws {
        let s = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), "pgmPvw+2x2")
        try checkCells(s, layout: "pgmPvw+2x2")
        let p = MultiviewLayout.placements(layout: "pgmPvw+2x2", inputs: s.inputs.map(\.number), width: 1920, height: 1080)
        XCTAssertEqual(p.count, 6)
        XCTAssertEqual(p.suffix(4).map(\.source), [.input(number: 1), .input(number: 2), .input(number: 3), .input(number: 4)])
        XCTAssertGreaterThan(p[2].inner.width, 0.4, "2×2 的格子应接近半宽")
        XCTAssertEqual(p[2].outer.y, p[3].outer.y, accuracy: 1e-9)
        XCTAssertGreaterThan(p[4].outer.y, p[2].outer.y)
    }

    /// 预设 3x3：九宫格，PGM、PVW、输入 1–7。
    func testV8_multiviewPreset_3x3() throws {
        let s = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), "3x3")
        try checkCells(s, layout: "3x3")
        let p = MultiviewLayout.placements(layout: "3x3", inputs: s.inputs.map(\.number), width: 1920, height: 1080)
        XCTAssertEqual(p.count, 9)
        XCTAssertEqual(p[0].source, .program)
        XCTAssertEqual(p[1].source, .preview)
        XCTAssertEqual(p[8].source, .input(number: 7))
        // 九个格子等大
        for c in p { XCTAssertEqual(c.outer.width, p[0].outer.width, accuracy: 1e-9); XCTAssertEqual(c.outer.height, p[0].outer.height, accuracy: 1e-9) }
        // 输入少于 7 路时后面的格子留黑：只给 3 路
        var few = s
        few.inputs = Array(few.inputs.prefix(3))
        let pf = MultiviewLayout.placements(layout: "3x3", inputs: few.inputs.map(\.number), width: 1920, height: 1080)
        XCTAssertEqual(pf.count, 5)
        let mv = Bitmap(try render(few).multiview)
        let emptyCell = p[8]
        let e = mv.pixel(Int((emptyCell.inner.x + emptyCell.inner.width / 2) * 1920), Int((emptyCell.inner.y + emptyCell.inner.height / 2) * 1080))
        XCTAssertEqual(e.r + e.g + e.b, 0, "没用到的格子留黑")
        // 4x4 也认
        XCTAssertEqual(MultiviewLayout.placements(layout: "4x4", inputs: s.inputs.map(\.number), width: 1920, height: 1080).count, 10)
        XCTAssertEqual(Set(MultiviewLayout.presetNames), ["pgmPvw+grid", "pgmPvw+4x2", "pgmPvw+2x2", "3x3", "4x4"])
    }

    /// 自定义 JSON：格子按给的 rect 放，source 可以是 "program" / "preview" / 输入号；不存在的输入画黑格 + 灰边。
    func testV8_multiviewCustomJSONLayout() throws {
        let s = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout)
        try checkCells(s, layout: ReferenceStates.customLayout)
        let p = MultiviewLayout.placements(layout: ReferenceStates.customLayout, inputs: s.inputs.map(\.number), width: 1920, height: 1080)
        XCTAssertEqual(p.count, 7)
        XCTAssertEqual(p[0].source, .program)
        XCTAssertEqual(p[0].outer, NormalizedRect(x: 0, y: 0, width: 0.7, height: 0.7))
        XCTAssertEqual(p[6].source, .input(number: 5))
        // 引用不存在的输入
        let missing: JSONValue = ["cells": [["source": 42, "rect": ["x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5]]]]
        let m = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), missing)
        let mv = Bitmap(try render(m).multiview)
        let c = mv.pixel(Int(0.35 * 1920), Int(0.35 * 1080))
        XCTAssertEqual(c.r + c.g + c.b, 0)
        let b = mv.pixel(Int(0.1 * 1920) + 1, Int(0.35 * 1080))
        XCTAssertTrue(Self.close(b, (71, 71, 71, 255), tolerance: 8), "不存在的输入 tally off，得 \(b)")
        // 越界的 rect 被钳到画面内、缺 rect 的格子忽略、超过 64 格截断
        var many: [JSONValue] = []
        for i in 0..<80 { many.append(["source": .number(Double(i % 8 + 1)), "rect": ["x": .number(Double(i % 10) * 0.1), "y": .number(Double(i / 10) * 0.1), "width": 0.1, "height": 0.1]]) }
        XCTAssertEqual(MultiviewLayout.placements(layout: ["cells": .array(many)], inputs: [1, 2, 3, 4, 5, 6, 7, 8], width: 1920, height: 1080).count, 64)
        // 全部格子都缺 rect → 没有一个合法格子 → 退回默认布局（PVW、PGM、输入 1）
        XCTAssertEqual(MultiviewLayout.placements(layout: ["cells": [["source": 1]]], inputs: [1], width: 1920, height: 1080).map(\.source), [.preview, .program, .input(number: 1)])
        // 空 cells → 默认布局
        XCTAssertEqual(MultiviewLayout.placements(layout: ["cells": []], inputs: [1, 2], width: 1920, height: 1080).map(\.source),
                       MultiviewLayout.placements(layout: nil, inputs: [1, 2], width: 1920, height: 1080).map(\.source))
    }

    /// 安全框（PGM / PVW 格，EBU R95：3.5% 动作安全、5% 字幕安全）与电平表占位（输入格右侧的暗条）。
    func testMultiview_safeAreaAndMeterPlaceholders() throws {
        let layout: JSONValue = ["cells": [
            ["source": "program", "rect": ["x": 0.0, "y": 0.0, "width": 0.6, "height": 0.6]],
            ["source": 8, "rect": ["x": 0.6, "y": 0.0, "width": 0.4, "height": 0.4]],
        ], "safeArea": true, "meters": true]
        let s = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), layout)
        let mv = Bitmap(try render(s).multiview)
        let p = MultiviewLayout.placements(layout: layout, inputs: s.inputs.map(\.number), width: 1920, height: 1080)
        let pgm = p[0].inner
        // 动作安全线在内框 3.5% 处：竖线上的像素应明显亮于它右边 8 px 的 PGM 内容（输入 1 渐变在左侧很暗）
        let lineX = Int((pgm.x + pgm.width * 0.035) * 1920), midY = Int((pgm.y + pgm.height * 0.5) * 1080)
        let onLine = mv.pixel(lineX, midY), beside = mv.pixel(lineX + 8, midY)
        XCTAssertGreaterThan(onLine.r + onLine.g + onLine.b, beside.r + beside.g + beside.b + 150, "3.5% 处应有安全框线，得 \(onLine) vs \(beside)")
        let titleX = Int((pgm.x + pgm.width * 0.05) * 1920)
        let onTitle = mv.pixel(titleX, midY), besideTitle = mv.pixel(titleX + 8, midY)
        XCTAssertGreaterThan(onTitle.r + onTitle.g + onTitle.b, besideTitle.r + besideTitle.g + besideTitle.b + 150, "5% 处应有字幕安全线")
        // 没开 safeArea 的同一布局：那里没有线
        var plainLayout = layout
        if case .object(var o) = plainLayout { o["safeArea"] = false; o["meters"] = false; plainLayout = .object(o) }
        let plain = Bitmap(try render(ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), plainLayout)).multiview)
        let off = plain.pixel(lineX, midY), offBeside = plain.pixel(lineX + 8, midY)
        XCTAssertLessThan(abs(off.r + off.g + off.b - offBeside.r - offBeside.g - offBeside.b), 40)
        // 电平表占位：输入 8（黄）格子右侧的暗条
        let cell = p[1].inner
        let stripX = Int((cell.x + cell.width) * 1920) - 6, stripY = Int((cell.y + cell.height * 0.5) * 1080)
        let strip = mv.pixel(stripX, stripY), content = mv.pixel(stripX - 60, stripY)
        XCTAssertLessThan(strip.r + strip.g + strip.b, 200, "电平表占位应是暗条，得 \(strip)")
        XCTAssertGreaterThan(content.r + content.g, 380, "条左边仍是黄内容，得 \(content)")
        let offStrip = plain.pixel(stripX, stripY)
        XCTAssertGreaterThan(offStrip.r + offStrip.g, 380, "meters 关时没有暗条，得 \(offStrip)")
    }

    /// tally 边框跟状态走：切 PGM / PVW、开叠加，格子边框颜色随之变。
    func testMultiview_tallyBordersFollowState() throws {
        var s = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), "3x3")
        s.overlays = Array(repeating: OverlayState(), count: 4)
        s.program = 3
        s.preview = 5
        try checkCells(s, layout: "3x3")
        s.overlays[3] = OverlayState(input: 7, on: true, rect: .bottomRightQuarter, animProgress: 1)
        XCTAssertTrue(s.tally(ofInput: 7).program)
        try checkCells(s, layout: "3x3")
        // 转场中 PVW 也算在 PGM
        s.transition = TransitionState(type: .fade, durationTicks: 30, progress: 0.5, source: .auto, startTick: Tick(0))
        XCTAssertTrue(s.tally(ofInput: 5).program)
        try checkCells(s, layout: "3x3")
    }

    /// 名字：每路输入的标签 + PGM / PVW 格的标签（LabelSet 末尾两个切片）。
    func testMultiview_labelsIncludeProgramAndPreview() throws {
        let s = ReferenceStates.fixed8()
        let texts = LabelPainter.wantedTexts(for: s, slices: 9 + LabelSet.extraSlices)
        XCTAssertEqual(texts.count, 11)
        XCTAssertEqual(texts[1], "1  摄像机 1")
        XCTAssertEqual(texts[8], "8  Cam 8")
        XCTAssertEqual(texts[LabelSet.programSlice(totalSlices: 11)], "PGM")
        XCTAssertEqual(texts[LabelSet.previewSlice(totalSlices: 11)], "PVW")
        // 渲染：默认布局 PGM 格左下角有标签条（55% 黑底 + 白字）。取条内、文字左边留白处的一个像素：应比同一位置没有标签条时暗。
        let r = try render(s)
        let mv = Bitmap(r.multiview)
        let pgmCell = MultiviewLayout.monitorCell(program: true, width: 1920, height: 1080)
        let lh = (pgmCell.height * 1080 * 0.14).rounded()
        let lx = Int(pgmCell.x * 1920) + 2, ly = Int((pgmCell.y + pgmCell.height) * 1080 - lh / 2)
        let onLabel = mv.pixel(lx, ly)
        // 同一位置的 PGM 内容：格子把 1920×1080 缩进内框，内框左边 2 px、条中线处对应 PGM 的 (2 / 内框宽 × 1920, ...)
        let px = Int(2 / (pgmCell.width * 1920) * 1920), py = Int((pgmCell.height * 1080 - lh / 2) / (pgmCell.height * 1080) * 1080)
        let content = Bitmap(r.program).pixel(px, py)
        let expected = Double(content.r + content.g + content.b) * 0.45
        XCTAssertLessThanOrEqual(Double(onLabel.r + onLabel.g + onLabel.b), expected + 40, "PGM 格左下角应有 55% 黑的标签条，得 \(onLabel)，内容 \(content)")
    }

    /// 多画面几何 API 用同一份解析逻辑（MultiviewLayoutTable），渲染线程的解析零分配：解析 20 次不分配。
    func testMultiview_layoutTableParseDoesNotAllocate() throws {
        try XCTSkipUnless(MallocProbe.isAvailable, "找不到 malloc_logger 符号")
        let table = MultiviewLayoutTable()
        let states = [ReferenceStates.fixed8(),
                      ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), "3x3"),
                      ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout),
                      ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), "pgmPvw+2x2")]
        for s in states { table.parse(state: s, width: 1920, height: 1080) }   // 预热
        MallocProbe.start()
        for _ in 0..<5 { for s in states { table.parse(state: s, width: 1920, height: 1080) } }
        let count = MallocProbe.stop()
        let own = MallocProbe.attributions().filter(\.isOwn)
        print("多画面布局解析：20 次共 \(count) 次分配，其中 SwitcherRender 代码 \(own.count) 次")
        for a in own.prefix(3) { print("   \(a.stack.prefix(10).joined(separator: " <- "))") }
        XCTAssertEqual(own.count, 0, "布局解析在渲染线程上跑，不许分配")
        XCTAssertEqual(table.cellCount, 6)
    }
}
