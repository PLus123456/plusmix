// W3-E3 交付第 5 条：输入条上名字出现两次（标题条一次 + 缩略图里渲染器画的名字条一次）。二选一选的是"缩略图切掉内框底部的名字条"：
// 标题条保留编号 + 名字 + tally 色（主界面的主标签），缩略图只要画面。名字条的几何与渲染器 CompositorPasses.drawCellLabel 同一个算式
// （贴内框底边，高 = 格高 × 14%，≥ 12 px，≤ 画面高 × 3.5%），再多切 2 px 给缩略图下采样的采样脚印。
// 像素扫描：离线渲染一张多画面（每路一个纯色输入、名字条 = 55% 黑底白字），在 App 算出的缩略图区域里逐像素扫——全是该路的纯色、没有白字；
// 对照：名字条那几行扫得到白字（证明扫描找得到名字条）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import Switcher

@MainActor
final class ThumbnailCropTests: XCTestCase {
    struct Layout: CustomStringConvertible {
        let preset: String?
        let count: Int
        let width: Int
        let height: Int
        var description: String { "\(preset ?? "默认")·\(count) 路·\(width)×\(height)" }
    }

    func testThumbnails_cropCellNameStrip_pixelScanFindsNoLabel() throws {
        let renderer = try OfflineRenderer()
        let layouts = [Layout(preset: nil, count: 2, width: 1920, height: 1080), Layout(preset: nil, count: 8, width: 1920, height: 1080),
                       Layout(preset: nil, count: 19, width: 1920, height: 1080), Layout(preset: "3x3", count: 4, width: 1920, height: 1080),
                       Layout(preset: "pgmPvw+2x2", count: 3, width: 1920, height: 1080), Layout(preset: "4x4", count: 5, width: 1920, height: 1080),
                       Layout(preset: nil, count: 3, width: 1280, height: 720)]
        for layout in layouts {
            var inputs: [InputConfig] = []
            var images: [Int: CGImage] = [:]
            var colors: [Int: (Int, Int, Int)] = [:]
            for n in 1...layout.count {
                // 蓝通道压低（≈ 31）：白字的蓝通道高，扫蓝通道就分得出字和画面
                let r = 0.3 + 0.4 * Double(n % 5) / 5, g = 0.65 - 0.3 * Double(n % 3) / 3, b = 0.12
                inputs.append(InputConfig(number: n, name: "名字 \(n)", source: .image(path: "/dev/null")))
                let image = try MultiviewLayoutTests.solid(red: r, green: g, blue: b)
                images[n] = image
                colors[n] = try RGBAPixels(image).rgb(8, 8)   // 期望色按同一条色彩管线读（与多画面同样画进 sRGB 缓冲）
            }
            var state = MixerState(format: ProgramFormat(width: layout.width, height: layout.height, frameRate: .fps60), inputs: inputs,
                                   program: 1, preview: min(2, layout.count))
            if let preset = layout.preset {
                state.outputs = [OutputState(number: 1, kind: .multiview, name: "mv", settings: OutputSettings(source: .multiview, multiview: MultiviewLayoutSettings(preset: preset)))]
            }
            let mv = try renderer.render(state: state, inputs: images, size: CGSize(width: layout.width, height: layout.height)).multiview
            let rep = try RGBAPixels(mv)
            let placements = MultiviewLayout.placements(settings: MultiviewLayout.layoutSettings(in: state), inputs: inputs.map(\.number), width: mv.width, height: mv.height)
            var checked = 0
            for input in inputs {
                guard let p = placements.first(where: { $0.source == .input(number: input.number) }) else { continue }
                let thumb = InputStripView.thumbnailRect(for: p, width: mv.width, height: mv.height)
                let want = try XCTUnwrap(colors[input.number])
                let label = Self.labelHeight(outerHeight: p.outer.height * Double(mv.height), frameHeight: Double(mv.height))
                // 切掉的 = 名字条 + 2 px
                XCTAssertEqual((p.inner.height - thumb.height) * Double(mv.height), label + 2, accuracy: 1e-6, "\(layout) 输入 \(input.number)")
                XCTAssertEqual(thumb.x, p.inner.x)
                XCTAssertEqual(thumb.y, p.inner.y)
                XCTAssertEqual(thumb.width, p.inner.width)

                // 1. 缩略图区域：画面部分（16:9 按比例放进内框，边上 2 px 的抗锯齿不算）每个像素都是这一路的纯色；整个区域没有白字
                let picture = Self.fitted(p.inner, width: mv.width, height: mv.height).insetBy(dx: 2, dy: 2)
                let thumbPx = Self.pixels(thumb, width: mv.width, height: mv.height)
                let notSolid = Self.count(rep, thumbPx.intersection(picture)) { !MultiviewLayoutTests.close($0, want, tolerance: 8) }
                let textInThumb = Self.count(rep, thumbPx) { $0.2 > 120 }
                XCTAssertEqual(notSolid, 0, "\(layout) 输入 \(input.number)：缩略图的画面里有 \(notSolid) 个像素不是纯色 \(want)（名字条漏进来了？）")
                XCTAssertEqual(textInThumb, 0, "\(layout) 输入 \(input.number)：缩略图区域里有 \(textInThumb) 个白字像素")

                // 2. 对照：内框底部名字条那几行扫得到白字（扫描找得到名字条；原来整个内框当缩略图时它就在里面）
                let innerPx = Self.pixels(p.inner, width: mv.width, height: mv.height)
                let labelRows = CGRect(x: innerPx.minX, y: innerPx.maxY - CGFloat(label), width: innerPx.width, height: CGFloat(label))
                let textInLabel = Self.count(rep, labelRows) { $0.2 > 120 }
                XCTAssertGreaterThan(textInLabel, 20, "\(layout) 输入 \(input.number)：名字条那几行应扫得到白字（\(textInLabel)）")
                checked += 1
            }
            print("缩略图切名字条：\(layout) 扫了 \(checked) 路，名字条高 \(placements.first { if case .input = $0.source { true } else { false } }.map { Self.labelHeight(outerHeight: $0.outer.height * Double(layout.height), frameHeight: Double(layout.height)) } ?? 0) px")
            XCTAssertGreaterThan(checked, 0, "\(layout)")
        }
    }

