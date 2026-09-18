import CoreVideo
import Foundation
import Metal
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherNDISend

/// NDI 发送：SDK 不在（本机）时只能测转换器、队列与空实现；有 SDK 时 Studio Monitor 人工验证（报告）。
final class NDISendTests: XCTestCase {
    /// 造一帧 NV12：Y(x, y) = (x + y) & 255，Cb(cx, cy) = cx & 255，Cr = cy & 255。
    private func makeNV12(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw NSError(domain: "test", code: 1) }
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<height { for col in 0..<width { y[row * ys + col] = UInt8((col + row) & 255) } }
        for row in 0..<(height / 2) {
            for col in 0..<(width / 2) {
                c[row * cs + col * 2] = UInt8(col & 255)
                c[row * cs + col * 2 + 1] = UInt8(row & 255)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func expectedUYVY(x: Int, y: Int) -> (cb: UInt8, y0: UInt8, cr: UInt8, y1: UInt8) {
        (UInt8((x / 2) & 255), UInt8((x + y) & 255), UInt8((y / 2) & 255), UInt8((x + 1 + y) & 255))
    }

    func testNV12ToUYVY_cpuMatchesFormula() throws {
        let (w, h) = (64, 32)
        let pb = try makeNV12(width: w, height: h)
        let mem = UnsafeMutableRawPointer.allocate(byteCount: w * h * 2, alignment: 16)
        defer { mem.deallocate() }
        let out = NV12ToUYVY.UYVYBuffer(width: w, height: h, base: mem)
        try NV12ToUYVY.convertCPU(pb, into: out)
        let p = mem.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: 0, to: h, by: 3) {
            for x in stride(from: 0, to: w, by: 2) {
                let e = expectedUYVY(x: x, y: y)
                let o = y * out.bytesPerRow + x * 2
                XCTAssertEqual([p[o], p[o + 1], p[o + 2], p[o + 3]], [e.cb, e.y0, e.cr, e.y1], "(\(x), \(y))")
            }
        }
    }

    func testNV12ToUYVY_gpuMatchesCPU_bytewise() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("BLOCKED-硬件：没有 Metal 设备") }
        let (w, h) = (1920, 1080)
        let gpu = try NV12ToUYVY.GPU(device: device, width: w, height: h)
        // 1. 公式帧
        let pb = try makeNV12(width: w, height: h)
        let cpuMem = UnsafeMutableRawPointer.allocate(byteCount: w * h * 2, alignment: 16)
        defer { cpuMem.deallocate() }
        let cpuOut = NV12ToUYVY.UYVYBuffer(width: w, height: h, base: cpuMem)
        try NV12ToUYVY.convertCPU(pb, into: cpuOut)
        let gpuOut = try gpu.convert(pb)
        XCTAssertEqual(memcmp(cpuOut.base, gpuOut.base, w * h * 2), 0, "GPU 与 CPU 输出逐字节相同（公式帧）")
        // 2. 测试图案帧（含噪声）
        let feeder = try PatternFeeder(configuration: .init(format: .hd1080p60, inputID: 5, texture: .noise(amplitude: 24, seed: 3)))
        let frame = try feeder.makeFrame(tick: Tick(7), tickTime: HostClock.now())
        try NV12ToUYVY.convertCPU(frame.program.pixelBuffer, into: cpuOut)
        let gpuOut2 = try gpu.convert(frame.program.pixelBuffer)
        XCTAssertEqual(memcmp(cpuOut.base, gpuOut2.base, w * h * 2), 0, "GPU 与 CPU 输出逐字节相同（图案帧）")
        // 3. 双缓冲：连续两次 convert 返回不同缓冲
        let a = try gpu.convert(pb).base
        let b = try gpu.convert(pb).base
        XCTAssertNotEqual(a, b)
    }

    /// 转换成本（报告用）：1080p 各 60 帧的每帧耗时。
    func testConversionCost_1080p_report() throws {
        let (w, h) = (1920, 1080)
        let feeder = try PatternFeeder(configuration: .init(format: .hd1080p60, inputID: 2, texture: .noise(amplitude: 24, seed: 1)))
        let frames = try (0..<8).map { try feeder.makeFrame(tick: Tick(Int64($0)), tickTime: HostClock.now()).program.pixelBuffer }
        let mem = UnsafeMutableRawPointer.allocate(byteCount: w * h * 2, alignment: 64)
        defer { mem.deallocate() }
        let out = NV12ToUYVY.UYVYBuffer(width: w, height: h, base: mem)
        var cpuMs: [Double] = []
        for i in 0..<60 {
            let t = HostClock.now()
            try NV12ToUYVY.convertCPU(frames[i % frames.count], into: out)
            cpuMs.append((HostClock.now() - t).milliseconds)
        }
        cpuMs.sort()
        print("NV12→UYVY CPU 1080p：p50 \(String(format: "%.2f", cpuMs[30])) ms，max \(String(format: "%.2f", cpuMs[59])) ms")
        if let device = MTLCreateSystemDefaultDevice() {
            let gpu = try NV12ToUYVY.GPU(device: device, width: w, height: h)
            var gpuMs: [Double] = []
            for i in 0..<60 {
                let t = HostClock.now()
                _ = try gpu.convert(frames[i % frames.count])
                gpuMs.append((HostClock.now() - t).milliseconds)
            }
            gpuMs.sort()
            print("NV12→UYVY GPU 1080p（含等待完成）：p50 \(String(format: "%.2f", gpuMs[30])) ms，max \(String(format: "%.2f", gpuMs[59])) ms（首帧 \(String(format: "%.2f", gpuMs.last!)) ms 含编译）")
        }
        XCTAssertLessThan(cpuMs[30], 20, "CPU 转换 p50 应远小于一帧")
    }

    /// SDK 不在：start 不抛、空实现、unavailable = true、帧照收不计 skipped。
    func testUnavailableWithoutSDK_emptyImplementation() throws {
        if NDISender.isAvailable { throw XCTSkip("本机有 NDI SDK，走真发送的测试") }
        let sender = NDISender(configuration: .init(name: "Switcher PGM", format: .hd720p60))
        XCTAssertTrue(sender.countersSnapshot.unavailable)
        try sender.start()
        XCTAssertTrue(sender.isRunning)
        let feeder = try PatternFeeder(configuration: .init(format: .hd720p60))
        for i in 0..<10 { sender.consume(try feeder.makeFrame(tick: Tick(Int64(i)), tickTime: HostClock.now())) }
        let c = sender.countersSnapshot
        XCTAssertTrue(c.unavailable)
        XCTAssertEqual(c.framesReceived, 10)
        XCTAssertEqual(c.framesSent, 0)
        XCTAssertEqual(c.skipped, 0)
        let entry = sender.statsEntry(previous: nil, windowSeconds: 1)
        XCTAssertEqual(entry.skipped, 0)
        XCTAssertEqual(entry.bitrate, 0)
        sender.stop()
        XCTAssertFalse(sender.isRunning)
    }

    /// 转换方式可选：gpu / cpu 立即生效、运行时可切；`OutputSettings.extra["ndi.conversion"]` 解析。
    func testConversionSelectable_runtimeSwitchAndExtraKey() throws {
        typealias Conversion = NDISender.Configuration.Conversion
        XCTAssertEqual(Conversion(extra: [:]), .auto)
        XCTAssertEqual(Conversion(extra: ["ndi.conversion": "cpu"]), .cpu)
        XCTAssertEqual(Conversion(extra: ["ndi.conversion": "GPU"]), .gpu)
        XCTAssertEqual(Conversion(extra: ["ndi.conversion": "whatever"]), .auto)
        XCTAssertEqual(Conversion(extra: ["ndi.conversion": 1]), .auto)
        XCTAssertEqual(Conversion.extraKey, "ndi.conversion")

        let hasMetal = MTLCreateSystemDefaultDevice() != nil
        let sender = NDISender(configuration: .init(name: "sel", format: .hd720p60, conversion: .gpu, dryRun: true))
        try sender.start()
        let feeder = try PatternFeeder(configuration: .init(format: .hd720p60))
        func feed(_ n: Int) throws {
            for i in 0..<n {
                sender.consume(try feeder.makeFrame(tick: Tick(Int64(i)), tickTime: HostClock.now()))
                Thread.sleep(forTimeInterval: 0.005)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try feed(10)
        XCTAssertEqual(sender.countersSnapshot.usingGPU, hasMetal, "gpu 模式：有 Metal 就用 GPU")
        XCTAssertEqual(sender.countersSnapshot.conversion, "gpu")
        sender.setConversion(.cpu)
        try feed(10)
        XCTAssertFalse(sender.countersSnapshot.usingGPU, "运行时切到 cpu 下一帧生效")
        XCTAssertEqual(sender.countersSnapshot.conversion, "cpu")
        sender.setConversion(.gpu)
        try feed(10)
        XCTAssertEqual(sender.countersSnapshot.usingGPU, hasMetal)
        sender.stop()
        let c = sender.countersSnapshot
        XCTAssertEqual(c.framesReceived, 30)
        XCTAssertEqual(c.framesReceived, c.framesSent + c.skipped)
        XCTAssertEqual(c.conversionFailures, 0)
    }

    /// auto：第一帧就探一次、之后每 autoProbeInterval 帧探一次（同一帧两种方法各转一次），用便宜的；探测值和当前选择自洽。
    func testAutoConversion_probesBothAndPicksCheaper() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("BLOCKED-硬件：没有 Metal 设备，auto 就是 cpu") }
        let sender = NDISender(configuration: .init(name: "auto", format: .hd1080p60, conversion: .auto, dryRun: true, autoProbeInterval: 20))
        try sender.start()
        let feeder = try PatternFeeder(configuration: .init(format: .hd1080p60, texture: .noise(amplitude: 12, seed: 2)))
        for i in 0..<100 {
            sender.consume(try feeder.makeFrame(tick: Tick(Int64(i)), tickTime: HostClock.now()))
            Thread.sleep(forTimeInterval: 0.008)
        }
        Thread.sleep(forTimeInterval: 0.2)
        sender.stop()
        let c = sender.countersSnapshot
        print("auto：\(c)")
        XCTAssertEqual(c.conversion, "auto")
        XCTAssertGreaterThan(c.lastCPUProbeMs, 0)
        XCTAssertGreaterThan(c.lastGPUProbeMs, 0)
        XCTAssertEqual(c.conversionFailures, 0)
        XCTAssertEqual(c.framesReceived, c.framesSent + c.skipped)
        // 自洽：便宜 30% 以上的那边就是当前选择（差距不到 30% 时保持原样，不断言）
        if c.lastCPUProbeMs < c.lastGPUProbeMs * 0.7 { XCTAssertFalse(c.usingGPU, "CPU 明显便宜应当在用 CPU：\(c)") }
        if c.lastGPUProbeMs < c.lastCPUProbeMs * 0.7 { XCTAssertTrue(c.usingGPU, "GPU 明显便宜应当在用 GPU：\(c)") }
    }

    /// 有 SDK 时真发：`SWITCHER_NDI_LIVE_SECONDS=20 swift test --filter NDISendTests/testLiveSend`，
    /// 用 NDI Tools 的 Studio Monitor 打开 "<机器名> (Switcher PGM test)"：左上角帧号块每帧在变、右上角闪光块每秒亮一次、1 kHz 正弦 + 每秒一声 click。
    /// SDK 不在或没设环境变量就 XCTSkip。结束打印送出帧数 / 跳帧 / 接收方数量（Studio Monitor 连着时 ≥ 1）。
    func testLiveSend_studioMonitor_manual() throws {
        guard NDISender.isAvailable else { throw XCTSkip("BLOCKED-SDK：没有 NDI SDK（/Library/NDI SDK for Apple）") }
        guard let secs = ProcessInfo.processInfo.environment["SWITCHER_NDI_LIVE_SECONDS"].flatMap(Double.init), secs > 0 else {
            throw XCTSkip("设 SWITCHER_NDI_LIVE_SECONDS=20 才真发（要有人看 Studio Monitor）")
        }
        let format = ProgramFormat.hd1080p60
        let sender = NDISender(configuration: .init(name: "Switcher PGM test", format: format))
        try sender.start()
        XCTAssertFalse(sender.countersSnapshot.unavailable)
        let feeder = try PatternFeeder(configuration: .init(format: format, inputID: 1))
        let t0 = HostClock.now() + HostDuration(milliseconds: 300)
        let clock = TickClockSpec(t0: t0, frameRate: format.frameRate)
        let signal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: format.frameRate))
        let signalFeeder = SignalFeeder(signal: signal)
        let ticks = Int(secs * Double(format.frameRate.nominalFramesPerSecond))
        let report = try feeder.feed(consumers: [sender], clock: clock, ticks: Tick.zero..<Tick(Int64(ticks)), pacing: .realTime) { _, tickTime in
            signalFeeder.feed(upTo: tickTime, to: [sender])
        }
        Thread.sleep(forTimeInterval: 0.2)
        sender.stop()
        let c = sender.countersSnapshot
        print("NDI 真发 \(secs) s：喂 \(report.framesFed) 帧（晚点 \(report.lateTicks)），\(c)")
        XCTAssertEqual(c.framesReceived, UInt64(report.framesFed))
        XCTAssertEqual(c.skipped, 0, "60 fps 实时喂不该跳帧")
        XCTAssertEqual(c.conversionFailures, 0)
        XCTAssertGreaterThan(c.audioBlocksSent, 0)
        if c.connections == 0 { print("提示：没有接收方连着（Studio Monitor 没开或没选这个源），画面没人看但发送本身没问题") }
    }

    /// 干跑：队列 + 转换线程真跑；consume 立即返回、满了丢最旧计 skipped、音频块进环；恒等式 收到 = 送出 + skipped。
    func testDryRunPipeline_boundedQueueAndCounters() throws {
        let sender = NDISender(configuration: .init(name: "dry", format: .hd1080p60, queueDepth: 2, dryRun: true))
        try sender.start()
        XCTAssertEqual(sender.countersSnapshot.unavailable, !NDISender.isAvailable, "干跑不改变 unavailable 的含义（= 有没有 SDK）")
        let feeder = try PatternFeeder(configuration: .init(format: .hd1080p60, texture: .noise(amplitude: 12, seed: 4)))
        var pushMs: [Double] = []
        // 尽快喂 240 帧（不等拍点）：GPU 转换 0.3 ms/帧比造帧还快，通常不丢；丢了也要满足恒等式
        for i in 0..<240 {
            let f = try feeder.makeFrame(tick: Tick(Int64(i)), tickTime: HostClock.now())
            let t = HostClock.now()
            sender.consume(f)
            pushMs.append((HostClock.now() - t).milliseconds)
        }
        // 音频
        let block = [Float](repeating: 0.1, count: 256)
        block.withUnsafeBufferPointer { p in
            var planes: [UnsafePointer<Float>] = [p.baseAddress!, p.baseAddress!]
            planes.withUnsafeMutableBufferPointer { pp in
                for _ in 0..<20 { sender.consumeAudio(planes: UnsafePointer(pp.baseAddress!), channelCount: 2, frameCount: 256, hostTime: HostClock.now()) }
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
        sender.stop()
        let c = sender.countersSnapshot
        print("干跑：\(c)")
        XCTAssertEqual(c.framesReceived, 240)
        XCTAssertEqual(c.framesReceived, c.framesSent + c.skipped, "收到 = 送出 + skipped（停止时队列已排空）")
        XCTAssertGreaterThan(c.framesSent, 0)
        XCTAssertEqual(c.audioBlocksSent, 20)
        XCTAssertEqual(c.conversionFailures, 0)
        pushMs.sort()
        XCTAssertLessThan(pushMs[Int(Double(pushMs.count) * 0.99)], 0.2, "consume p99 < 0.2 ms")
        XCTAssertGreaterThan(c.lastConvertMs, 0)
    }
}
