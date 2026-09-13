import CoreMedia
import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// E1 编码滞后跳帧（口径：有界队列满时丢的最旧帧）、编码延迟、VT 属性生效情况。
final class VideoEncoderTests: XCTestCase {
    let format = ProgramFormat.hd1080p60

    // MARK: E1 —— 计数精确等于理论值（可控后端，确定性）

    /// 消费者每放行一次才编一帧，生产者每轮 push 两帧（喂帧速率 2 倍）。
    /// 编码线程一有帧就从队列取走并卡在后端里（等放行），所以系统里最多容纳 D + 1 帧（队列 D + 后端 1）。
    /// 每轮净增 1 帧：前 D 轮在填满，从第 D + 1 轮起每轮挤掉 1 帧。理论值 skipped = rounds − D（rounds ≥ D）。
    func testE1_skippedCountIsExactWithGatedBackend() throws {
        for depth in [2, 3] {
            let backend = GatedBackend()
            let encoder = VideoEncoder(configuration: .init(name: "gated", format: format, settings: VideoEncodeSettings(), queueDepth: depth),
                                       backend: backend)
            try encoder.start()
            let feeder = try PatternFeeder(configuration: .init(format: .init(width: 640, height: 360, frameRate: .fps60)))
            let clock = TickClockSpec(t0: HostClock.now(), frameRate: .fps60)
            let rounds = 200
            var tick = Tick.zero
            for round in 0..<rounds {
                for _ in 0..<2 {
                    encoder.consume(try feeder.makeFrame(tick: tick, clock: clock))
                    tick += 1
                }
                backend.gate.signal()
                XCTAssertTrue(waitUntil(5) { backend.encodedCount == round + 1 }, "第 \(round) 轮没编出来")
            }
            let c = encoder.counters
            let theoretical = UInt64(rounds - depth)
            XCTAssertEqual(c.pushed, UInt64(rounds * 2))
            XCTAssertEqual(c.skipped, theoretical, "深度 \(depth)：skipped 应精确等于 rounds − D")
            // 放行了 rounds 次：rounds 帧已经过了后端，还有 1 帧卡在后端里（已 submitted）
            XCTAssertEqual(c.submitted, UInt64(rounds + 1))
            XCTAssertEqual(c.queueDepth, depth - 1)
            XCTAssertEqual(c.pushed, c.accountedFrames, "恒等式 pushed = submitted + skipped + 队列")
            // 被丢的永远是最旧的：编出来的 tick 序列严格递增
            let ticks = backend.encodedTicks
            XCTAssertEqual(ticks, ticks.sorted())
            XCTAssertEqual(Set(ticks).count, ticks.count)
            // 停止：放行剩下的
            for _ in 0..<depth { backend.gate.signal() }
            encoder.stop()
            XCTAssertEqual(encoder.counters.queueDepth, 0)
            XCTAssertEqual(encoder.counters.pushed, encoder.counters.accountedFrames)
            XCTAssertEqual(encoder.counters.submitted, UInt64(rounds + depth), "停止时把队列里剩的 D − 1 帧也编完")
        }
    }

    /// 生产者被完全堵住时 push N 帧：skipped = N − D，且每次 push 都立即返回。
    func testE1_producerNeverBlocksWhenConsumerStalls() throws {
        let backend = GatedBackend()
        let encoder = VideoEncoder(configuration: .init(name: "stalled", format: format, settings: VideoEncodeSettings(), queueDepth: 3), backend: backend)
        try encoder.start()
        let feeder = try PatternFeeder(configuration: .init(format: .init(width: 640, height: 360, frameRate: .fps60)))
        let clock = TickClockSpec(t0: HostClock.now(), frameRate: .fps60)
        var pushes: [HostDuration] = []
        let n = 1000
        for i in 0..<n {
            let f = try feeder.makeFrame(tick: Tick(Int64(i)), clock: clock)
            let t0 = HostClock.now()
            encoder.consume(f)
            pushes.append(HostClock.now() - t0)
        }
        let c = encoder.counters
        XCTAssertEqual(c.pushed, UInt64(n))
        XCTAssertEqual(c.skipped, UInt64(n - 3 - 1), "队列 3 帧 + 后端里卡着 1 帧，其余全丢")
        XCTAssertEqual(c.queueDepth, 3)
        XCTAssertEqual(c.submitted, 1)
        XCTAssertEqual(c.pushed, c.accountedFrames)
        let sorted = pushes.map { $0.milliseconds }.sorted()
        let p99 = sorted[Int(Double(n) * 0.99)]
        print("E1 堵死消费者：push p50 \(sorted[n / 2]) ms p99 \(p99) ms max \(sorted.last!) ms")
        XCTAssertLessThan(p99, 0.1, "push 耗时 p99 必须 < 0.1 ms")
        for _ in 0..<4 { backend.gate.signal() }
        encoder.stop()
    }

    // MARK: E1 —— 真编码器，喂帧速率 2 倍与 4 倍

