// 实时路径：V1 渲染耗时、T1 零分配、T3 在途限制、离线 == 实时、输出环。
import CoreVideo
import Darwin
import Metal
import XCTest
import SwitcherContracts
@testable import SwitcherRender

final class RealtimeRendererTests: XCTestCase {
    /// V1：1080p60、8 路 1080p 输入、4 个 overlay 开 + Fade 进行中 + 多画面，跑 30 秒（SWITCHER_V1_SECONDS 可改），
    /// render_ms 平均和 p99 写进报告；断言用测试标准 §4 的"必须"档（平均 ≤ 6 ms，p99 ≤ 12 ms）。
    func testV1_1080p60EightInputsFourOverlays_renderMs() throws {
        let seconds = Double(ProcessInfo.processInfo.environment["SWITCHER_V1_SECONDS"] ?? "30") ?? 30
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd1080p60, maxInputs: 9)
        let engine = FakeEngine(renderer: renderer, format: .hd1080p60, inputs: FakeInputs.nv12(count: 8), state: LoadStates.eightInputsFourOverlays())
        engine.run(seconds: seconds)
        renderer.shutdown()
        let all = engine.sink.renderMs
        XCTAssertGreaterThan(all.count, Int(seconds * 55), "30 秒 60 fps 应有约 1800 帧完成，实际 \(all.count)")
        // 去掉预热的前 60 帧
        let ms = Array(all.dropFirst(60))
        let mean = ms.reduce(0, +) / Double(ms.count)
        let p99 = percentile(ms, 0.99), p50 = percentile(ms, 0.5), maxV = ms.max() ?? 0
        let gpu = engine.sink.frames.dropFirst(60).map { ($0.gpuEnd - $0.gpuStart).milliseconds }
        let gpuMean = gpu.reduce(0, +) / Double(gpu.count)
        let submitLag = engine.sink.frames.dropFirst(60).map { ($0.submitTime - $0.tickTime).milliseconds }
        let submitMean = submitLag.reduce(0, +) / Double(submitLag.count)
        print(String(format: "V1 render_ms：帧数 %d，平均 %.3f ms，p50 %.3f，p99 %.3f，最大 %.3f；GPU 执行平均 %.3f ms；拍点→提交平均 %.3f ms；skipped %d",
                     ms.count, mean, p50, p99, maxV, gpuMean, submitMean, Int(engine.skipped.load(ordering: .relaxed))))
        XCTAssertLessThanOrEqual(mean, 6, "V1 平均 render_ms 超过必须档 6 ms")
        XCTAssertLessThanOrEqual(p99, 12, "V1 p99 render_ms 超过必须档 12 ms")
        XCTAssertEqual(engine.skipped.load(ordering: .relaxed), 0, "标准负载下不该跳拍")
    }

    /// T1：稳态 10 秒内渲染线程零分配。数法：malloc_logger 钩子只数渲染线程、只数分配，
    /// 按直接调用者归类 —— SwitcherRender 代码自己的分配必须为 0；Metal / AGX 驱动内部的分配（命令缓冲区、编码器对象）单独计数写进报告。
    func testT1_renderThreadSteadyStateAllocations() throws {
        try XCTSkipUnless(MallocProbe.isAvailable, "找不到 malloc_logger 符号")
        let seconds = Double(ProcessInfo.processInfo.environment["SWITCHER_T1_SECONDS"] ?? "10") ?? 10
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd1080p60, maxInputs: 9)
        let engine = FakeEngine(renderer: renderer, format: .hd1080p60, inputs: FakeInputs.nv12(count: 8), state: LoadStates.eightInputsFourOverlays())
        // 预热 2 秒（纹理表填满、标签画好），然后只在 render() 内部计数
        let counting = SharedFlag()
        engine.beforeRender = { tick in
            if tick.rawValue == 120 { MallocProbe.start(); counting.value = true }
        }
        engine.afterRender = { tick, _ in
            if counting.value, tick.rawValue == 120 + Int64(seconds * 60) { MallocProbe.stop(); counting.value = false }
        }
        engine.run(seconds: seconds + 3)
        MallocProbe.stop()
        renderer.shutdown()
        let list = MallocProbe.attributions()
        let own = list.filter(\.isOwn)
        let hist = MallocProbe.histogram(list)
        let frames = Int(seconds * 60)
        print("T1：\(frames) 帧内渲染线程共 \(list.count) 次分配（每帧 \(String(format: "%.2f", Double(list.count) / Double(frames)))），其中 SwitcherRender 代码直接引发 \(own.count) 次")
        for (k, v) in hist.prefix(15) { print("   \(v)x  \(k)") }
        for a in own.prefix(5) { print("   自己的分配：\(a.stack.prefix(8).joined(separator: " <- "))") }
        XCTAssertEqual(own.count, 0, "渲染线程上 SwitcherRender 代码不许分配")
        print("T1：纹理表共建了 \(renderer.textureCreateCount) 张纹理（预热期），输出环退回池子 \(renderer.outputFallbackCount) 次")
        XCTAssertEqual(renderer.outputFallbackCount, 0, "输出环不该退回池子分配")
        XCTAssertEqual(engine.skipped.load(ordering: .relaxed), 0)
    }

    /// T3：GPU 压不住时 render 返回 .skipped 而不是等；在途永远 ≤ 2。用 4K + 16 路 + 4 overlay + 超高频调用制造压力。
    func testT3_cpuNeverLeadsGPUByMoreThanTwoFrames() throws {
        var options = MetalRendererOptions()
        options.maxInflight = 2
        let renderer = try MetalRenderer(options: options)
        try renderer.prepare(format: .uhd2160p30, maxInputs: 17)
        let inputs = FakeInputs.nv12(count: 16, width: 1920, height: 1080, poolDepth: 2)
        var state = LoadStates.eightInputsFourOverlays()
        state.inputs = ReferenceStates.inputs(count: 16)
        state.format = .uhd2160p30
        let table = RenderInputTable(capacity: 17)
        for i in inputs {
            table[inputNumber: i.number] = Frame(pixelBuffer: i.buffers[0], pts: .zero, duration: .zero, color: .bt709Limited, inputNumber: i.number, sequence: 0, ingressTime: .zero)
        }
        let snap = MixerSnapshot(state: state, sequence: 1, tick: .zero)
        let sink = CollectingSink()
        renderer.sink = sink
        var maxInflight = 0
        var submitted = 0, skipped = 0
        // 不等拍点，尽可能快地调 2000 次
        for i in 0..<2000 {
            let v = renderer.render(tick: Tick(Int64(i)), at: HostClock.now(), snapshot: snap, inputs: table)
            maxInflight = max(maxInflight, renderer.inflight.load(ordering: .acquiring))
            if v == .submitted { submitted += 1 } else { skipped += 1 }
        }
        renderer.shutdown()
        print("T3：提交 \(submitted)，跳过 \(skipped)，观察到的最大在途 \(maxInflight)，完成 \(sink.count)")
        XCTAssertLessThanOrEqual(maxInflight, 2)
        XCTAssertGreaterThan(skipped, 0, "全速调用时应该出现 .skipped（否则说明 GPU 比 CPU 编码还快，测试没制造出压力）")
        XCTAssertEqual(sink.count, submitted, "每个提交的帧都要有完成回调")
    }

    /// 离线渲染与实时路径共用同一函数：同一状态、同一输入，实时路径交给编码器的 NV12 与离线的 NV12 逐字节相同，
    /// PGM 纹理逐像素相同。
    func testOffline_matchesRealtimeBitExact() throws {
        let state = ReferenceStates.fixed()
        let buffers = TestImages.referenceBuffers()
        // 实时
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd1080p60, maxInputs: 5)
        let sink = CollectingSink()
        sink.holdDepth = 4
        renderer.sink = sink
        let table = RenderInputTable(capacity: 5)
        for (n, pb) in buffers {
            table[inputNumber: n] = Frame(pixelBuffer: pb, pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: n, sequence: 0, ingressTime: .zero)
        }
        let snap = MixerSnapshot(state: state, sequence: 1, tick: .zero)
        // 标签线程要一点时间把名字画出来；先渲染几帧等它
        for i in 0..<30 {
            _ = renderer.render(tick: Tick(Int64(i)), at: HostClock.now(), snapshot: snap, inputs: table)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)
        var last: RenderedFrame?
        for i in 30..<33 {
            let v = renderer.render(tick: Tick(Int64(i)), at: HostClock.now(), snapshot: snap, inputs: table)
            XCTAssertEqual(v, .submitted)
            Thread.sleep(forTimeInterval: 0.05)
            last = sink.frames.last
        }
        guard let realtime = last else { return XCTFail("没有完成的帧") }
        // 实时的 PGM 纹理读回
        let display = renderer.latestDisplayFrame(for: .program)!
        let realtimeProgram = try readback(display.texture, device: renderer.device)
        renderer.shutdown()
        // 离线
        let offline = try OfflineRenderer().render(state: state, pixelBuffers: buffers, size: CGSize(width: 1920, height: 1080))
        let a = PixelBuffers.nv12Planes(realtime.program.pixelBuffer), b = PixelBuffers.nv12Planes(offline.programNV12)
        XCTAssertEqual(a.luma, b.luma, "实时与离线的 NV12 亮度平面必须逐字节相同")
        XCTAssertEqual(a.chroma, b.chroma, "实时与离线的 NV12 色度平面必须逐字节相同")
        let offlineProgram = Bitmap(offline.program)
        XCTAssertEqual(realtimeProgram, offlineProgram.bgra, "实时与离线的 PGM 纹理必须逐像素相同")
        XCTAssertEqual(realtime.program.inputNumber, 0)
        XCTAssertEqual(realtime.program.pixelFormat, .nv12)
        XCTAssertEqual(realtime.program.color, .bt709Limited)
    }

    /// 输出环：消费者拿着的缓冲不会被再次发出；放掉后才复用；全占时退回池子而不是覆盖。
    func testOutputRing_neverHandsOutHeldBuffer() throws {
        let ring = try OutputBufferRing(width: 64, height: 32, count: 3)
        var held: [CVPixelBuffer] = []
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<3 {
            let pb = try XCTUnwrap(ring.next())
            XCTAssertTrue(seen.insert(ObjectIdentifier(pb)).inserted, "同一个缓冲被发了两次")
            held.append(pb)
        }
        XCTAssertEqual(ring.fallbackCount, 0)
        let extra = try XCTUnwrap(ring.next())
        XCTAssertFalse(seen.contains(ObjectIdentifier(extra)), "全被占着时不许把在用的缓冲再发出去")
        XCTAssertEqual(ring.fallbackCount, 1)
        held.removeFirst()
        let reused = try XCTUnwrap(ring.next())
        XCTAssertTrue(seen.contains(ObjectIdentifier(reused)), "放掉的缓冲应被复用")
        XCTAssertEqual(ring.fallbackCount, 1)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(reused), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(reused))
        _ = held
        _ = extra
    }

    /// 完成回调里的时间戳：gpuEnd ≥ gpuStart ≥ submitTime 附近、tickTime 原样带回、renderMs = gpuEnd − tickTime。
    func testRenderedFrame_timestampsAreHostTime() throws {
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd720p60, maxInputs: 2)
        let sink = CollectingSink()
        renderer.sink = sink
        let table = RenderInputTable(capacity: 2)
        table[inputNumber: 1] = Frame(pixelBuffer: TestImages.grayBuffer(level: 100, width: 1280, height: 720), pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: 1, sequence: 0, ingressTime: .zero)
        let snap = MixerSnapshot(state: MixerState(format: .hd720p60, inputs: ReferenceStates.inputs(count: 1), program: 1), sequence: 1, tick: .zero)
        let t = HostClock.now()
        XCTAssertEqual(renderer.render(tick: Tick(7), at: t, snapshot: snap, inputs: table), .submitted)
        Thread.sleep(forTimeInterval: 0.2)
        renderer.shutdown()
        let f = try XCTUnwrap(sink.frames.first)
        XCTAssertEqual(f.tick, Tick(7))
        XCTAssertEqual(f.tickTime, t)
        XCTAssertGreaterThanOrEqual(f.gpuEnd, f.gpuStart)
        XCTAssertGreaterThanOrEqual(f.gpuStart.ticks, t.ticks, "GPU 开始时刻应晚于拍点")
        XCTAssertLessThan((f.gpuEnd - t).milliseconds, 100)
        XCTAssertEqual(f.renderMs, (f.gpuEnd - t).milliseconds, accuracy: 0.001)
        XCTAssertEqual(f.program.pts, t, "编码 PTS 用拍点时刻（决策 10）")
        XCTAssertNil(f.preview)
        XCTAssertNil(f.multiview)
    }

    /// 快照里 program 变了，下一帧就生效（Cut 原子换号；渲染器不缓存旧状态）。
    func testV6_programChangeTakesEffectNextFrame() throws {
        let renderer = try MetalRenderer()
        try renderer.prepare(format: .hd720p60, maxInputs: 3)
        let sink = CollectingSink()
        renderer.sink = sink
        let table = RenderInputTable(capacity: 3)
        table[inputNumber: 1] = Frame(pixelBuffer: TestImages.grayBuffer(level: 64, width: 1280, height: 720), pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: 1, sequence: 0, ingressTime: .zero)
        table[inputNumber: 2] = Frame(pixelBuffer: TestImages.grayBuffer(level: 192, width: 1280, height: 720), pts: .zero, duration: .zero, color: .sRGBFull, inputNumber: 2, sequence: 0, ingressTime: .zero)
        var state = MixerState(format: .hd720p60, inputs: ReferenceStates.inputs(count: 2), program: 1, preview: 2)
        state.transition = TransitionState(type: .cut, durationTicks: 0)
        for i in 0..<4 {
            if i == 2 { state.program = 2; state.preview = 1 }
            _ = renderer.render(tick: Tick(Int64(i)), at: HostClock.now(), snapshot: MixerSnapshot(state: state, sequence: UInt64(i), tick: Tick(Int64(i))), inputs: table)
            Thread.sleep(forTimeInterval: 0.05)
        }
        renderer.shutdown()
        XCTAssertEqual(sink.frames.count, 4)
        let lumas = sink.frames.map { Int(PixelBuffers.nv12Luma($0.program.pixelBuffer, x: 640, y: 360)) }
        // 灰 64 → Y 71，灰 192 → Y 181（P1 报告里的换算）
        XCTAssertEqual(lumas, [71, 71, 181, 181], "第 2 拍换号后第 2 帧起必须是新输入，且没有混合帧")
    }

    private func readback(_ texture: any MTLTexture, device: any MTLDevice) throws -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = .shaderRead
        let staging = try XCTUnwrap(device.makeTexture(descriptor: d))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, to: staging)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            staging.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }
}
