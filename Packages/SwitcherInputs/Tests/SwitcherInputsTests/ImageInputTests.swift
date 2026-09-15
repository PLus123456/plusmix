import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherInputs

/// ImageInput：一次解码、大图预缩放到节目分辨率上限、PNG alpha 保留（预乘 BGRA）、帧槽里永远同一帧（pts 每拍刷新为拍点）。
final class ImageInputTests: XCTestCase {
    /// 写一张 PNG：左半 alpha 0.5 的纯红（直通），右半不透明绿。
    private func writePNG(width: Int, height: Int, name: String) throws -> URL {
        let url = RepoPaths.output.appendingPathComponent(name)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!   // 与 ImageInput 的工作色彩空间相同，解码时不做色彩转换
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 0, 0, 0.5])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 1, 0, 1])!)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeTiming(_ format: ProgramFormat = .hd1080p60) -> ProgramTiming {
        ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: 60))
    }

    func testImage_pngAlphaPreserved_outputsPremultipliedBGRA() throws {
        let url = try writePNG(width: 400, height: 200, name: "alpha.png")
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try ImageInput(number: 2, name: "图", path: url.path, timing: timing, videoSlot: slot)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 2000) { input.state == .live })
        let driver = TickDriver(timing: timing)
        let picks = driver.run(from: driver.firstTick(afterMs: 40), count: 5) { n, t -> (Pick, [Int]) in
            let f = slot.latest(atOrBefore: t)
            var pixels: [Int] = []
            if let pb = f?.pixelBuffer {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(pb)
                let left = 100 * stride + 100 * 4, right = 100 * stride + 300 * 4
                pixels = [Int(base[left]), Int(base[left + 1]), Int(base[left + 2]), Int(base[left + 3]),
                          Int(base[right]), Int(base[right + 1]), Int(base[right + 2]), Int(base[right + 3])]
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            return (Pick(tick: n, tickTime: t, frame: f), pixels)
        }
        let (p, px) = picks.last!
        XCTAssertEqual(p.pixelFormat, .bgra)
        XCTAssertEqual(px.count, 8)
        // 左半：alpha 0.5 红，预乘 → B0 G0 R128 A128；右半：B0 G255 R0 A255
        XCTAssertEqual(px[0], 0); XCTAssertEqual(px[1], 0); XCTAssertEqual(px[2], 128, accuracy: 1); XCTAssertEqual(px[3], 128, accuracy: 1)
        XCTAssertEqual(px[4], 0); XCTAssertEqual(px[5], 255); XCTAssertEqual(px[6], 0); XCTAssertEqual(px[7], 255)
        XCTAssertEqual(input.imageWidth, 400)
        XCTAssertEqual(input.imageHeight, 200)
        XCTAssertEqual(p.inputNumber, 2)
    }

    func testImage_largeImageDownscaledToProgramBounds_keepsAspect() throws {
        let url = try writePNG(width: 4000, height: 3000, name: "large.png")
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try ImageInput(number: 1, name: "大图", path: url.path, timing: timing, videoSlot: slot)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 5000) { input.state == .live })
        XCTAssertEqual(input.imageWidth, 1440, "4000×3000 缩到 1080 高：1440×1080")
        XCTAssertEqual(input.imageHeight, 1080)
        let driver = TickDriver(timing: timing)
        let pick = driver.run(from: driver.firstTick(afterMs: 40), count: 2) { n, t in Pick(tick: n, tickTime: t, frame: slot.latest(atOrBefore: t)) }.last!
        XCTAssertTrue(pick.hasFrame)
        XCTAssertEqual(pick.pixelFormat, .bgra)
        // 小图不放大
        let small = try writePNG(width: 320, height: 240, name: "small.png")
        let input2 = try ImageInput(number: 3, name: "小图", path: small.path, timing: timing, videoSlot: LockFreeFrameSlot(capacity: 3))
        defer { input2.stop() }
        try input2.start()
        XCTAssertTrue(waitUntil(timeoutMs: 2000) { input2.state == .live })
        XCTAssertEqual(input2.imageWidth, 320)
        XCTAssertEqual(input2.imageHeight, 240)
    }

    func testImage_sameBufferEveryTick_ptsRefreshedToTick_noReuse() throws {
        let url = try writePNG(width: 64, height: 64, name: "tiny.png")
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try ImageInput(number: 1, name: "图", path: url.path, timing: timing, videoSlot: slot)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 2000) { input.state == .live })
        let driver = TickDriver(timing: timing)
        var surfaceIDs = Set<UInt32>()
        let picks = driver.run(from: driver.firstTick(afterMs: 40), count: 60) { n, t -> Pick in
            let f = slot.latest(atOrBefore: t)
            if let pb = f?.pixelBuffer, let s = CVPixelBufferGetIOSurface(pb) { surfaceIDs.insert(IOSurfaceGetID(s.takeUnretainedValue())) }
            return Pick(tick: n, tickTime: t, frame: f)
        }
        input.stop()
        XCTAssertEqual(surfaceIDs.count, 1, "帧槽里永远同一帧（同一个 IOSurface）")
        for p in picks {
            XCTAssertTrue(p.hasFrame, "\(p)")
            XCTAssertEqual(p.pts, p.tickTime, "pts 每拍刷新为拍点：\(p)")
            XCTAssertEqual(p.inputNumber, 1)
        }
        let seqs = picks.compactMap(\.sequence)
        for i in 1..<seqs.count { XCTAssertEqual(seqs[i], seqs[i - 1] + 1, "每拍一次新 push（序号递增）") }
        let s = slot.stats
        XCTAssertEqual(s.reused, 0, "每拍都有新 push，不该靠 reused：\(s)")
        // 拍点循环比输入晚起 40 ms，前几拍的 push 没人取会被计成 dropped（设计内），之后不该再有
        XCTAssertLessThanOrEqual(s.dropped, 4, "\(s)")
        XCTAssertEqual(input.counters.distinctSurfaces, 1)
    }

    func testImage_missingFile_stateIsErrorWithMessage() throws {
        let timing = makeTiming()
        let input = try ImageInput(number: 1, name: "图", path: "/nonexistent/nope.png", timing: timing, videoSlot: LockFreeFrameSlot(capacity: 3))
        XCTAssertThrowsError(try input.start())
        guard case .error(let m) = input.state else { return XCTFail("\(input.state)") }
        XCTAssertTrue(m.contains("nope.png"), m)
    }
}
