// W3-C2 交付 1：Aux（外部显示选"输入 n"）由本包自己画输入帧的全分辨率画面（G4 拟、用户 2026-09-22 批）。
// 离屏：窗口里用的同一个 AuxInputPresenter 画进一张 1920×1080 的 BGRA8 纹理（= drawable 的格式），逐像素对照
//   ① 输入帧本身（BGRA 输入：字节相等）；② 渲染器对同一帧的换算（OfflineRenderer 的 PGM，与实时路径同一个 CompositorPasses）——"与渲染器同一套系数"；
//   ③ CPU 参考公式（BT.709 / limited，与 Compositor.metal 的 ycbcrToRGB 同式，±1 LSB 只给 CPU 双精度与 GPU 单精度的舍入）。
@preconcurrency import Metal
import AppKit
import CoreVideo
import XCTest
import SwitcherContracts
import SwitcherRender
@testable import SwitcherExternal

@MainActor
final class AuxInputTests: XCTestCase {
    private var device: any MTLDevice { MTLCreateSystemDefaultDevice()! }

    /// 画一次：presenter 决定画什么 → 编码进离屏纹理 → 等 GPU 完成 → 读回。
    private func drawOnce(_ presenter: AuxInputPresenter, queue: any MTLCommandQueue, width: Int = 1920, height: Int = 1080,
                          now: HostTime = .now()) -> (draw: AuxInputPresenter.Draw, bytes: [UInt8]?) {
        let draw = presenter.nextDraw(now: now, targetWidth: width, targetHeight: height)
        if case .nothing = draw { return (draw, nil) }
        let target = TextureReadback.makeTarget(device: queue.device, width: width, height: height)
        let cb = queue.makeCommandBuffer()!
        guard presenter.encode(draw, into: target, commandBuffer: cb) else {
            presenter.didNotPresent(draw)
            return (draw, nil)
        }
        cb.commit()
        cb.waitUntilCompleted()
        presenter.didPresent(draw)
        return (draw, TextureReadback.bytes(of: target))
    }

    private static func programState(inputName: String = "机位一") -> MixerState {
        MixerState(format: .hd1080p60, inputs: [InputConfig(number: 1, name: inputName, source: .image(path: "/aux.png"))], program: 1)
    }

    /// BT.709 / BT.601 / BT.2020 limited / full：码值 → 0–255 的 RGB（与 Compositor.metal 的 ycbcrToRGB 同一式子），双精度。
    private static func referenceRGB(y: Double, cb: Double, cr: Double, fullRange: Bool, kr: Double = 0.2126, kb: Double = 0.0722) -> (Double, Double, Double) {
        let kg = 1 - kr - kb
        let yn = fullRange ? y / 255 : (y - 16) / 219
        let cbn = fullRange ? (cb - 128) / 255 : (cb - 128) / 224
        let crn = fullRange ? (cr - 128) / 255 : (cr - 128) / 224
        let r = yn + 2 * (1 - kr) * crn
        let b = yn + 2 * (1 - kb) * cbn
        let g = (yn - kr * r - kb * b) / kg
        func c(_ v: Double) -> Double { min(max(v, 0), 1) * 255 }
        return (c(r), c(g), c(b))
    }

