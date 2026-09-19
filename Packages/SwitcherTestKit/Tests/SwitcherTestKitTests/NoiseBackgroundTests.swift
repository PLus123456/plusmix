import XCTest
import CoreVideo
import Darwin
import SwitcherContracts
import SwitcherOutputs
import Synchronization
@testable import SwitcherTestKit

/// 噪声底纹（提案 006，prompt 44 交付 1）：解码器对加噪帧的帧号 / ID / 闪光判读 100% 正确、中心均值 = level ± 1（V6 / V7 不受影响）、
/// GPU 版与契约 CPU 参考实现逐像素相同、每帧成本；E2 用例（1080p60 H.264 6 Mbps 录 60 s 平均码率 ≥ 设定的 80%）在 `testE2_*`。
final class NoiseBackgroundTests: XCTestCase {
    static let noise = TestPattern.Background.noise(level: 128, amplitude: 24, seed: 7)

    func makeBuffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        let pool = try NV12PixelBufferPool(width: w, height: h, maximumBuffers: 2)
        return pool.take()!
    }

    func planeBytes(_ pb: CVPixelBuffer, plane: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!, bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let rows = CVPixelBufferGetHeightOfPlane(pb, plane), width = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2)
        var out: [UInt8] = []
        out.reserveCapacity(rows * width)
        for y in 0..<rows { out.append(contentsOf: UnsafeBufferPointer(start: (base + y * bpr).assumingMemoryBound(to: UInt8.self), count: width)) }
        return out
    }

    // MARK: 解码正确性（CPU 参考实现 + GPU）

    /// 加噪帧（振幅 24；V7 的 64 / 192 也配 24）逐帧解码：帧号 / ID / 闪光 100% 对；中心 1/4 区域均值 = level ± 1。
    func testW1A2_noise_decodeIsExact_andCenterMeanIsLevel() throws {
        let pb = try makeBuffer(1920, 1080)
        let renderer = try? NoisePatternRenderer()
        var worst = 0.0
        for (level, amplitude) in [(UInt8(128), UInt8(24)), (64, 24), (192, 24), (128, 63)] {
            for useGPU in [false, true] {
                if useGPU && renderer == nil { continue }
                for i in 0..<40 {
                    let n = UInt32(i * 37 + 3)
                    let c = TestPattern.Content(frameNumber: n, hostTimeMs: n * 16 + 1000, inputID: Int(n % 16), flash: i % 5 == 0,
                                                background: .noise(level: level, amplitude: amplitude, seed: UInt64(i)))
                    if useGPU { XCTAssertTrue(renderer!.draw(c, into: pb)) } else { TestPattern.draw(c, into: pb) }
                    let d = try XCTUnwrap(TestPattern.decode(pixelBuffer: pb))
                    XCTAssertEqual(d.frameNumber, n, "GPU \(useGPU) level \(level) 帧 \(i)")
                    XCTAssertEqual(d.hostTimeMs, (n * 16 + 1000) & TestPattern.dataMask)
                    XCTAssertEqual(d.inputID, Int(n % 16))
                    XCTAssertEqual(d.flash, i % 5 == 0)
                    let gray = MediaReader.grayLevel(of: pb)
                    worst = max(worst, abs(gray - Double(level)))
                    XCTAssertEqual(gray, Double(level), accuracy: 1.0, "GPU \(useGPU) level \(level) 振幅 \(amplitude) 帧 \(i) 中心均值 \(gray)")
                }
            }
        }
        print("[W1-A2] 噪声帧中心均值离 level 最远 \(String(format: "%.3f", worst))（阈值 1）")
    }

    /// GPU 版整幅（亮度 + 色度）与 `TestPattern.draw` 逐字节相同：几个尺寸、几个种子 / 帧号 / ID / 闪光、包括边界 (0, 0)、(w−1, h−1) 与四样覆盖物区域。
    func testW1A2_noiseGPU_matchesContractDrawPixelExact() throws {
        let renderer = try NoisePatternRenderer()
        for (w, h) in [(1920, 1080), (1280, 720), (640, 360), (322, 180)] {
            let gpu = try makeBuffer(w, h), cpu = try makeBuffer(w, h)
            for (k, seed) in [UInt64(7), 0, UInt64.max, 12345].enumerated() {
                let n = UInt32(k * 1001)
                let c = TestPattern.Content(frameNumber: n, hostTimeMs: 0x0FFF_FFFF - n, inputID: (k * 5) % 16, flash: k % 2 == 0,
                                            background: .noise(level: k == 3 ? 250 : 128, amplitude: k == 2 ? 63 : 24, seed: seed))
                TestPattern.draw(c, into: cpu)
                XCTAssertTrue(renderer.draw(c, into: gpu))
                let (la, lb) = (planeBytes(gpu, plane: 0), planeBytes(cpu, plane: 0))
                let (ca, cb) = (planeBytes(gpu, plane: 1), planeBytes(cpu, plane: 1))
                XCTAssertEqual(la.count, w * h)
                if la != lb {
                    let first = zip(la, lb).enumerated().first { $0.element.0 != $0.element.1 }!
                    XCTFail("\(w)×\(h) seed \(seed) 亮度第一个不同在 (\(first.offset % w), \(first.offset / w))：GPU \(first.element.0) vs CPU \(first.element.1)，共 \(zip(la, lb).filter { $0 != $1 }.count) 处")
                }
                XCTAssertEqual(ca, cb, "\(w)×\(h) seed \(seed) 色度平面不同")
                // 参考定义抽查（噪声区一个像素）
                let y = h / 2, x = w - 1
                let ref = TestPattern.noiseValue(level: k == 3 ? 250 : 128, amplitude: k == 2 ? 63 : 24, seed: seed, frameNumber: n, x: x, y: y)
                XCTAssertEqual(la[y * w + x], UInt8((16 + 219 * Double(ref) / 255).rounded()))
            }
        }
        // 非噪声底色 / 非 NV12 缓冲：返回 false，调用方退回 CPU
        let bgra = { () -> CVPixelBuffer in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
            return pb!
        }()
        XCTAssertFalse(renderer.draw(TestPattern.Content(frameNumber: 1, hostTimeMs: 1, inputID: 0, flash: false, background: .gray(level: 128)), into: try makeBuffer(640, 360)))
        XCTAssertFalse(renderer.draw(TestPattern.Content(frameNumber: 1, hostTimeMs: 1, inputID: 0, flash: false, background: Self.noise), into: bgra))
    }

    /// 每帧成本（报告用；release 数字用 `swift test -c release --filter NoiseBackgroundTests/testW1A2_noise_costPerFrame`）：
    /// CPU 参考实现的线程 CPU 时间、GPU 版的 GPU 忙 / 线程 CPU / 墙钟，背靠背与 60 fps 节奏各一组。
    func testW1A2_noise_costPerFrame() throws {
        let pb = try makeBuffer(1920, 1080)
        let renderer = try NoisePatternRenderer()
        try renderer.prepare(pb)
        func content(_ i: Int, _ bg: TestPattern.Background) -> TestPattern.Content {
            TestPattern.Content(frameNumber: UInt32(i), hostTimeMs: UInt32(i * 16), inputID: 3, flash: i % 60 == 0, background: bg)
        }
        func measure(_ label: String, frames: Int, paced: Bool, _ body: (Int) -> Void) -> (cpuMs: Double, wallMs: Double) {
            var cpu: UInt64 = 0, wall: UInt64 = 0
            let warm = 10
            for i in 0..<(frames + warm) {
                let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), w0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                body(i)
                let c1 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), w1 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                if i >= warm { cpu += c1 - c0; wall += w1 - w0 }
                if paced { usleep(16_000) }
            }
            let r = (Double(cpu) / Double(frames) / 1e6, Double(wall) / Double(frames) / 1e6)
            print("[W1-A2] \(label)：线程 CPU \(String(format: "%.3f", r.0)) ms/帧，墙钟 \(String(format: "%.3f", r.1)) ms/帧")
            return r
        }
        _ = measure("灰底 CPU 背靠背", frames: 60, paced: false) { TestPattern.draw(content($0, .gray(level: 128)), into: pb) }
        let cpuBack = measure("噪声 CPU 参考实现 背靠背", frames: 60, paced: false) { TestPattern.draw(content($0, Self.noise), into: pb) }
        var gpuBusy: UInt64 = 0
        let gpuBack = measure("噪声 GPU 背靠背", frames: 60, paced: false) { renderer.draw(content($0, Self.noise), into: pb); gpuBusy += renderer.lastCost.gpuNanoseconds }
        print("[W1-A2] 噪声 GPU 背靠背：GPU 忙 \(String(format: "%.3f", Double(gpuBusy) / 70 / 1e6)) ms/帧")
        let cpuPaced = measure("噪声 CPU 参考实现 60 fps 节奏", frames: 30, paced: true) { TestPattern.draw(content($0, Self.noise), into: pb) }
        gpuBusy = 0
        let gpuPaced = measure("噪声 GPU 60 fps 节奏", frames: 30, paced: true) { renderer.draw(content($0, Self.noise), into: pb); gpuBusy += renderer.lastCost.gpuNanoseconds }
        print("[W1-A2] 噪声 GPU 60 fps 节奏：GPU 忙 \(String(format: "%.3f", Double(gpuBusy) / 40 / 1e6)) ms/帧")
        // 只拦数量级：GPU 路径的线程 CPU 时间必须明显低于 CPU 参考实现（debug 构建两边都慢，比值仍成立）
        XCTAssertLessThan(gpuBack.cpuMs, cpuBack.cpuMs / 2, "GPU 路径线程 CPU \(gpuBack.cpuMs) 应远小于 CPU 参考 \(cpuBack.cpuMs)")
        XCTAssertLessThan(gpuPaced.cpuMs, cpuPaced.cpuMs / 2)
    }

    // MARK: 实跑

    /// 合成源真跑线程、噪声在 GPU 上画：1080p60 3 s 每帧都解得出、帧号连续、late 0；打印每帧成本三项。
    func testW1A2_syntheticVideo_noiseGPU_3s_allFramesDecodable() throws {
        let settings = SyntheticSourceSettings(frameRate: .fps60, width: 1920, height: 1080, background: Self.noise, audio: false)
        let slot = TestKitFrameSlot(capacity: 3)
        let decoded = Mutex<[(UInt64, TestPattern.Decoded?, Double)]>([])
        slot.onPush = { f in
            let d = TestPattern.decode(pixelBuffer: f.pixelBuffer)
            decoded.withLock { $0.append((f.sequence, d, MediaReader.grayLevel(of: f.pixelBuffer))) }
        }
        let timeline = SyntheticTimeline.startingSoon(frameRate: .fps60, leadMilliseconds: 50)
        let input = try SyntheticVideoInput(number: 4, settings: settings, videoSlot: slot, timeline: timeline)
        XCTAssertTrue(input.usesGPUNoise)
        try input.start()
        RealtimeThread.wait(until: timeline.t0 + HostDuration(seconds: 3) - HostDuration(milliseconds: 8))
        input.stop()
        let all = decoded.withLock { $0 }
        let c = input.counters
        XCTAssertTrue(abs(all.count - 180) <= 1, "pushed \(all.count)")
        XCTAssertEqual(c.poolStarved, 0); XCTAssertEqual(c.late, 0)
        for (i, r) in all.enumerated() {
            XCTAssertEqual(r.0, UInt64(i))
            XCTAssertEqual(r.1?.frameNumber, UInt32(i)); XCTAssertEqual(r.1?.inputID, 3); XCTAssertEqual(r.1?.flash, i % 60 == 0)
            XCTAssertEqual(r.2, 128, accuracy: 1.0)
        }
        print("[W1-A2] 1080p60 噪声 GPU 3 s：画帧墙钟 \(String(format: "%.3f", c.meanDrawMs)) ms、线程 CPU \(String(format: "%.3f", c.meanDrawCPUMs)) ms、GPU 忙 \(String(format: "%.3f", c.meanGPUBusyMs)) ms；唤醒延迟平均 \(String(format: "%.3f", c.meanWakeLatencyMs)) ms")
        // 强制 CPU：同样解得出（对照，1 s 就够；360p——debug 构建下 CPU 参考实现 1080p 一帧 48 ms，跟不上 60 fps）
        let cpuSettings = SyntheticSourceSettings(frameRate: .fps60, width: 640, height: 360, background: Self.noise, audio: false)
        let slot2 = TestKitFrameSlot(capacity: 3)
        let count2 = Mutex<Int>(0)
        slot2.onPush = { f in
            let d = TestPattern.decode(pixelBuffer: f.pixelBuffer)
            if d?.frameNumber == UInt32(f.sequence) && d?.inputID == 3 { count2.withLock { $0 += 1 } }
        }
        let tl2 = SyntheticTimeline.startingSoon(frameRate: .fps60, leadMilliseconds: 50)
        let cpuInput = try SyntheticVideoInput(number: 4, settings: cpuSettings, videoSlot: slot2, timeline: tl2, noise: .cpu)
        XCTAssertFalse(cpuInput.usesGPUNoise)
        try cpuInput.start()
        RealtimeThread.wait(until: tl2.t0 + HostDuration(seconds: 1) - HostDuration(milliseconds: 8))
        cpuInput.stop()
        XCTAssertEqual(count2.withLock { $0 }, Int(cpuInput.counters.generated))
        XCTAssertTrue(abs(Int(cpuInput.counters.generated) - 60) <= 1)
        print("[W1-A2] 360p60 噪声 CPU 1 s：画帧墙钟 \(String(format: "%.3f", cpuInput.counters.meanDrawMs)) ms、线程 CPU \(String(format: "%.3f", cpuInput.counters.meanDrawCPUMs)) ms")
    }

    // MARK: E2

    /// E2 在 L2 长跑里有可判对象的前提：噪声底纹的合成源经 W1-E 录制器（真 VideoToolbox，实时模式）1080p60 H.264 6 Mbps 录 60 s，
    /// 平均码率 ≥ 设定的 80%（灰底只有 0.1 Mbps）；录出来的文件每帧帧号 / ID / 闪光仍 100% 可解。`SW_E2_SECONDS` 可缩短（开发用）。
    func testE2_noiseSource_1080p60_6Mbps_60s_averageBitrateAtLeast80pct() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["SW_E2_SECONDS"] ?? "") ?? 60
        let bitrate = 6_000_000
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w1a2-e2-noise-\(getpid()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = ProgramFormat(width: 1920, height: 1080, frameRate: .fps60)
        let recorder = Recorder(configuration: Recorder.Configuration(url: url, format: format,
                                                                     video: VideoEncodeSettings(codec: .h264, bitrateBps: bitrate, keyframeIntervalFrames: 120),
                                                                     audio: nil, name: "e2-noise"))
        let settings = SyntheticSourceSettings(frameRate: .fps60, width: 1920, height: 1080, background: Self.noise, audio: false)
        let slot = TestKitFrameSlot(capacity: 3)
        let timeline = SyntheticTimeline.startingSoon(frameRate: .fps60, leadMilliseconds: 300)
        let clock = timeline.videoClock(driftPpm: 0)
        let total = Int64((seconds * 60).rounded())
        let fed = Atomic<Int64>(0)
        slot.onPush = { f in
            let n = Int64(f.sequence)
            guard n < total else { return }
            let t = clock.time(of: Tick(n))
            recorder.consume(RenderedFrame(tick: Tick(n), tickTime: t, program: f, submitTime: t, gpuStart: t, gpuEnd: t))
            fed.store(n + 1, ordering: .relaxed)
        }
        let input = try SyntheticVideoInput(number: 1, settings: settings, videoSlot: slot, timeline: timeline)
        XCTAssertTrue(input.usesGPUNoise)
        try recorder.start(at: RecordingStart(tick: .zero, tickTime: timeline.t0))
        try input.start()
        RealtimeThread.wait(until: clock.time(of: Tick(total)) + HostDuration(milliseconds: 50))
        input.stop()
        let result: RecordingResult = try await withCheckedThrowingContinuation { cont in
            recorder.stop(atTick: Tick(total)) { cont.resume(with: $0) }
        }
        let c = input.counters
        let avgBps = Double(result.videoBytes) * 8 / result.durationSeconds
        print("[W1-A2 E2] \(seconds) s 1080p60 噪声 GPU → 录制器 6 Mbps：\(result.videoFrames) 帧 \(result.videoBytes) 字节，平均 \(String(format: "%.3f", avgBps / 1e6)) Mbps（\(String(format: "%.1f", avgBps / Double(bitrate) * 100))% 设定）；合成源 late \(c.late) 饿 \(c.poolStarved)，画帧墙钟 \(String(format: "%.3f", c.meanDrawMs)) / CPU \(String(format: "%.3f", c.meanDrawCPUMs)) / GPU \(String(format: "%.3f", c.meanGPUBusyMs)) ms；编码器 \(recorder.encoder.counters)")
        XCTAssertGreaterThanOrEqual(result.videoFrames, UInt64(total - 2))
        XCTAssertGreaterThanOrEqual(avgBps, Double(bitrate) * 0.8, "E2：平均码率 \(avgBps / 1e6) Mbps 不到设定 6 Mbps 的 80%")
        // 录出来的加噪帧 100% 可解（V4 / V5 / V6 / A2 的读数不受噪声影响）
        let v = try await MediaReader.readVideo(url: url)
        let undecodable = v.frames.filter { $0.frameNumber == nil || $0.inputID != 0 }
        XCTAssertEqual(undecodable.count, 0, "录制文件里 \(undecodable.count) / \(v.frames.count) 帧解不出（前几个：\(undecodable.prefix(5).map(\.index))）")
        let stats = FrameAnalysis.stats(frames: v.frames, programFps: 60, inputFps: [0: 60])
        XCTAssertEqual(stats.inputs.first?.droppedFrames, 0); XCTAssertEqual(stats.inputs.first?.duplicateFrames, 0)
        XCTAssertEqual(v.frames.filter(\.flash).count, Int(seconds.rounded()), "闪光帧数")
        for f in v.frames.prefix(300) { XCTAssertEqual(f.gray, 128, accuracy: 2.0, "帧 \(f.index) 中心均值 \(f.gray)（经 H.264）") }
    }
}
