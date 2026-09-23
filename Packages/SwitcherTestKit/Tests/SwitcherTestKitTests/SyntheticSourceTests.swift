import XCTest
import CoreVideo
import Darwin
import SwitcherContracts
import Synchronization
@testable import SwitcherTestKit

/// 合成源自测（prompt "测试"第 3 条）：60 fps 跑 10 秒帧号连续、时间戳单调、pushed = 600 ± 1；5% 人为丢帧经 frameprobe stats 报出 5% ± 0.5%。
/// 这些测试真跑线程、真等时间（两条 10 秒的），放最后跑不影响别的。
final class SyntheticSourceTests: XCTestCase {
    /// 收集每一帧：在生产者线程上解码图案（只读几十个块，< 0.3 ms）。
    final class Collector: @unchecked Sendable {
        struct Record { var n: UInt64; var pts: HostTime; var ingress: HostTime; var decoded: TestPattern.Decoded; var gray: Double; var format: PixelFormat? }
        let records = Mutex<[Record]>([])
        func attach(_ slot: TestKitFrameSlot) {
            slot.onPush = { [self] f in
                let d = TestPattern.decode(pixelBuffer: f.pixelBuffer) ?? TestPattern.Decoded(frameNumber: nil, hostTimeMs: nil, inputID: nil, flash: false)
                let g = MediaReader.grayLevel(of: f.pixelBuffer)
                records.withLock { $0.append(Record(n: f.sequence, pts: f.pts, ingress: f.ingressTime, decoded: d, gray: g, format: f.pixelFormat)) }
            }
        }
        var all: [Record] { records.withLock { $0 } }
        var probeFrames: [ProbeFrame] {
            all.enumerated().map { i, r in ProbeFrame(index: i, ptsSeconds: r.pts.seconds, decoded: r.decoded, gray: r.gray) }
        }
    }

    private func run(settings: SyntheticSourceSettings, seconds: Double, number: Int = 1, stopBeforeNextFrameMs: Double = 8) throws -> (SyntheticVideoInput, Collector, SyntheticTimeline) {
        let slot = TestKitFrameSlot(capacity: 3)
        let collector = Collector()
        collector.attach(slot)
        let timeline = SyntheticTimeline.startingSoon(frameRate: settings.frameRate, leadMilliseconds: 50)
        let input = try SyntheticVideoInput(number: number, settings: settings, videoSlot: slot, timeline: timeline)
        try input.start()
        // 睡到 t0 + seconds − 一点，保证第 seconds × fps 帧还没产
        RealtimeThread.wait(until: timeline.t0 + HostDuration(seconds: seconds) - HostDuration(milliseconds: stopBeforeNextFrameMs))
        input.stop()
        return (input, collector, timeline)
    }