    /// NV12 的 CPU 参考：色度按着色器的采样点（4:2:0 水平左对齐 = 色度坐标 + 0.25 色度像素、垂直居中）双线性插值。
    private static func referenceBytes(nv12 pb: CVPixelBuffer, fullRange: Bool) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        func chroma(_ cx: Int, _ cy: Int, _ k: Int) -> Double {
            Double(cp[min(max(cy, 0), ch - 1) * cbpr + min(max(cx, 0), cw - 1) * 2 + k])
        }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for py in 0..<h {
            // 色度纹素坐标（纹素中心在 j + 0.5）：u = (px + 0.5) / w · cw + 0.25，v = (py + 0.5) / h · ch
            let v = (Double(py) + 0.5) / Double(h) * Double(ch) - 0.5
            let j0 = Int(v.rounded(.down)), fy = v - Double(j0)
            for px in 0..<w {
                let u = (Double(px) + 0.5) / Double(w) * Double(cw) + 0.25 - 0.5
                let i0 = Int(u.rounded(.down)), fx = u - Double(i0)
                var cbcr = [0.0, 0.0]
                for k in 0..<2 {
                    let top = chroma(i0, j0, k) * (1 - fx) + chroma(i0 + 1, j0, k) * fx
                    let bottom = chroma(i0, j0 + 1, k) * (1 - fx) + chroma(i0 + 1, j0 + 1, k) * fx
                    cbcr[k] = top * (1 - fy) + bottom * fy
                }
                let (r, g, b) = referenceRGB(y: Double(yp[py * ybpr + px]), cb: cbcr[0], cr: cbcr[1], fullRange: fullRange)
                let o = (py * w + px) * 4
                out[o] = UInt8(b.rounded()); out[o + 1] = UInt8(g.rounded()); out[o + 2] = UInt8(r.rounded())
            }
        }
        return out
    }

    /// 在 NV12 的色度平面上铺确定性的伪随机 Cb / Cr（16–240），逼出 4:2:0 插值的每一种权重（0.25 / 0.5 / 0.75）。
    private static func scrambleChroma(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<ch {
            for x in 0..<(cw * 2) {
                s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                cp[y * cbpr + x] = UInt8(16 + Int((s >> 33) % 225))
            }
        }
    }

    /// 离屏：1080p 合成源 → Aux 画出来的纹理逐像素 = 输入帧（不是多画面缩略格子）；NV12 与 BGRA 各一次（外加一张色度噪声的 NV12）。
    func testAux_inputWindowDrawsFullResolutionFrame() throws {
        let queue = device.makeCommandQueue()!
        _ = try AuxPipeline.shared(for: device)   // 窗口里是后台预编，这里同步编好
        let offline = try OfflineRenderer(device: device)
        let presenter = AuxInputPresenter(device: device)
        presenter.inputState = .live   // 这条只比像素；逐帧对照渲染器要好几秒，别让"帧旧了 = 无信号"插进来
        let slot = TestFrameSlot()
        presenter.attach(input: 1, name: "机位一", slot: slot)
        XCTAssertEqual(presenter.textureCacheInput, 1, "纹理缓存按输入编号预建（attach 时建，不等第一帧）")

        let bgra = PatternFrames.bgra(frameNumber: 1001)
        let nv12 = PatternFrames.nv12(frameNumber: 1002)
        let nv12Noisy = PatternFrames.nv12(frameNumber: 1003)
        Self.scrambleChroma(nv12Noisy)
        let cases: [(String, CVPixelBuffer, UInt32)] = [("BGRA", bgra, 1001), ("NV12", nv12, 1002), ("NV12 色度噪声", nv12Noisy, 1003)]
        var sequence: UInt64 = 0
        for (label, pb, frameNumber) in cases {
            sequence += 1
            let frame = PatternFrames.frame(pb, sequence: sequence, pts: .now())
            slot.push(frame)
            let (draw, bytes) = drawOnce(presenter, queue: queue)
            guard case .frame(let drawn) = draw, let got = bytes else { return XCTFail("\(label)：应画输入帧，实际 \(draw)") }
            XCTAssertEqual(drawn.sequence, sequence, label)
            XCTAssertEqual(presenter.signal, .live, label)

            // ② 与渲染器对同一帧的换算逐像素相等（同一套系数、同一种色度对齐与采样）
            let reference = try offline.render(state: Self.programState(), frames: [1: frame], size: CGSize(width: 1920, height: 1080)).program
            let referenceBytes = TextureReadback.bytes(of: reference)
            let vsRenderer = TextureReadback.compareRGB(got, referenceBytes)
            print("Aux \(label)：对渲染器 PGM 最大差 \(vsRenderer.maxDiff)，不同像素 \(vsRenderer.differingPixels) / \(1920 * 1080)")
            if vsRenderer.differingPixels > 0 { print("  " + TextureReadback.describeDifferences(got, referenceBytes, width: 1920)) }
            XCTAssertEqual(vsRenderer.maxDiff, 0, "\(label)：Aux 与渲染器对同一输入帧的换算应逐像素相等")

            // ① BGRA 输入：画出来的字节 = 输入字节
            if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA {
                let vsInput = TextureReadback.compareRGB(got, TextureReadback.bytes(ofBGRA: pb))
                XCTAssertEqual(vsInput.maxDiff, 0, "\(label)：BGRA 输入应原样画出（不同像素 \(vsInput.differingPixels)）")
            } else {
                // ③ YCbCr 输入：与 CPU 参考公式（BT.709 limited）只差单精度舍入
                let vsCPU = TextureReadback.compareRGB(got, Self.referenceBytes(nv12: pb, fullRange: false))
                print("Aux \(label)：对 CPU 参考公式最大差 \(vsCPU.maxDiff)，不同像素 \(vsCPU.differingPixels)")
                XCTAssertLessThanOrEqual(vsCPU.maxDiff, 1, "\(label)：BT.709 limited 的换算系数不对")
            }

            // 全分辨率：帧号 / 输入 ID 在画出来的 1080p 上照样解得出（缩略格子 470×260 放大回来做不到逐像素相等，上面已排除）
            if label != "NV12 色度噪声" {
                var copy = got
                let decoded = copy.withUnsafeMutableBytes { raw in
                    TestPattern.decode(.bgra(base: raw.baseAddress!, bytesPerRow: 1920 * 4), width: 1920, height: 1080)
                }
                XCTAssertEqual(decoded.frameNumber, frameNumber, label)
                XCTAssertEqual(decoded.inputID, 3, label)
            }
        }
        XCTAssertEqual(presenter.presentedFrames, 3)
        XCTAssertEqual(presenter.droppedFrames, 0)
        // 没有新帧：这次刷新不画（不重复 blit）
        let (idle, _) = drawOnce(presenter, queue: queue)
        guard case .nothing = idle else { return XCTFail("没有新帧不该再画：\(idle)") }
    }

    /// UYVY（DeckLink 的 8 位 4:2:2）同一套：与渲染器逐像素相等。
    func testAux_uyvyInputMatchesRenderer() throws {
        let queue = device.makeCommandQueue()!
        _ = try AuxPipeline.shared(for: device)
        let offline = try OfflineRenderer(device: device)
        let presenter = AuxInputPresenter(device: device)
        presenter.inputState = .live
        let slot = TestFrameSlot()
        presenter.attach(input: 1, name: "卡一", slot: slot)
        let uyvy = PatternFrames.uyvy(from: PatternFrames.nv12(frameNumber: 77))
        let frame = PatternFrames.frame(uyvy, sequence: 1)
        slot.push(frame)
        let (draw, bytes) = drawOnce(presenter, queue: queue)
        guard case .frame = draw, let got = bytes else { return XCTFail("应画 UYVY 帧：\(draw)") }
        let reference = try offline.render(state: Self.programState(), frames: [1: frame], size: CGSize(width: 1920, height: 1080)).program
        let cmp = TextureReadback.compareRGB(got, TextureReadback.bytes(of: reference))
        print("Aux UYVY：对渲染器最大差 \(cmp.maxDiff)，不同像素 \(cmp.differingPixels)")
        XCTAssertEqual(cmp.maxDiff, 0)
    }

    /// 输入无信号时画占位（与多画面格子同一套文案："无信号" + 左下角"编号  名字"）；有帧就画帧，帧断了（> 3 个帧间隔，与输入的无信号看门狗同一口径）回到占位；
    /// 组装方给了输入的运行状态就以它为准（noSignal / error 的文案）。
    func testAux_noSignalDrawsPlaceholder() throws {
        let queue = device.makeCommandQueue()!
        _ = try AuxPipeline.shared(for: device)
        let presenter = AuxInputPresenter(device: device)
        XCTAssertEqual(AuxInputPresenter.defaultNoSignalText, "No signal", "W3-C3：包里的默认文案是 ASCII，App 按本地化表给 input.noSignal")
        XCTAssertEqual(presenter.noSignalText, AuxInputPresenter.defaultNoSignalText)
        presenter.noSignalText = "无信号"   // App 中文界面给的（SwitcherSession：aux.external.noSignalText = L("input.noSignal")）
        let slot = TestFrameSlot()
        presenter.attach(input: 2, name: "机位二", slot: slot)
        XCTAssertEqual(presenter.placeholderLines.center, "无信号")
        XCTAssertEqual(presenter.placeholderLines.label, "2  机位二", "与多画面格子的名字条同一格式")

        // 1. 帧槽里从来没有帧 → 占位（文字栅格化在后台，好了再补画）
        let first = drawOnce(presenter, queue: queue)
        guard case .placeholder = first.draw else { return XCTFail("没有帧应画占位：\(first.draw)") }
        XCTAssertEqual(presenter.signal, .waitingForFrames)
        XCTAssertTrue(pumpEvents(until: 3) { presenter.placeholderReady(width: 1920, height: 1080) }, "占位文字应在后台栅格化好")
        let withText = drawOnce(presenter, queue: queue)
        guard case .placeholder = withText.draw, let placeholder = withText.bytes else { return XCTFail("文字好了应补画一次占位：\(withText.draw)") }
        let again = drawOnce(presenter, queue: queue)
        guard case .nothing = again.draw else { return XCTFail("占位画完一次就不再重画：\(again.draw)") }
        func brightPixels(_ bytes: [UInt8], x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
            var n = 0
            for y in y0..<y1 { for x in x0..<x1 where bytes[(y * 1920 + x) * 4 + 1] > 128 { n += 1 } }
            return n
        }
        let center = brightPixels(placeholder, x0: 480, y0: 400, x1: 1440, y1: 680)
        let corner = brightPixels(placeholder, x0: 0, y0: 960, x1: 700, y1: 1080)
        let elsewhere = brightPixels(placeholder, x0: 1000, y0: 0, x1: 1920, y1: 380)
        print("占位：中间亮像素 \(center)，左下名字条 \(corner)，右上 \(elsewhere)")
        XCTAssertGreaterThan(center, 500, "中间应有「无信号」")
        XCTAssertGreaterThan(corner, 200, "左下应有「2  机位二」")
        XCTAssertEqual(elsewhere, 0, "其余是黑底")
        XCTAssertEqual(presenter.presentedFrames, 0, "占位不算呈现的帧")

        // 2. 来帧 → 画帧（时刻都按这一帧的到达时刻算：debug 下逐像素比一次就要几百毫秒）
        let pb = PatternFrames.bgra(frameNumber: 5)
        let arrived = HostTime.now()
        slot.push(PatternFrames.frame(pb, input: 2, sequence: 1, pts: arrived))
        let live = drawOnce(presenter, queue: queue, now: arrived + HostDuration(milliseconds: 1))
        guard case .frame = live.draw, let liveBytes = live.bytes else { return XCTFail("来帧应画帧：\(live.draw)") }
        XCTAssertEqual(presenter.signal, .live)
        XCTAssertEqual(TextureReadback.compareRGB(liveBytes, TextureReadback.bytes(ofBGRA: pb)).maxDiff, 0)

        // 3. 帧断了：3 个帧间隔（60 fps → 50 ms）之内仍是最后一帧（不重画），超过就回到占位
        let soon = drawOnce(presenter, queue: queue, now: arrived + HostDuration(milliseconds: 40))
        guard case .nothing = soon.draw else { return XCTFail("没超时不该变：\(soon.draw)") }
        XCTAssertEqual(presenter.signal, .live)
        let late = drawOnce(presenter, queue: queue, now: arrived + HostDuration(milliseconds: 60))
        guard case .placeholder = late.draw, let lateBytes = late.bytes else { return XCTFail("超时应回到占位：\(late.draw)") }
        XCTAssertEqual(presenter.signal, .noSignal)
        XCTAssertEqual(TextureReadback.compareRGB(lateBytes, placeholder).maxDiff, 0, "同一个占位")

        // 4. 组装方给的运行状态优先：noSignal → 占位，即使帧还新鲜；error → 占位中间换成错误文案
        let fresh = HostTime.now()
        slot.push(PatternFrames.frame(pb, input: 2, sequence: 2, pts: fresh))
        presenter.inputState = .noSignal
        let forced = drawOnce(presenter, queue: queue, now: fresh + HostDuration(milliseconds: 1))
        if case .frame = forced.draw { XCTFail("运行状态 noSignal 时不该画帧") }
        presenter.inputState = .error(message: "摄像头权限被拒")
        XCTAssertEqual(presenter.placeholderLines.center, "摄像头权限被拒")
        let blackFirst = drawOnce(presenter, queue: queue)   // 文案变了：先画黑底，同时后台栅格化新文案（窗口里是下一次刷新）
        guard case .placeholder = blackFirst.draw else { return XCTFail("文案变了应重画占位：\(blackFirst.draw)") }
        XCTAssertTrue(pumpEvents(until: 3) { presenter.placeholderReady(width: 1920, height: 1080) })
        let failed = drawOnce(presenter, queue: queue)
        guard case .placeholder = failed.draw, let errorBytes = failed.bytes else { return XCTFail("error 应画占位：\(failed.draw)") }
        XCTAssertEqual(presenter.signal, .error("摄像头权限被拒"))
        XCTAssertGreaterThan(TextureReadback.compareRGB(errorBytes, placeholder).differingPixels, 100, "错误文案与「无信号」不同")
        presenter.inputState = .live
        let again3 = HostTime.now()
        slot.push(PatternFrames.frame(pb, input: 2, sequence: 3, pts: again3))
        let back = drawOnce(presenter, queue: queue, now: again3 + HostDuration(milliseconds: 1))
        guard case .frame = back.draw else { return XCTFail("状态回到 live 应画帧：\(back.draw)") }

        // 5. 文案可由组装方换（App 按本地化表给；英文界面就是包里的默认）
        presenter.noSignalText = "Kein Signal"
        presenter.inputState = .noSignal
        XCTAssertEqual(presenter.placeholderLines.center, "Kein Signal")

        // 6. 没接帧槽（组装方没给 / 分支用完）→ 占位
        presenter.attach(input: 2, name: "机位二", slot: nil)
        presenter.inputState = nil
        let orphan = drawOnce(presenter, queue: queue)
        guard case .placeholder = orphan.draw else { return XCTFail("没有帧槽应画占位：\(orphan.draw)") }
        XCTAssertEqual(presenter.signal, .noSlot)
    }

    /// 纹理缓存按输入编号预建、换输入时重建；同一路重复 attach 不重建。
    func testAux_textureCacheRebuiltOnInputSwitch() throws {
        let presenter = AuxInputPresenter(device: device)
        XCTAssertNil(presenter.textureCacheInput)
        let a = TestFrameSlot(), b = TestFrameSlot()
        presenter.attach(input: 1, name: "a", slot: a)
        let g1 = presenter.textureCacheGeneration
        XCTAssertEqual(presenter.textureCacheInput, 1)
        presenter.attach(input: 1, name: "a（改名）", slot: a)
        XCTAssertEqual(presenter.textureCacheGeneration, g1, "同一路同一个帧槽：不重建")
        XCTAssertEqual(presenter.placeholderLines.label, "1  a（改名）")
        presenter.attach(input: 2, name: "b", slot: b)
        XCTAssertEqual(presenter.textureCacheInput, 2)
        XCTAssertGreaterThan(presenter.textureCacheGeneration, g1, "换输入：重建")
        presenter.detach()
        XCTAssertNil(presenter.textureCacheInput)
        XCTAssertEqual(presenter.signal, .detached)
    }
}
