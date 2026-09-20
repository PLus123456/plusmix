// 多画面 / PVW 作为一张帧送出去（W3-B 交付 4"作为一张纹理送外部显示 / 独立窗口 / NDI"）：
// MetalRendererOptions.previewOutput / multiviewOutput 打开时 RenderedFrame.preview / multiview 非 nil，NV12 内容与离线渲染逐字节相同。
import CoreVideo
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class AuxOutputTests: XCTestCase {
    func testAux_previewAndMultiviewFramesMatchOfflineWhenEnabled() throws {
        var options = MetalRendererOptions()
        options.previewOutput = true
        options.multiviewOutput = true
        let renderer = try MetalRenderer(options: options)
        try renderer.prepare(format: .hd1080p60, maxInputs: 9)
        let sink = CollectingSink()
        sink.holdDepth = 1
        renderer.sink = sink
        let buffers = TestImages.phase2ReferenceBuffers()
        let table = RenderInputTable(capacity: 9)
        for (n, pb) in buffers {
            table[inputNumber: n] = Frame(pixelBuffer: pb, pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: n, sequence: 0, ingressTime: .zero)
        }
        let state = ReferenceStates.withMultiviewLayout(ReferenceStates.fixed8(), ReferenceStates.customLayout)
        let snap = MixerSnapshot(state: state, sequence: 1, tick: .zero)
        for i in 0..<30 {   // 等标签线程画好名字
            _ = renderer.render(tick: Tick(Int64(i)), at: HostClock.now(), snapshot: snap, inputs: table)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(renderer.render(tick: Tick(30), at: HostClock.now(), snapshot: snap, inputs: table), .submitted)
        Thread.sleep(forTimeInterval: 0.1)
        let frame = try XCTUnwrap(sink.lastHeld)
        renderer.shutdown()
        let preview = try XCTUnwrap(frame.preview, "previewOutput 打开时 RenderedFrame.preview 应非 nil")
        let multiview = try XCTUnwrap(frame.multiview, "multiviewOutput 打开时 RenderedFrame.multiview 应非 nil")
        XCTAssertEqual(preview.inputNumber, 0)
        XCTAssertEqual(preview.pixelFormat, .nv12)
        XCTAssertEqual(preview.pts, frame.tickTime)
        XCTAssertEqual(multiview.pts, frame.tickTime)
        XCTAssertEqual(multiview.width, 1920)
        let offline = try OfflineRenderer().render(state: state, pixelBuffers: buffers, size: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(PixelBuffers.nv12Planes(preview.pixelBuffer).luma, PixelBuffers.nv12Planes(offline.previewNV12).luma, "PVW NV12 亮度应与离线相同")
        XCTAssertEqual(PixelBuffers.nv12Planes(preview.pixelBuffer).chroma, PixelBuffers.nv12Planes(offline.previewNV12).chroma)
        XCTAssertEqual(PixelBuffers.nv12Planes(multiview.pixelBuffer).luma, PixelBuffers.nv12Planes(offline.multiviewNV12).luma, "多画面 NV12 亮度应与离线相同")
        XCTAssertEqual(PixelBuffers.nv12Planes(multiview.pixelBuffer).chroma, PixelBuffers.nv12Planes(offline.multiviewNV12).chroma)
        XCTAssertEqual(PixelBuffers.nv12Planes(frame.program.pixelBuffer).luma, PixelBuffers.nv12Planes(offline.programNV12).luma)
        // 三份缓冲互不相同
        XCTAssertFalse(preview.pixelBuffer === frame.program.pixelBuffer)
        XCTAssertFalse(multiview.pixelBuffer === preview.pixelBuffer)
    }

    /// 默认关：preview / multiview 仍是 nil（第一版契约允许），不多花 GPU。
    func testAux_disabledByDefault() throws {
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd720p60, maxInputs: 2)
        let sink = CollectingSink()
        sink.holdDepth = 1
        renderer.sink = sink
        let table = RenderInputTable(capacity: 2)
        table[inputNumber: 1] = Frame(pixelBuffer: TestImages.grayBuffer(level: 100, width: 1280, height: 720), pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: 1, sequence: 0, ingressTime: .zero)
        let snap = MixerSnapshot(state: MixerState(format: .hd720p60, inputs: ReferenceStates.inputs(count: 1), program: 1), sequence: 1, tick: .zero)
        XCTAssertEqual(renderer.render(tick: Tick(1), at: HostClock.now(), snapshot: snap, inputs: table), .submitted)
        Thread.sleep(forTimeInterval: 0.2)
        renderer.shutdown()
        let f = try XCTUnwrap(sink.lastHeld)
        XCTAssertNil(f.preview)
        XCTAssertNil(f.multiview)
    }
}
