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
