// MultiviewLayout（缩略图切多画面纹理的哪一块）必须与渲染器 CompositorPasses.encodeMultiview 逐字一致：
// 用 OfflineRenderer 画一张多画面（每路一个纯色输入），在算出来的格子中心采样应得到该路的颜色，格子外一圈应是 tally 边框色。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import Switcher

final class MultiviewLayoutTests: XCTestCase {
    func testMultiviewLayout_matchesRenderedCells() throws {
        let counts = [1, 2, 3, 8, 9, 18, 19, 24]
        let renderer = try OfflineRenderer()
        for count in counts {
            var inputs: [InputConfig] = []
            var images: [Int: CGImage] = [:]
            for n in 1...count {
                inputs.append(InputConfig(number: n, name: "in \(n)", source: .image(path: "/dev/null")))
                images[n] = try Self.solid(red: 0.2 + 0.6 * Double(n % 5) / 5, green: 0.9 - 0.7 * Double(n % 3) / 3, blue: 0.5)
            }
            let state = MixerState(format: .hd1080p60, inputs: inputs, program: 1, preview: min(2, count))
            let result = try renderer.render(state: state, inputs: images, size: CGSize(width: 1920, height: 1080))
            let mv = result.multiview
            let (columns, rows) = MultiviewLayout.grid(inputCount: count)
            for (index, input) in inputs.enumerated() where index < columns * rows {
                let cell = try XCTUnwrap(MultiviewLayout.inputCell(index: index, inputCount: count, width: mv.width, height: mv.height),
                                         "\(count) 路第 \(index) 格应有位置")
                let cx = Int((cell.x + cell.width / 2) * Double(mv.width)), cy = Int((cell.y + cell.height * 0.3) * Double(mv.height))
                let got = try Self.pixel(mv, x: cx, y: cy)
                let want = try Self.pixel(images[input.number]!, x: 8, y: 8)
                XCTAssertTrue(Self.close(got, want, tolerance: 6), "\(count) 路：格子 \(index) 中心 (\(cx),\(cy)) 采到 \(got)，期望输入 \(input.number) 的 \(want)")
                // 格子外 2 像素（tally 边框）：PGM 红 / PVW 绿 / 灰
                let tally = state.tally(ofInput: input.number)
                let expectedBorder: (Int, Int, Int) = tally.program ? (230, 26, 26) : (tally.preview ? (26, 204, 26) : (71, 71, 71))
                let bx = Int(cell.x * Double(mv.width)) - 2, by = Int((cell.y + cell.height / 2) * Double(mv.height))
                let border = try Self.pixel(mv, x: bx, y: by)
                XCTAssertTrue(Self.close(border, expectedBorder, tolerance: 8), "\(count) 路：格子 \(index) 左边框 (\(bx),\(by)) 采到 \(border)，期望 \(expectedBorder)")
            }
            XCTAssertNil(MultiviewLayout.inputCell(index: columns * rows, inputCount: count, width: 1920, height: 1080), "超出格子数返回 nil")
        }
        // 上半 PVW / PGM 格子：PGM 是输入 1 的颜色
        let pgm = MultiviewLayout.monitorCell(program: true, width: 1920, height: 1080)
        XCTAssertGreaterThan(pgm.x, 0.5, "PGM 在右半")
        let pvw = MultiviewLayout.monitorCell(program: false, width: 1920, height: 1080)
        XCTAssertLessThan(pvw.x + pvw.width, 0.5, "PVW 在左半")
    }

    static func solid(red: Double, green: Double, blue: Double) throws -> CGImage {
        let w = 64, h = 36
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(ctx.makeImage())
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = try XCTUnwrap(rep.colorAt(x: x, y: y))
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    static func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }
}

/// W3-E2 / 提案 010：输出设置 › 多画面页读写 `OutputSettings.multiview`（预设 + safeArea / meters；自定义格子只读展示）；
/// 缩略图按当前布局切多画面纹理（换预设后跟着换位置），布局里没有的输入显示占位文案。
@MainActor
final class MultiviewSettingsTests: XCTestCase {
    func testMultiviewSettings_presetFlagsCustomReadOnly_thumbnailsFollowLayout() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        let page = AppTest.controller.panels.showOutputSettings(tab: .multiview).model
        XCTAssertNil(page.multiviewOutput, "空节目没有多画面输出")
        XCTAssertEqual(page.multiviewLayout, MultiviewLayoutSettings(), "没有就显示默认布局")
        // 缩略图 = 格子内框切掉底部的名字条（W3-E3 交付第 5 条）；这里看的是"按哪个布局切"
        func thumb(_ settings: MultiviewLayoutSettings?, _ n: Int) -> NormalizedRect? {
            MultiviewLayout.placements(settings: settings, inputs: [1, 2], width: 1920, height: 1080).first { $0.source == .input(number: n) }
                .map { InputStripView.thumbnailRect(for: $0, width: 1920, height: 1080) }
        }
        XCTAssertEqual(MultiviewLayout.placements(settings: nil, inputs: [1, 2], width: 1920, height: 1080).first { $0.source == .input(number: 1) }?.inner,
                       MultiviewLayout.inputCell(index: 0, inputCount: 2, width: 1920, height: 1080))
        XCTAssertEqual(wc.inputStrip.cells[1]?.display.sourceRect, thumb(nil, 1))