    func testW1A_syntheticVideo_60fps10s_continuousMonotonic_pushed600() throws {
        let settings = SyntheticSourceSettings(frameRate: .fps60, width: 1920, height: 1080, background: .gray(level: 128), audio: false)
        let (input, collector, timeline) = try run(settings: settings, seconds: 10)
        let records = collector.all
        let stats = input.videoSlot!.stats
        XCTAssertEqual(input.state, .noSignal)
        XCTAssertTrue(abs(Int(stats.pushed) - 600) <= 1, "pushed = \(stats.pushed)，应为 600 ± 1")
        XCTAssertEqual(records.count, Int(stats.pushed))
        XCTAssertEqual(input.counters.generated, stats.pushed)
        XCTAssertEqual(input.counters.droppedByDesign, 0); XCTAssertEqual(input.counters.poolStarved, 0)
        // 帧号连续、烧进画面的帧号 = sequence、时间戳单调、pts = 时间线拍点
        var maxLateMs = 0.0, sumLateMs = 0.0, minLateMs = Double.infinity
        for (i, r) in records.enumerated() {
            XCTAssertEqual(r.n, UInt64(i))
            XCTAssertEqual(r.decoded.frameNumber, UInt32(i))
            XCTAssertEqual(r.decoded.inputID, 0, "输入 1 → 调色板 0")
            XCTAssertEqual(r.decoded.flash, i % 60 == 0)
            XCTAssertEqual(r.format, .nv12)
            XCTAssertEqual(r.pts, timeline.videoClock(driftPpm: 0).time(of: Tick(Int64(i))))
            // 图案里的毫秒是 28 位（契约 `TestPattern.Content` 会 & dataMask），期望值也得掩码：
            // host time 从开机起算，开机超过 2²⁸ ms（3.1 天）之后不掩码就差一个 2²⁸（W1-A3 在开机 7 天的机器上踩到）
            XCTAssertEqual(r.decoded.hostTimeMs, UInt32(truncatingIfNeeded: r.pts.nanoseconds / 1_000_000) & TestPattern.dataMask)
            if i > 0 { XCTAssertGreaterThan(r.pts, records[i - 1].pts); XCTAssertGreaterThanOrEqual(r.ingress, records[i - 1].ingress) }
            let late = (r.ingress - r.pts).milliseconds
            maxLateMs = max(maxLateMs, late); minLateMs = min(minLateMs, late); sumLateMs += late
        }
        let meanLate = sumLateMs / Double(records.count)
        let c = input.counters
        print("[W1-A] 60 fps 10 s 1080p：ingress − pts 平均 \(String(format: "%.3f", meanLate)) ms（最小 \(String(format: "%.3f", minLateMs))，最大 \(String(format: "%.3f", maxLateMs))）；唤醒延迟平均 \(String(format: "%.3f", c.meanWakeLatencyMs)) ms、最大 \(String(format: "%.3f", Double(c.wakeLatencyMaxNs) / 1e6)) ms；画帧平均 \(String(format: "%.3f", c.meanDrawMs)) ms；late \(c.late)")
        XCTAssertGreaterThanOrEqual(minLateMs, 0, "没配抖动时不可能早于 pts")
        XCTAssertLessThan(c.meanWakeLatencyMs, 0.5, "平均唤醒延迟 < 0.5 ms（没有 time-constraint 策略时是 2.8 ms）")
        // 单次最大值受整机负载影响（并行跑别的测试时见过 7 ms 一次），只拦"根本没拿到实时调度"的情况；平均值才是判据
        XCTAssertLessThan(Double(c.wakeLatencyMaxNs) / 1e6, 20, "最大唤醒延迟 < 20 ms")
        XCTAssertEqual(c.late, 0)
    }

    func testV4_syntheticVideo_dropEvery20_frameprobeStatsReports5pct() throws {
        let settings = SyntheticSourceSettings(frameRate: .fps60, width: 1280, height: 720, background: .gray(level: 64), dropEveryN: 20, audio: false)
        let (input, collector, _) = try run(settings: settings, seconds: 10)
        XCTAssertEqual(input.counters.droppedByDesign, 30)
        XCTAssertTrue(abs(Int(input.counters.generated) - 570) <= 1, "generated = \(input.counters.generated)")
        let report = FrameAnalysis.stats(frames: collector.probeFrames, programFps: 60, inputFps: [0: 60])
        let s = report.inputs[0]
        XCTAssertEqual(s.inputID, 0)
        // 最后一个缺口（帧号 599）在最后一帧之后看不见：29 / 599 = 4.84%；设定值 5%，容差 ±0.5%
        XCTAssertEqual(s.dropRatio, 0.05, accuracy: 0.005, "frameprobe 报的丢弃比例 \(s.dropRatio)")
        XCTAssertEqual(s.dropGaps.first?.missing, 1)
        XCTAssertEqual(s.dropGaps.first?.from, 18); XCTAssertEqual(s.dropGaps.first?.to, 20)
        XCTAssertEqual(s.duplicateFrames, 0); XCTAssertEqual(s.backwardJumps, 0)
        XCTAssertEqual(report.undecodableFrames, 0)
        XCTAssertEqual(s.passV4, false, "5% 是设计外丢弃，V4 必须判失败")
    }