    /// App 里接的就是这个几何：两路合成源，缩略图的 sourceRect = 内框切掉名字条；标题条里仍是编号 + 名字（名字只在标题条出现一次）。
    func testThumbnails_cellsUseCroppedRectAndTitleBarKeepsName() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        let placements = MultiviewLayout.placements(settings: nil, inputs: [1, 2], width: 1920, height: 1080)
        for n in [1, 2] {
            let p = try XCTUnwrap(placements.first { $0.source == .input(number: n) })
            let cell = try XCTUnwrap(wc.inputStrip.cells[n])
            XCTAssertTrue(AppTest.waitUntil(2) { cell.display.sourceRect == InputStripView.thumbnailRect(for: p, width: 1920, height: 1080) },
                          "输入 \(n) 的缩略图应切掉名字条：\(cell.display.sourceRect) / 内框 \(p.inner)")
            XCTAssertNotEqual(cell.display.sourceRect, p.inner)
            XCTAssertEqual(cell.displayedName, "合成 \(n)", "标题条保留名字")
        }
    }

    /// 渲染器的名字条高（CompositorPasses.drawCellLabel，Float 算）：格高 × 14%，≥ 12 px，≤ 画面高 × 3.5%。
    static func labelHeight(outerHeight: Double, frameHeight: Double) -> Double {
        let cell = Float(outerHeight), h = Float(frameHeight)
        return Double(max(12, min((cell * 0.14).rounded(), (h * 0.035).rounded())))
    }

    /// 16:9 的纯色输入按比例放进内框（渲染器的 fit）之后画面占的像素范围。
    static func fitted(_ inner: NormalizedRect, width: Int, height: Int) -> CGRect {
        let iw = inner.width * Double(width), ih = inner.height * Double(height)
        let pw = min(iw, ih * 16 / 9), ph = pw * 9 / 16
        return CGRect(x: inner.x * Double(width) + (iw - pw) / 2, y: inner.y * Double(height) + (ih - ph) / 2, width: pw, height: ph)
    }

    /// 归一化矩形 → 完整落在里面的像素范围（像素坐标，原点左上）。
    static func pixels(_ r: NormalizedRect, width: Int, height: Int) -> CGRect {
        let x0 = (r.x * Double(width)).rounded(.up), y0 = (r.y * Double(height)).rounded(.up)
        let x1 = ((r.x + r.width) * Double(width)).rounded(.down), y1 = ((r.y + r.height) * Double(height)).rounded(.down)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// 数一块像素里满足条件的个数（RGB 0–255）。
    static func count(_ pixels: RGBAPixels, _ rect: CGRect, where predicate: ((Int, Int, Int)) -> Bool) -> Int {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        var n = 0
        let x0 = max(0, Int(rect.minX.rounded(.up))), x1 = min(pixels.width, Int(rect.maxX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.up))), y1 = min(pixels.height, Int(rect.maxY.rounded(.down)))
        guard x0 < x1, y0 < y1 else { return 0 }
        for y in y0..<y1 {
            for x in x0..<x1 where predicate(pixels.rgb(x, y)) { n += 1 }
        }
        return n
    }
}

/// 整张图画进一块 sRGB RGBA8 缓冲再按字节读（逐像素 NSBitmapImageRep.colorAt 在几百万像素上太慢）。内存第 0 行 = 图像顶行。
struct RGBAPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw XCTSkip("建不出 sRGB 位图上下文") }
        width = w
        height = h
        bytes = buf
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}