        page.setMultiviewPreset("3x3")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.outputs.first { $0.kind == .multiview }?.settings.multiview?.preset == "3x3" }, "\(session.state.outputs)")
        let mv = try XCTUnwrap(session.state.outputs.first { $0.kind == .multiview })
        XCTAssertEqual(mv.settings.source, .multiview)
        XCTAssertFalse(mv.enabled, "只承载布局：enabled + source = multiview 会让渲染器每拍多转一次 NV12，App 里没有下游")
        page.setMultiviewSafeArea(true)
        page.setMultiviewMeters(true)
        let wanted = MultiviewLayoutSettings(preset: "3x3", safeArea: true, meters: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.output(mv.number)?.settings.multiview == wanted }, "\(String(describing: session.state.output(mv.number)?.settings.multiview))")
        XCTAssertTrue(session.state.output(mv.number)?.settings.extra.isEmpty ?? false, "只写正式字段，不写 extra[\"layout\"]")

        // 缩略图跟着布局
        let placements = MultiviewLayout.placements(settings: wanted, inputs: [1, 2], width: 1920, height: 1080)
        let rect1 = try XCTUnwrap(placements.first { $0.source == .input(number: 1) }?.inner)
        XCTAssertNotEqual(rect1, MultiviewLayout.inputCell(index: 0, inputCount: 2, width: 1920, height: 1080), "3×3 与默认布局的格子不同（否则测不出东西）")
        let thumb1 = try XCTUnwrap(thumb(wanted, 1))
        XCTAssertEqual(thumb1.x, rect1.x)
        XCTAssertEqual(thumb1.y, rect1.y)
        XCTAssertTrue(AppTest.waitUntil(2) { wc.inputStrip.cells[1]?.display.sourceRect == thumb1 }, "缩略图应按 3×3 切：\(String(describing: wc.inputStrip.cells[1]?.display.sourceRect))")

        // 自定义格子（节目文件 / API 给的）：页上只读列出，预设不起作用；布局里没有 2 号 → 2 号缩略图显示占位文案
        var settings = try XCTUnwrap(session.state.output(mv.number)?.settings)
        settings.multiview?.custom = [MultiviewCell(source: .program, rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                                      MultiviewCell(source: .input(number: 1), rect: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5))]
        session.send(.setOutputSettings(output: mv.number, settings: settings))
        XCTAssertTrue(AppTest.waitUntil(2) { page.multiviewLayout.custom.count == 2 })
        XCTAssertEqual(page.customCellRows.count, 2)
        XCTAssertTrue(page.customCellRows[0].source.contains("PGM"), page.customCellRows[0].source)
        XCTAssertTrue(AppTest.waitUntil(2) { wc.inputStrip.cells[2]?.isOutsideMultiviewLayout == true }, "2 号不在自定义布局里")
        XCTAssertEqual(wc.inputStrip.cells[2]?.displayedStatus, "不在多画面布局里")
        XCTAssertEqual(wc.inputStrip.cells[1]?.isOutsideMultiviewLayout, false)
        page.clearMultiviewCustomCells()
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.output(mv.number)?.settings.multiview?.custom.isEmpty == true && wc.inputStrip.cells[2]?.isOutsideMultiviewLayout == false })
        AppTest.controller.panels.closeAll()
    }

    /// API 直接 addOutput 一个带过渡键 extra["layout"] 的多画面输出（没经过 Show.load）：P4 起状态机先按 Show.load 同一套规则把它搬进正式字段
    /// （`OutputSettings.multiview` = 预设 "3x3"），渲染器与缩略图读的都是正式字段——两边一起按 3x3 切格子，旧键不再被静默丢成默认布局
    /// （W3-B2 报告 §4 第 4 条；G4 第二批合入时这条曾改成"过渡键被忽略"，P4 之后前提变了）。
    func testThumbnails_legacyLayoutKeyFromAPIMigratedLikeRenderer() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        // 默认布局 2 号格子（内框切掉名字条，W3-E3 交付第 5 条）
        let defaultPlacement = try XCTUnwrap(MultiviewLayout.placements(settings: nil, inputs: [1, 2], width: 1920, height: 1080).first { $0.source == .input(number: 2) })
        XCTAssertEqual(defaultPlacement.inner, MultiviewLayout.inputCell(index: 1, inputCount: 2, width: 1920, height: 1080))
        let defaultRect = InputStripView.thumbnailRect(for: defaultPlacement, width: 1920, height: 1080)
        XCTAssertTrue(AppTest.waitUntil(2) { wc.inputStrip.cells[2]?.display.sourceRect == defaultRect })
        let number = (session.state.outputs.map(\.number).max() ?? 0) + 1
        session.send(.addOutput(config: OutputState(number: number, kind: .multiview, name: "legacy", enabled: false,
                                                    settings: OutputSettings(source: .multiview, extra: ["layout": .string("3x3")]))))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.output(number) != nil })
        let settings = try XCTUnwrap(session.state.output(number)?.settings)
        XCTAssertEqual(settings.multiview, MultiviewLayoutSettings(preset: "3x3"), "过渡键搬进正式字段")
        XCTAssertNil(settings.extra["layout"], "旧键搬完清掉")
        let migratedPlacement = try XCTUnwrap(MultiviewLayout.placements(settings: settings.multiview, inputs: [1, 2], width: 1920, height: 1080)
            .first { $0.source == .input(number: 2) })
        let migratedRect = InputStripView.thumbnailRect(for: migratedPlacement, width: 1920, height: 1080)
        XCTAssertNotEqual(migratedRect, defaultRect)
        XCTAssertTrue(AppTest.waitUntil(2) { wc.inputStrip.cells[2]?.display.sourceRect == migratedRect }, "缩略图按搬进来的 3x3 切，与渲染器一致")
        session.send(.removeOutput(output: number))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.output(number) == nil && wc.inputStrip.cells[2]?.display.sourceRect == defaultRect })
    }
}