    func testW1A_syntheticVideo_jitterIsUniformWithinBound() throws {
        let settings = SyntheticSourceSettings(frameRate: .fps60, width: 640, height: 360, jitterMs: 3, audio: false)
        let (input, collector, _) = try run(settings: settings, seconds: 3)
        let lates = collector.all.map { ($0.ingress - $0.pts).milliseconds }
        XCTAssertGreaterThan(lates.count, 170)
        let mean = lates.reduce(0, +) / Double(lates.count)
        let std = (lates.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lates.count)).squareRoot()
        print("[W1-A] 抖动 ±3 ms：ingress − pts 均值 \(String(format: "%.3f", mean))，标准差 \(String(format: "%.3f", std))，范围 \(String(format: "%.3f", lates.min()!)) … \(String(format: "%.3f", lates.max()!)) ms")
        XCTAssertGreaterThanOrEqual(lates.min()!, -3.0)
        XCTAssertLessThanOrEqual(lates.max()!, 3.0 + 3.0)
        XCTAssertEqual(std, 3 / 3.0.squareRoot(), accuracy: 0.4, "均匀分布 ±3 的标准差 1.73")
        // 0.8 → 1.2：mean 里除了零均值的抖动还有一项系统性的画帧 + 交付开销（1080p 那条没配抖动时是 2.17 ms，
        // 这里 640×360 实测 0.85–0.86），0.8 正压在线上，main 上也 3/3 红。用户 2026-09-23 批了放宽到 1.2。
        // 问题单 reports/issues/P3-w1-testkit-jitter-mean-bound.md 留着（里面记了"扣掉偏置再判"那个更稳的方向）。
        XCTAssertLessThan(abs(mean), 1.2)
        // pts 本身不抖：仍是严格的拍点
        let clock = input.timeline!.videoClock(driftPpm: 0)
        for r in collector.all { XCTAssertEqual(r.pts, clock.time(of: Tick(Int64(r.n)))) }
    }

    func testW1A_generator_driftFlashAndDropArithmetic() {
        let tl = SyntheticTimeline(t0: HostTime(nanoseconds: 1_000_000_000), frameRate: .fps60)
        // +100 ppm：设备时钟快，600 帧在 host 上只走 10 s / 1.0001
        let fast = SyntheticVideoInput.Generator(timeline: tl, settings: SyntheticSourceSettings(dropEveryN: 20, clockDriftPpm: 100), patternID: 3)
        let elapsed = (fast.pts(of: 600) - tl.t0).nanoseconds
        XCTAssertEqual(Double(elapsed), 10e9 / 1.0001, accuracy: 100)
        XCTAssertEqual(SyntheticTimeline.driftedDuration(Rational(1, 60), ppm: 100), Rational(1_000_000_000, 60_006_000_000))
        XCTAssertEqual(SyntheticTimeline.driftedDuration(Rational(1001, 60000), ppm: -100), Rational(1001, 60000) * Rational(1_000_000_000, 999_900_000))
        XCTAssertTrue(fast.isDropped(19)); XCTAssertTrue(fast.isDropped(39)); XCTAssertFalse(fast.isDropped(20)); XCTAssertFalse(fast.isDropped(0))
        let c = fast.content(of: 120)
        XCTAssertEqual(c.frameNumber, 120); XCTAssertTrue(c.flash); XCTAssertEqual(c.inputID, 3)
        XCTAssertFalse(fast.content(of: 121).flash)
        XCTAssertEqual(c.hostTimeMs, UInt32(fast.pts(of: 120).nanoseconds / 1_000_000))
        // 59.94：闪光每 60 帧，第 60 帧在 1.001 s
        let tl2 = SyntheticTimeline(t0: tl.t0, frameRate: .fps5994)
        let g2 = SyntheticVideoInput.Generator(timeline: tl2, settings: SyntheticSourceSettings(frameRate: .fps5994), patternID: 0)
        XCTAssertTrue(g2.content(of: 60).flash); XCTAssertFalse(g2.content(of: 59).flash)
        XCTAssertEqual((g2.pts(of: 60) - tl2.t0).nanoseconds, 1_001_000_000, accuracy: 50)
        // click 与闪光同刻：第 1 个 click 的样本时刻 = 第 60 帧的 pts
        let sig = tl2.audioSignal(driftPpm: 0)
        XCTAssertEqual(sig.hostTime(ofSample: sig.clickSampleIndex(1)).nanoseconds, g2.pts(of: 60).nanoseconds, accuracy: 25_000, "click 落在样本格上，最多差半个样本（10.4 µs）")
        XCTAssertEqual(fast.frameDuration.nanoseconds, Int64(1e9 / 60 / 1.0001), accuracy: 50)
    }

    func testW1A_syntheticAudio_blocks256_timestampsAndClicks() throws {
        let ring = TestKitAudioRing(channelCount: 2, capacityFrames: 1 << 20)
        let timeline = SyntheticTimeline.startingSoon(frameRate: .fps60, leadMilliseconds: 50)
        let audio = SyntheticAudioInput(number: 2, frameRate: .fps60, driftPpm: 0, audioRing: ring, timeline: timeline)
        XCTAssertEqual(audio.state, .noSignal); XCTAssertNil(audio.videoSlot); XCTAssertEqual(audio.kind, .synthetic)
        try audio.start()
        XCTAssertEqual(audio.state, .live)
        RealtimeThread.wait(until: timeline.t0 + HostDuration(seconds: 1.5))
        let stopTime = HostClock.now() // 测试线程自己没有 time-constraint 策略，可能晚醒几 ms，所以按实际停止时刻算期望
        audio.stop()
        let c = audio.counters
        XCTAssertEqual(c.framesWritten, c.blocksWritten * 256)
        XCTAssertEqual(c.framesRejected, 0)
        // 停止时刻前到期的块（块在其最后一个样本时刻到期）：floor(经过秒数 × 48000 / 256)，stop 时正在等的那块可能再多 1
        let due = Int((stopTime - timeline.t0).seconds * 48000 / 256)
        XCTAssertTrue((due...(due + 1)).contains(Int(c.blocksWritten)), "blocks = \(c.blocksWritten)，期望 \(due) 或 \(due + 1)")
        XCTAssertEqual(ring.availableFrames, Int(c.framesWritten))
        // 读回：首帧 host time = t0；两个声道一样；click 在样本 0 和 48000
        let n = ring.availableFrames
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n); defer { l.deallocate() }
        let r = UnsafeMutablePointer<Float>.allocate(capacity: n); defer { r.deallocate() }
        let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2); defer { planes.deallocate() }
        planes[0] = l; planes[1] = r
        let res = ring.read(into: UnsafePointer(planes), frameCount: n)
        XCTAssertEqual(res.framesRead, n)
        XCTAssertEqual(res.firstFrameHostTime, timeline.t0)
        XCTAssertEqual(l[0], 1); XCTAssertEqual(l[47], 1); XCTAssertNotEqual(l[48], 1); XCTAssertEqual(r[10], l[10])
        let clicks = ClickDetector.detect(samples: Array(UnsafeBufferPointer(start: l, count: n)), sampleRate: 48000)
        XCTAssertEqual(clicks.map(\.sampleIndex), [0, 48000])
        XCTAssertEqual(audio.signal!.toneAmplitude, 0.1, accuracy: 1e-12)
        XCTAssertEqual(c.late, 0)
    }

    func testW1A_syntheticVideoWithAudio_flashAndClickShareT0() throws {
        let slot = TestKitFrameSlot(capacity: 3)
        let ring = TestKitAudioRing(channelCount: 1, capacityFrames: 1 << 20)
        let collector = Collector()
        collector.attach(slot)
        let settings = SyntheticSourceSettings(frameRate: .fps60, width: 640, height: 360, audio: true, audioDriftPpm: 50)
        let input = try SyntheticVideoInput(number: 5, settings: settings, videoSlot: slot, audioRing: ring)
        XCTAssertNotNil(input.audio); XCTAssertTrue(input.audioRing === ring)
        XCTAssertEqual(input.patternID, 4)
        XCTAssertNil(input.timeline, "start 前没有时间线")
        try input.start()
        let tl = try XCTUnwrap(input.timeline)
        XCTAssertEqual(input.audio!.timeline, tl, "音视频共用一个 t0")
        XCTAssertEqual(input.audio!.state, .live)
        RealtimeThread.wait(until: tl.t0 + HostDuration(seconds: 2.2))
        input.stop()
        XCTAssertEqual(input.audio!.state, .noSignal)
        // 视频闪光帧 0 / 60 / 120 的 pts = t0 + k s；音频第 k 个 click 的样本时刻也是 t0 + k s（漂移 50 ppm 只改样本序号）
        let flashes = collector.all.filter(\.decoded.flash)
        XCTAssertEqual(flashes.map(\.n), [0, 60, 120])
        let sig = try XCTUnwrap(input.audio!.signal)
        for k in 0..<3 {
            let clickTime = sig.hostTime(ofSample: sig.clickSampleIndex(k))
            XCTAssertEqual(Double((clickTime - flashes[k].pts).nanoseconds), 0, accuracy: 11_000, "第 \(k) 个 click 与闪光帧相差半个样本以内")
        }
        XCTAssertEqual(sig.clickSampleIndex(1), 48002, "48000 × 1.00005 = 48002.4")
        // 环里读回来的 click 位置 = 信号定义的样本序号
        let n = ring.availableFrames
        var mono = [Float](repeating: 0, count: n)
        mono.withUnsafeMutableBufferPointer { buf in
            let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1); defer { planes.deallocate() }
            planes[0] = buf.baseAddress!
            _ = ring.read(into: UnsafePointer(planes), frameCount: n)
        }
        XCTAssertEqual(ClickDetector.detect(samples: mono, sampleRate: 48000).map(\.sampleIndex), [0, 48002, 96005])
    }

    func testW1A_syntheticVideo_stateStartStopRestart() throws {
        let slot = TestKitFrameSlot()
        let input = try SyntheticVideoInput(number: 1, name: "cam", settings: SyntheticSourceSettings(width: 320, height: 180, audio: false), videoSlot: slot)
        XCTAssertEqual(input.name, "cam"); XCTAssertEqual(input.kind, .synthetic); XCTAssertNil(input.audioRing)
        XCTAssertEqual(input.state, .noSignal)
        try input.start()
        XCTAssertEqual(input.state, .live)
        input.stop()
        XCTAssertEqual(input.state, .noSignal)
        let pushedAfterFirst = slot.stats.pushed
        // 再 start：新的时间线，帧号从 0 重来
        try input.start()
        Thread.sleep(forTimeInterval: 0.1)
        input.stop()
        XCTAssertGreaterThan(slot.stats.pushed, pushedAfterFirst)
    }

    func testW1A_pool_returnsNilBeyondThresholdAndRecycles() throws {
        let pool = try NV12PixelBufferPool(width: 320, height: 180, maximumBuffers: 4)
        var held: [CVPixelBuffer] = []
        for _ in 0..<4 { held.append(try XCTUnwrap(pool.take())) }
        XCTAssertNil(pool.take(), "超过阈值不再分配")
        let first = held.removeFirst()
        let firstAddress = Unmanaged.passUnretained(first).toOpaque()
        _ = firstAddress
        held.removeAll()
        let again = try XCTUnwrap(pool.take())
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(again), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(again), "IOSurface 背后")
        XCTAssertEqual(CVPixelBufferGetPlaneCount(again), 2)
    }
}