    /// 1080p60 的帧按 2 倍（120 fps）实时喂给硬件 H.264 编码器 8 秒：恒等式成立，push p99 < 0.1 ms。
    /// M5 Max 的硬件编码器 1080p 吞吐约 170 fps，2 倍速通常跟得上（skipped 理论值 = 0 或很小）；4 倍速一定跟不上，看计数正确增长。
    func testE1_realEncoderOverfeed_accountingHoldsAndPushNeverBlocks() throws {
        for multiplier in [2, 4] {
            let encoder = VideoEncoder(configuration: .init(name: "overfeed\(multiplier)x", format: format,
                                                            settings: VideoEncodeSettings(codec: .h264, bitrateBps: 6_000_000)))
            try encoder.start()
            let feeder = try PatternFeeder(configuration: .init(format: format, texture: .noise(amplitude: 24, seed: 7)))
            // 喂的时钟按 60 × multiplier fps 走，帧的 PTS 仍按 60 fps 的拍点递增（编码器只关心单调）
            let seconds = 8
            let feedRate = FrameRate(Int64(60 * multiplier))
            let wallClock = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 200), frameRate: feedRate)
            let ptsClock = TickClockSpec(t0: wallClock.t0, frameRate: .fps60)
            let total = seconds * 60 * multiplier
            var pushes: [HostDuration] = []
            pushes.reserveCapacity(total)
            var late = 0
            for i in 0..<total {
                let wake = wallClock.time(of: Tick(Int64(i)))
                mach_wait_until(wake.ticks)
                if (HostClock.now() - wake).milliseconds > 1000.0 / Double(60 * multiplier) { late += 1 }
                let f = try feeder.makeFrame(tick: Tick(Int64(i)), clock: ptsClock)
                let t0 = HostClock.now()
                encoder.consume(f)
                pushes.append(HostClock.now() - t0)
            }
            encoder.stop()
            let c = encoder.counters
            let sorted = pushes.map { $0.milliseconds }.sorted()
            let p99 = sorted[Int(Double(total) * 0.99)]
            print("E1 真编码器 \(multiplier)×：pushed \(c.pushed) encoded \(c.encoded) skipped \(c.skipped) droppedByEncoder \(c.droppedByEncoder) failed \(c.failed); push p50 \(sorted[total / 2]) p99 \(p99) max \(sorted.last!) ms; 喂帧晚点 \(late) 次; 编码延迟 max \(c.maxLatency.milliseconds) ms")
            XCTAssertEqual(c.pushed, UInt64(total))
            XCTAssertEqual(c.queueDepth, 0)
            XCTAssertEqual(c.pushed, c.accountedFrames, "恒等式 pushed = submitted + skipped + 队列")
            XCTAssertEqual(c.submitted, c.backendAccountedFrames, "flush 后 submitted = encoded + droppedByEncoder + failed")
            XCTAssertLessThan(p99, 0.1, "push 耗时 p99 必须 < 0.1 ms")
            if multiplier == 4 { XCTAssertGreaterThan(c.skipped, 0, "4 倍速应当让编码器跟不上并计数") }
        }
    }

    // MARK: 编码延迟 H.264 vs HEVC（报告要求）

    func testLatency_h264VersusHEVC_1080p60() throws {
        var summary: [String] = []
        for codec in [VideoCodec.h264, .hevc] {
            let encoder = VideoEncoder(configuration: .init(name: "lat-\(codec.rawValue)", format: format,
                                                            settings: VideoEncodeSettings(codec: codec, bitrateBps: 6_000_000)))
            let latencies = LockedArray<Double>()
            encoder.output = { s in latencies.append(s.encodeLatency.milliseconds) }
            try encoder.start()
            let feeder = try PatternFeeder(configuration: .init(format: format, texture: .noise(amplitude: 24, seed: 3)))
            let clock = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 200), frameRate: .fps60)
            _ = try feeder.feed(consumers: [encoder], clock: clock, ticks: Tick.zero..<Tick(600), pacing: .realTime)
            encoder.stop()
            let l = latencies.values.sorted()
            XCTAssertEqual(l.count, 600)
            let line = "\(codec.rawValue): p50 \(String(format: "%.2f", l[l.count / 2])) ms p99 \(String(format: "%.2f", l[Int(Double(l.count) * 0.99)])) ms max \(String(format: "%.2f", l.last ?? 0)) ms (首帧 \(String(format: "%.2f", l.first ?? 0)))"
            summary.append(line)
            XCTAssertEqual(encoder.counters.skipped, 0)
        }
        print("编码延迟 1080p60 实时喂（噪声底）：\n  " + summary.joined(separator: "\n  "))
    }

    // MARK: VT 属性生效情况（报告要求）

    func testVTProperties_allAcceptedForH264AndHEVC_rateControlRejectedForProRes() throws {
        for codec in [VideoCodec.h264, .hevc, .prores422] {
            let backend = VTCompressionBackend(configuration: .init(format: format, settings: VideoEncodeSettings(codec: codec)))
            try backend.prepare(output: { _ in }, dropped: {})
            let rejected = backend.propertyOutcomes.filter { $0.status != 0 }
            print("VT \(codec.rawValue) encoder=\(backend.encoderID ?? "?") hw=\(backend.usingHardware)")
            for o in backend.propertyOutcomes { print("   \(o.status == 0 ? "OK " : "ERR") \(o.key) = \(o.readback ?? "nil") (\(o.status))") }
            XCTAssertTrue(backend.usingHardware, "\(codec) 应当在用硬件编码器")
            switch codec {
            case .h264, .hevc:
                XCTAssertTrue(rejected.isEmpty, "\(codec)：这些属性被拒绝 \(rejected.map(\.key))")
                let byKey = Dictionary(uniqueKeysWithValues: backend.propertyOutcomes.map { ($0.key, $0.readback ?? "") })
                XCTAssertEqual(byKey["MaxKeyFrameInterval"], "120")
                XCTAssertEqual(byKey["AllowFrameReordering"], "0")
                XCTAssertEqual(byKey["RealTime"], "1")
            default:
                XCTAssertTrue(rejected.isEmpty, "ProRes 只设它支持的属性，不该有拒绝：\(rejected.map(\.key))")
            }
            backend.invalidate()
        }
    }
}

final class LockedArray<T>: @unchecked Sendable {
    private var storage: [T] = []
    private let lock = NSLock()
    func append(_ v: T) { lock.withLock { storage.append(v) } }
    var values: [T] { lock.withLock { storage } }
}
