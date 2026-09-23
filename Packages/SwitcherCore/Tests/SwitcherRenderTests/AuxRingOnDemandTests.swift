// PVW / 多画面的 NV12 输出环按需建（W3-B2 可选项；P3 报告 §5 第 1 条）：没有要 PVW / 多画面帧的输出时两个环都不建，
// 状态里一出现就由后台线程建、渲染线程几帧之后开始填 RenderedFrame.preview / .multiview；渲染线程上没有一次分配来自建环或包纹理。
import CoreVideo
import Darwin
import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class AuxRingOnDemandTests: XCTestCase {
    /// 默认选项：prepare 之后两个环都不在；状态里加一路 enabled 的 PVW 输出（NDI）→ 后台线程建 PVW 环，
    /// 第一次看到它的那一拍起几帧内 RenderedFrame.preview 就有；多画面环一直不建；整个过程渲染线程上 SwitcherRender 0 次分配，
    /// 也没有 CoreVideo 建缓冲 / Metal 包 IOSurface 纹理的分配（它们都在后台线程）。
    func testAux_previewRingBuiltOnDemandOffRenderThread() throws {
        try XCTSkipUnless(MallocProbe.isAvailable, "找不到 malloc_logger 符号")
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd1080p60, maxInputs: 9)
        XCTAssertFalse(renderer.isAuxRingBuilt(.preview), "默认选项、还没有状态：PVW 环不该建")
        XCTAssertFalse(renderer.isAuxRingBuilt(.multiview))
        var state = ReferenceStates.fixed8()
        state.outputs = []
        let engine = FakeEngine(renderer: renderer, format: .hd1080p60, inputs: FakeInputs.nv12(count: 8, poolDepth: 2), state: state)
        var withPVW = state
        withPVW.outputs = [OutputState(number: 2, kind: .ndi, name: "PVW 发送", enabled: true, settings: OutputSettings(source: .preview))]
        let enabled = MixerSnapshot(state: withPVW, sequence: 5, tick: Tick(60))
        let switchTick: Int64 = 61                     // 第 60 拍的钩子换快照 → 第 61 拍第一次看到 PVW 输出
        let counting = SharedFlag()
        engine.beforeRender = { [weak engine] tick in
            if tick.rawValue == 40 { MallocProbe.start(); counting.value = true }
            if tick.rawValue == switchTick - 1 { engine?.publish(enabled) }
        }
        engine.afterRender = { tick, _ in
            if counting.value, tick.rawValue == 120 { MallocProbe.stop(); counting.value = false }
        }
        engine.run(seconds: 2.4)
        MallocProbe.stop()
        let builtPreview = renderer.isAuxRingBuilt(.preview), builtMultiview = renderer.isAuxRingBuilt(.multiview)
        let builds = renderer.auxRingBuilds, resident = renderer.auxRingResidentBytes
        renderer.shutdown()

        let samples = engine.sink.samples
        let firstPreview = samples.first { $0.hasPreview }?.tick.rawValue
        XCTAssertFalse(samples.contains { $0.hasPreview && $0.tick.rawValue < switchTick }, "状态要 PVW 之前不该有 PVW 帧")
        let first = try XCTUnwrap(firstPreview, "状态要 PVW 之后应该开始出 PVW 帧")
        XCTAssertLessThanOrEqual(first - switchTick, 3, "后台建环不该拖太久（第 \(switchTick) 拍请求，第 \(first) 拍才有）")
        XCTAssertTrue(samples.filter { $0.tick.rawValue >= first }.allSatisfy(\.hasPreview), "建好之后每一帧都有 PVW")
        XCTAssertFalse(samples.contains(where: \.hasMultiview), "没有要多画面帧的输出：多画面环不建、不填")
        XCTAssertTrue(builtPreview)
        XCTAssertFalse(builtMultiview)
        XCTAssertEqual(builds, 1)

        let list = MallocProbe.attributions()
        let own = list.filter(\.isOwn)
        let ringWork = list.filter { a in a.stack.contains { $0.contains("CVPixelBufferCreate") || $0.contains("iosurface") || $0.contains("OutputBufferRing") } }
        print("PVW 环按需建：第 \(switchTick) 拍请求，第 \(first) 拍开始出 PVW 帧，后台建环 \(builds) 次，常驻 \(resident / 1_048_576) MB；"
              + "第 40–120 拍渲染线程共 \(list.count) 次分配，SwitcherRender 代码 \(own.count) 次，建环 / 包纹理相关 \(ringWork.count) 次")
        for a in (own + ringWork).prefix(3) { print("   \(a.stack.prefix(12).joined(separator: " <- "))") }
        XCTAssertEqual(own.count, 0, "渲染线程上 SwitcherRender 代码不许分配")
        XCTAssertEqual(ringWork.count, 0, "建环、包 NV12 纹理都该在后台线程")
    }

    /// 强制开（options.previewOutput / multiviewOutput）照旧在 prepare 里建好；multiview = false 时多画面环永远不建。
    func testAux_forcedOutputsBuildAtPrepareAndMultiviewOffNeverBuilds() throws {
        var forced = MetalRendererOptions()
        forced.previewOutput = true
        forced.multiviewOutput = true
        let a = try MetalRenderer(options: forced)
        try a.prepare(format: .hd720p60, maxInputs: 2)
        XCTAssertTrue(a.isAuxRingBuilt(.preview))
        XCTAssertTrue(a.isAuxRingBuilt(.multiview))
        XCTAssertEqual(a.auxRingBuilds, 0, "prepare 里建的不算后台建环")
        a.shutdown()

        var off = MetalRendererOptions()
        off.multiview = false
        off.multiviewOutput = true            // multiview 关着时强制开也不起作用（多画面根本不画）
        let b = try MetalRenderer(options: off)
        try b.prepare(format: .hd720p60, maxInputs: 2)
        XCTAssertFalse(b.isAuxRingBuilt(.multiview))
        let sink = CollectingSink()
        b.sink = sink
        let table = RenderInputTable(capacity: 2)
        table[inputNumber: 1] = Frame(pixelBuffer: TestImages.grayBuffer(level: 100, width: 1280, height: 720), pts: .zero, duration: .zero,
                                      color: .sRGBFull, inputNumber: 1, sequence: 0, ingressTime: .zero)
        var s = MixerState(format: .hd720p60, inputs: ReferenceStates.inputs(count: 1), program: 1)
        s.outputs = [OutputState(number: 1, kind: .multiview, name: "多画面", enabled: true, settings: OutputSettings(source: .multiview))]
        for i in 0..<10 {
            _ = b.render(tick: Tick(Int64(i)), at: HostClock.now(), snapshot: MixerSnapshot(state: s, sequence: 1, tick: .zero), inputs: table)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(b.isAuxRingBuilt(.multiview), "multiview = false：状态要也不建")
        XCTAssertFalse(sink.samples.contains(where: \.hasMultiview))
        b.shutdown()
    }
}
