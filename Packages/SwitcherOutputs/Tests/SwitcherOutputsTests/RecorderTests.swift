import AVFoundation
import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// E2 码率遵从、E3 关键帧间隔、E5 文件完整性、ISO 分路、磁盘错误、ProRes、转封装。
final class RecorderTests: XCTestCase {
    let format = ProgramFormat.hd1080p60
    let fps = 60

    override func setUpWithError() throws {
        try FFprobe.requireAvailable()
    }

    private func makeRecorder(_ name: String, codec: VideoCodec = .h264, bitrate: Int = 6_000_000, keyint: Int = 120,
                              audio: AudioEncodeSettings? = AudioEncodeSettings(), remux: Bool = false,
                              fragment: Double = 1, minimumFree: UInt64 = 200 * 1024 * 1024, url: URL? = nil) -> Recorder {
        Recorder(configuration: .init(
            url: url ?? TestPaths.file("\(name).mov"), format: format,
            video: VideoEncodeSettings(codec: codec, bitrateBps: bitrate, keyframeIntervalFrames: keyint),
            audio: audio, fragmentIntervalSeconds: fragment, remuxToMP4: remux, minimumFreeBytes: minimumFree, name: name))
    }

    /// P2（提案 001 / 002）：Stats.encoder 项的 frames / dropped / disk_free_mb / state 从录制器计数与状态来。
    func testP2_recorder_statsEntryCarriesFramesDiskAndState() throws {
        let rec = makeRecorder("p2-stats")
        XCTAssertEqual(rec.statsEntry(previous: nil, windowSeconds: 1).state, "idle")
        try rec.start(at: RecordingStart(clock: TickClockSpec(t0: HostClock.now(), frameRate: format.frameRate), tick: .zero))
        let e = rec.statsEntry(previous: nil, windowSeconds: 1)
        XCTAssertEqual([e.state, "\(e.frames)", "\(e.dropped)", "\(e.reconnects)"], ["recording", "0", "0", "0"])
        XCTAssertGreaterThan(e.diskFreeMb, 200, "录制目录所在卷的剩余 MB（start 时刷新）")
        let done = expectation(description: "stop")
        rec.stop { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(rec.statsEntry(previous: nil, windowSeconds: 1).state, "failed", "一帧没写就封口 → failed")
    }

    // MARK: E2 码率遵从

    /// H.264 6 Mbps 1080p60 录 60 秒（噪声底，实时喂）；ffprobe 包按秒分桶：10 s 滑窗平均误差 ≤ 10%（目标 5%），1 s 峰值 ≤ 1.5×（目标 1.2×）。
    func testE2_bitrateCompliance_h264_6Mbps_1080p60_60s() throws {
        let target = 6_000_000.0
        let seconds = 60
        let recorder = makeRecorder("e2-h264", codec: .h264, bitrate: Int(target))
        let scene = try RecordingScene(format: format, texture: .noise(amplitude: 24, seed: 11), realTime: true)
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        let report = try scene.feed(recorders: [recorder], ticks: seconds * fps, realTime: true)
        let result = try stopAndWait(recorder, atTick: Tick(Int64(seconds * fps)))
        XCTAssertEqual(report.framesFed, seconds * fps)
        print("E2 喂料：晚点 \(report.lateTicks) 次，push p99 \(report.pushPercentileMs(0.99)) ms；编码 skipped \(result.encoder.skipped) 于拍 \(result.encoder.recentSkippedTicks.map(\.rawValue))，EncodeFrame 最长 \(result.encoder.maxEncodeCall.milliseconds) ms，延迟 max \(result.encoder.maxLatency.milliseconds) ms")
        XCTAssertEqual(result.encoder.skipped, 0, "标准负载下 E1 必须为 0")
        XCTAssertEqual(Int(result.videoFrames), seconds * fps)

        let packets = try FFprobe.packets(result.url)
        XCTAssertEqual(packets.count, seconds * fps)
        var perSecond = [Double](repeating: 0, count: seconds)
        for p in packets {
            let s = Int(p.ptsTime.rounded(.down))
            if s >= 0 && s < seconds { perSecond[s] += Double(p.size) * 8 }
        }
        let peakRatio = perSecond.max()! / target
        var worstWindowError = 0.0
        var windowMeans: [Double] = []
        for a in 0...(seconds - 10) {
            let mean = perSecond[a..<(a + 10)].reduce(0, +) / 10
            windowMeans.append(mean)
            worstWindowError = max(worstWindowError, abs(mean - target) / target)
        }
        let overall = perSecond.reduce(0, +) / Double(seconds)
        print(String(format: "E2 H.264 6 Mbps：总平均 %.3f Mbps；10 s 滑窗平均误差最大 %.2f%%（必须 ≤ 10%%，目标 ≤ 5%%）；1 s 峰值 %.3f×（必须 ≤ 1.5，目标 ≤ 1.2）", overall / 1e6, worstWindowError * 100, peakRatio))
        print("   逐秒 Mbps：" + perSecond.map { String(format: "%.2f", $0 / 1e6) }.joined(separator: " "))
        XCTAssertLessThanOrEqual(worstWindowError, 0.10, "10 s 滑窗平均码率误差必须 ≤ 10%")
        XCTAssertLessThanOrEqual(peakRatio, 1.5, "1 s 窗峰值必须 ≤ 1.5 倍")
        // 顺便：E3 在同一个文件上
        let intervals = keyframeIntervals(packets)
        print("   关键帧间隔：\(Set(intervals).sorted())")
        for i in intervals { XCTAssertLessThanOrEqual(abs(i - 120), 1, "关键帧间隔 \(i) 偏离 120 超过 1 帧") }
    }

    private func keyframeIntervals(_ packets: [FFprobe.Packet]) -> [Int] {
        let keys = packets.enumerated().filter { $0.element.isKeyframe }.map(\.offset)
        guard keys.count >= 2 else { return [] }
        return (1..<keys.count).map { keys[$0] - keys[$0 - 1] }
    }

    // MARK: E3 关键帧间隔

    /// 关键帧间隔设 120，H.264 与 HEVC 各录 20 秒（噪声底），每个间隔 ≤ ±1 帧。
    func testE3_keyframeInterval120_h264AndHEVC() throws {
        for codec in [VideoCodec.h264, .hevc] {
            let seconds = 20
            let recorder = makeRecorder("e3-\(codec.rawValue)", codec: codec, keyint: 120)
            let scene = try RecordingScene(format: format, texture: .noise(amplitude: 24, seed: 5), realTime: false)
            try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
            _ = try scene.feed(recorders: [recorder], ticks: seconds * fps, realTime: false)
            let result = try stopAndWait(recorder, atTick: Tick(Int64(seconds * fps)))
            XCTAssertEqual(Int(result.videoFrames), seconds * fps)
            let packets = try FFprobe.packets(result.url)
            XCTAssertEqual(packets.count, seconds * fps)
            XCTAssertTrue(packets.first?.isKeyframe ?? false, "第一帧必须是关键帧")
            let intervals = keyframeIntervals(packets)
            XCTAssertEqual(intervals.count, seconds * fps / 120 - 1)
            print("E3 \(codec.rawValue)：关键帧位置间隔 \(intervals)")
            for i in intervals { XCTAssertLessThanOrEqual(abs(i - 120), 1, "\(codec)：关键帧间隔 \(i) 偏离 120 超过 1 帧") }
        }
    }

    // MARK: E5 文件完整性

    /// 正常停止 20 次（0.5–60 s 随机时长，固定种子），每个文件 ffprobe 无错、帧数精确、视频时长误差 ≤ 1 帧、音视频轨时长差 ≤ 20 ms。
    /// 喂料用"尽快 + 背压"（不等拍点），编码器和文件只看 PTS；20 个文件总时长约 10 分钟的素材几分钟录完。
    func testE5_normalStop20Times_fileIntegrity() throws {
        var rng = SplitMix64(seed: 2026)
        var lines: [String] = []
        for run in 0..<20 {
            let ticks = 30 + Int(rng.next() % UInt64(3600 - 30 + 1))     // 0.5 s … 60 s
            let audioCodec: SwitcherContracts.AudioCodec = run % 5 == 4 ? .pcm : .aac
            let recorder = makeRecorder("e5-\(run)", audio: AudioEncodeSettings(codec: audioCodec))
            let scene = try RecordingScene(format: format, texture: run % 2 == 0 ? .flat : .noise(amplitude: 16, seed: UInt64(run)), realTime: false)
            try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
            _ = try scene.feed(recorders: [recorder], ticks: ticks, realTime: false)
            let result = try stopAndWait(recorder, atTick: Tick(Int64(ticks)))
            XCTAssertEqual(Int(result.videoFrames), ticks, "第 \(run) 个：写入帧数")
            XCTAssertEqual(result.encoder.skipped, 0, "第 \(run) 个：不该跳帧")
            let probe = try FFprobe.probe(result.url)
            XCTAssertEqual(probe.exitCode, 0, "第 \(run) 个：ffprobe 退出码")
            XCTAssertEqual(probe.stderr, "", "第 \(run) 个：ffprobe 报错：\(probe.stderr)")
            let expected = Double(ticks) / Double(fps)
            guard let v = probe.video, let a = probe.audio, let vd = v.duration, let ad = a.duration else {
                XCTFail("第 \(run) 个：缺轨道"); continue
            }
            XCTAssertEqual(v.nbFrames, ticks, "第 \(run) 个：nb_frames")
            let frameErr = abs(vd - expected) * Double(fps)
            let avDiffMs = abs(vd - ad) * 1000
            lines.append("  #\(run) \(ticks) 拍 \(audioCodec.rawValue) 视频 \(String(format: "%.4f", vd)) s（期望 \(String(format: "%.4f", expected))，误差 \(String(format: "%.3f", frameErr)) 帧）音频 \(String(format: "%.4f", ad)) s（差 \(String(format: "%.2f", avDiffMs)) ms）")
            XCTAssertLessThanOrEqual(frameErr, 1.0, "第 \(run) 个：视频时长误差超过 1 帧")
            XCTAssertLessThanOrEqual(avDiffMs, 20, "第 \(run) 个：音视频轨时长差超过 20 ms")
            XCTAssertEqual(a.startTime ?? -1, 0, accuracy: 0.0005, "第 \(run) 个：音轨起点应为 0")
            XCTAssertEqual(v.startTime ?? -1, 0, accuracy: 0.0005, "第 \(run) 个：视频轨起点应为 0")
        }
        print("E5 20 次正常停止：\n" + lines.joined(separator: "\n"))
    }

    // MARK: E5 停止边界（W1-E2：边界之后到达的块、预告停止拍、边界之前调 stop）

    /// 按拍喂视频到 T，`stop(atTick: T)`（此时含边界的音频块还没到——泵比 PTS 晚 60 ms 送，和集成层的对齐延迟一个样子），
    /// 然后泵继续按实时送 PTS > T 的块 5 s：封口 ≤ 1 s 完成（越界块不再触发补静音、不再每 4096 帧等 200 ms），
    /// 音轨长度 = 名义时长 ± 1 块（256 帧 = 5.33 ms），越界样本只计数不写，边界之前的样本一个不丢。
    func testE5_recorderStopBoundary_audioTrackWithin1Block() throws {
        let seconds = 5
        let ticks = seconds * fps
        let boundary = Tick(Int64(ticks))
        let recorder = makeRecorder("e5-boundary")
        let scene = try RecordingScene(format: format, realTime: true)
        let pump = LaggedAudioPump(signal: scene.signal, consumers: [recorder], lag: HostDuration(milliseconds: 60))
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        pump.start()
        defer { pump.stop() }
        let report = try scene.feeder.feed(consumers: [recorder], clock: scene.clock, ticks: Tick.zero..<boundary, pacing: .realTime)
        XCTAssertEqual(report.framesFed, ticks)
        let stopCalledAt = HostClock.now()
        let outcome = StopOutcome()
        recorder.stop(atTick: boundary, completion: outcome.handler)
        // 泵继续送 5 s 的越界块（PTS > T）
        Thread.sleep(forTimeInterval: 5)
        XCTAssertGreaterThan(pump.nextSample, Int64((seconds + 4) * 48000), "泵应当已经送了 ≥ 4 s 的越界块")
        pump.stop()
        let (result, completedAt) = try outcome.wait(timeout: 10)
        let sealMs = (completedAt - stopCalledAt).milliseconds
        let c = recorder.counters
        let probe = try FFprobe.probe(result.url)
        XCTAssertEqual(probe.stderr, "")
        guard let vd = probe.video?.duration, let ad = probe.audio?.duration else { XCTFail("缺轨道"); return }
        print(String(format: "E5 停止边界：封口 %.0f ms（必须 ≤ 1000）；视频 %.4f s / 音频 %.4f s（名义 %d s，差 %.2f ms）；越界样本 %d，封口后丢 %d，硬校正 %d，环丢块 %d",
                     sealMs, vd, ad, seconds, abs(vd - ad) * 1000, c.audioFramesBeyondStop, c.audioFramesDroppedAfterStop, c.audioCorrections, c.audioBlocksDropped))
        XCTAssertLessThanOrEqual(sealMs, 1000, "封口必须 ≤ 1 s 完成")
        XCTAssertEqual(result.stopTick, boundary)
        XCTAssertEqual(Int(result.videoFrames), ticks)
        XCTAssertEqual(c.audioFramesDroppedAfterStop, 0, "边界之前的样本一个都不该丢")
        XCTAssertGreaterThanOrEqual(c.audioFramesBeyondStop, UInt64(4 * 48000), "越界样本只计数不写")
        XCTAssertEqual(c.audioCorrections, 0, "越界块不参与漂移 / 补静音")
        XCTAssertEqual(vd, Double(seconds), accuracy: 1.0 / Double(fps))
        XCTAssertEqual(ad, Double(seconds), accuracy: 256.0 / 48000, "音轨长度 = 名义时长 ± 1 块")
        XCTAssertLessThanOrEqual(abs(vd - ad) * 1000, 20, "音视频轨时长差")
    }

    /// 边界前 2 s 调 `setStopTick(T)`：之后到达的越界块（视频 tick ≥ T、音频 PTS ≥ T 的拍点）一个都不进文件；
    /// 视频越过边界继续喂 1 s、音频泵一直跑，再 `stop()`（nil = 用预告的拍）：两轨时长差 ≤ 20 ms（必须）/ ≤ 1 帧（目标），click 仍在整秒上。
    func testE5_announcedStopTick_beforeBoundary() throws {
        let seconds = 6
        let boundary = Tick(Int64(seconds * fps))
        let announceAt = Tick(Int64((seconds - 2) * fps))
        let extraTicks = fps
        let recorder = makeRecorder("e5-announced")
        let scene = try RecordingScene(format: format, realTime: true)
        let pump = LaggedAudioPump(signal: scene.signal, consumers: [recorder], lag: HostDuration(milliseconds: 60))
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        pump.start()
        defer { pump.stop() }
        let announced = LockedArray<Tick?>()
        let report = try scene.feeder.feed(consumers: [recorder], clock: scene.clock, ticks: Tick.zero..<(boundary + extraTicks), pacing: .realTime) { tick, _ in
            if tick == announceAt { announced.append(recorder.setStopTick(boundary)) }
        }
        XCTAssertEqual(announced.values, [boundary], "预告的边界原样生效")
        XCTAssertEqual(report.framesFed, seconds * fps + extraTicks)
        let stopCalledAt = HostClock.now()
        let outcome = StopOutcome()
        recorder.stop(completion: outcome.handler)
        let (result, completedAt) = try outcome.wait(timeout: 10)
        pump.stop()
        let sealMs = (completedAt - stopCalledAt).milliseconds
        let c = recorder.counters
        let probe = try FFprobe.probe(result.url)
        XCTAssertEqual(probe.stderr, "")
        guard let vd = probe.video?.duration, let ad = probe.audio?.duration else { XCTFail("缺轨道"); return }
        let diffMs = abs(vd - ad) * 1000
        let frameMs = 1000.0 / Double(fps)
        print(String(format: "E5 预告停止拍：封口 %.0f ms；视频 %.4f s / 音频 %.4f s（名义 %d s），两轨差 %.2f ms（必须 ≤ 20，目标 ≤ 1 帧 = %.2f ms：%@）；越界帧 %d / 越界样本 %d，封口后丢 %d，硬校正 %d",
                     sealMs, vd, ad, seconds, diffMs, frameMs, diffMs <= frameMs ? "达标" : "未达", c.videoFramesBeyondStop, c.audioFramesBeyondStop, c.audioFramesDroppedAfterStop, c.audioCorrections))
        XCTAssertLessThanOrEqual(sealMs, 1000)
        XCTAssertEqual(result.stopTick, boundary)
        XCTAssertEqual(Int(result.videoFrames), seconds * fps, "tick ≥ 预告拍的帧不进文件")
        XCTAssertEqual(c.videoFramesBeyondStop, UInt64(extraTicks))
        XCTAssertGreaterThan(c.audioFramesBeyondStop, UInt64(48000 * 9 / 10), "边界之后至少 0.9 s 的越界样本被计数")
        XCTAssertEqual(c.audioFramesDroppedAfterStop, 0)
        XCTAssertEqual(c.audioCorrections, 0)
        XCTAssertEqual(vd, Double(seconds), accuracy: 1.0 / Double(fps))
        XCTAssertLessThanOrEqual(ad, Double(seconds) + 0.001, "越界块一个都不进文件")
        XCTAssertGreaterThanOrEqual(ad, Double(seconds) - 256.0 / 48000)
        XCTAssertLessThanOrEqual(diffMs, 20, "音视频轨时长差必须 ≤ 20 ms")
        // click 仍精确在每个整秒上（截断没有挪动时间轴）
        let samples = try FFprobe.decodeAudioMono(result.url)
        XCTAssertEqual(samples.count, seconds * 48000, accuracy: 256)
        for k in 0..<seconds {
            let center = k * 48000
            let lo = max(0, center - 2000), hi = min(samples.count, center + 2000)
            var best = lo, bestV: Float = 0
            for i in lo..<hi where abs(samples[i]) > bestV { bestV = abs(samples[i]); best = i }
            XCTAssertLessThanOrEqual(abs(best - center), 48, "第 \(k) 个 click 峰在 \(best)，期望 \(center) ± 48")
        }
    }

    /// 边界之前调 `stop(atTick:)`（点"停止"= 当前拍 + 1 的场景）：录制器等 tick = 边界 − 1 的帧和边界之前的音频都到了再封口，
    /// 视频恰好 = 边界拍数、之后喂的帧只计数，封口在边界拍点之后 ≤ 0.5 s 完成（不用等宽限到期）。
    func testE5_stopBeforeBoundary_waitsForFramesUpToBoundary() throws {
        let boundary = Tick(120)      // 2 s
        let stopAt = Tick(90)         // 边界前 0.5 s
        let total = 150
        let recorder = makeRecorder("e5-early-stop")
        let scene = try RecordingScene(format: format, realTime: true)
        let pump = LaggedAudioPump(signal: scene.signal, consumers: [recorder], lag: HostDuration(milliseconds: 60))
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        pump.start()
        defer { pump.stop() }
        let outcome = StopOutcome()
        let report = try scene.feeder.feed(consumers: [recorder], clock: scene.clock, ticks: Tick.zero..<Tick(Int64(total)), pacing: .realTime) { tick, _ in
            if tick == stopAt { recorder.stop(atTick: boundary, completion: outcome.handler) }
        }
        XCTAssertEqual(report.framesFed, total)
        let (result, completedAt) = try outcome.wait(timeout: 10)
        pump.stop()
        let boundaryTime = scene.clock.time(of: boundary)
        let afterBoundaryMs = (completedAt - boundaryTime).milliseconds
        let c = recorder.counters
        let probe = try FFprobe.probe(result.url)
        XCTAssertEqual(probe.stderr, "")
        guard let vd = probe.video?.duration, let ad = probe.audio?.duration else { XCTFail("缺轨道"); return }
        print(String(format: "E5 边界前 stop：封口在边界拍点后 %.0f ms 完成；视频 %.4f s / 音频 %.4f s（差 %.2f ms）；越界帧 %d / 越界样本 %d，封口后丢 %d",
                     afterBoundaryMs, vd, ad, abs(vd - ad) * 1000, c.videoFramesBeyondStop, c.audioFramesBeyondStop, c.audioFramesDroppedAfterStop))
        XCTAssertGreaterThan(completedAt, scene.clock.time(of: boundary - 1), "不该在边界前一拍的帧到之前封口")
        XCTAssertLessThanOrEqual(afterBoundaryMs, 500)
        XCTAssertEqual(result.stopTick, boundary)
        XCTAssertEqual(Int(result.videoFrames), Int(boundary.rawValue))
        XCTAssertEqual(c.videoFramesBeyondStop, UInt64(total) - UInt64(boundary.rawValue))
        XCTAssertEqual(c.audioFramesDroppedAfterStop, 0)
        XCTAssertEqual(vd, 2.0, accuracy: 1.0 / Double(fps))
        XCTAssertEqual(ad, 2.0, accuracy: 256.0 / 48000)
        XCTAssertLessThanOrEqual(abs(vd - ad) * 1000, 20)
    }

    /// `stop()`（nil）的边界 = 最后一个已收帧的下一拍（不是"此刻"），之后送来的音频块按边界截掉、只计数（G2 问题单建议 2）；
    /// 封口之后再来的"边界之前"的迟到样本：不写、不崩、计入 audioFramesDroppedAfterStop。
    func testStop_nilBoundaryIsLastConsumedFramePlusOne() throws {
        let ticks = 120
        let recorder = makeRecorder("stop-nil")
        let scene = try RecordingScene(format: format, realTime: false)
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        _ = try scene.feed(recorders: [recorder], ticks: ticks, realTime: false)   // 音频恰好喂到 T
        let outcome = StopOutcome()
        recorder.stop(completion: outcome.handler)
        // 停止之后再送 10 拍的音频（PTS ≥ 边界）：一个都不进文件
        let fed = scene.signalFeeder.feed(upTo: scene.clock.time(of: Tick(Int64(ticks + 10))), to: [recorder])
        XCTAssertGreaterThan(fed, 0)
        let (result, _) = try outcome.wait(timeout: 10)
        let c = recorder.counters
        XCTAssertEqual(result.stopTick, Tick(Int64(ticks)))
        XCTAssertEqual(Int(result.videoFrames), ticks)
        XCTAssertEqual(Int(result.audioFrames), ticks * 800)
        XCTAssertEqual(c.audioFramesBeyondStop, UInt64(fed * scene.signalFeeder.blockFrames))
        XCTAssertEqual(c.audioFramesDroppedAfterStop, 0)
        let probe = try FFprobe.probe(result.url)
        XCTAssertEqual(probe.stderr, "")
        XCTAssertEqual(probe.video?.duration ?? 0, 2.0, accuracy: 1.0 / Double(fps))
        XCTAssertEqual(probe.audio?.duration ?? 0, 2.0, accuracy: 256.0 / 48000)
        // 迟到的样本（边界之前的 PTS）在封口之后才来
        let late = SignalFeeder(signal: scene.signal, startSample: 0)
        late.flush(upToSample: 256, to: [recorder])
        XCTAssertEqual(recorder.counters.audioFramesDroppedAfterStop, 256)
        XCTAssertEqual(recorder.state, .finished)
    }

    // MARK: ISO 分路

    /// 4 路同时录 30 秒（同一拍启动、共用起点），各文件第一帧 PTS 相同、总帧数相同、无跳帧。
    func testISO_fourRecorders30s_sameFirstPTSAndFrameCount() throws {
        let seconds = 30
        let recorders = (1...4).map { makeRecorder("iso-\($0)") }
        let scene = try RecordingScene(format: format, texture: .noise(amplitude: 12, seed: 9), realTime: true)
        let start = RecordingStart(clock: scene.clock, tick: .zero)
        for r in recorders { try r.start(at: start) }
        let report = try scene.feed(recorders: recorders, ticks: seconds * fps, realTime: true)
        XCTAssertEqual(report.framesFed, seconds * fps)
        let end = Tick(Int64(seconds * fps))
        var results: [RecordingResult] = []
        for r in recorders { results.append(try stopAndWait(r, atTick: end)) }
        var firstPTS: [Double] = []
        var counts: [Int] = []
        for (i, res) in results.enumerated() {
            XCTAssertEqual(res.encoder.skipped, 0, "第 \(i + 1) 路跳帧")
            let packets = try FFprobe.packets(res.url)
            let probe = try FFprobe.probe(res.url)
            XCTAssertEqual(probe.stderr, "")
            firstPTS.append(packets.first?.ptsTime ?? -1)
            counts.append(packets.count)
            print("ISO 第 \(i + 1) 路：首帧 PTS \(packets.first?.ptsTime ?? -1) 帧数 \(packets.count) 视频 \(probe.video?.duration ?? -1) s 音频 \(probe.audio?.duration ?? -1) s 跳帧 \(res.encoder.skipped) 延迟 max \(res.encoder.maxLatency.milliseconds) ms")
        }
        XCTAssertEqual(Set(firstPTS).count, 1, "各文件第一帧 PTS 必须相同：\(firstPTS)")
        XCTAssertEqual(firstPTS.first, 0)
        XCTAssertEqual(Set(counts).count, 1, "各文件总帧数必须相同：\(counts)")
        XCTAssertEqual(counts.first, seconds * fps)
        print("ISO 4 路：喂帧晚点 \(report.lateTicks) 次，push p99 \(report.pushPercentileMs(0.99)) ms")
    }

    // MARK: 磁盘错误只停本录制

    /// 录到一个 12 MB 的小盘直到写满：该录制状态置 failed，同时录到正常目录的另一路帧数不受影响（S7 的基础）。
    func testDiskWriteFailure_stopsOnlyThisRecorder() throws {
        let image = TestPaths.file("tiny.dmg")
        let mount = TestPaths.file("tiny-volume")
        try? FileManager.default.removeItem(at: image)
        _ = try? runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard (try? runProcess("/usr/bin/hdiutil", ["create", "-size", "12m", "-fs", "HFS+", "-volname", "W1ETiny", "-quiet", image.path]))?.code == 0 else {
            throw XCTSkip("hdiutil create 失败，跳过磁盘错误测试")
        }
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard (try? runProcess("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-quiet", "-mountpoint", mount.path]))?.code == 0 else {
            throw XCTSkip("hdiutil attach 失败，跳过磁盘错误测试")
        }
        defer { _ = try? runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"]); try? FileManager.default.removeItem(at: image) }

        // 高码率 + 噪声让它几秒内写满；minimumFreeBytes 设 0 让失败真正来自写入
        let doomed = Recorder(configuration: .init(
            url: mount.appendingPathComponent("doomed.mov"), format: format,
            video: VideoEncodeSettings(codec: .h264, bitrateBps: 20_000_000), audio: AudioEncodeSettings(),
            minimumFreeBytes: 0, name: "doomed"))
        let healthy = makeRecorder("healthy")
        let scene = try RecordingScene(format: format, texture: .noise(amplitude: 40, seed: 4), realTime: true)
        let start = RecordingStart(clock: scene.clock, tick: .zero)
        try doomed.start(at: start)
        try healthy.start(at: start)
        let seconds = 12
        _ = try scene.feed(recorders: [doomed, healthy], ticks: seconds * fps, realTime: true)
        let end = Tick(Int64(seconds * fps))
        let healthyResult = try stopAndWait(healthy, atTick: end)
        let doomedState = doomed.state
        print("磁盘错误：doomed 状态 \(doomedState)，写入帧 \(doomed.counters.videoFrames)；healthy 帧 \(healthyResult.videoFrames) 跳帧 \(healthyResult.encoder.skipped)")
        guard case .failed(let message) = doomedState else {
            XCTFail("小盘上的录制应当失败，实际 \(doomedState)"); return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(Int(healthyResult.videoFrames), seconds * fps, "另一路不受影响")
        XCTAssertEqual(healthyResult.encoder.skipped, 0)
        let probe = try FFprobe.probe(healthyResult.url)
        XCTAssertEqual(probe.stderr, "")
        // 失败的录制 stop 也要能返回（返回失败），不挂
        let sem = DispatchSemaphore(value: 0)
        doomed.stop { r in
            if case .success = r { XCTFail("失败的录制 stop 不该成功") }
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + 10), .success)
    }

    private func runProcess(_ path: String, _ args: [String]) throws -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: ProRes（硬件）与 LPCM

    func testProRes422_hardware_writesPlayableMov() throws {
        let seconds = 5
        let recorder = makeRecorder("prores", codec: .prores422, audio: AudioEncodeSettings(codec: .pcm))
        let scene = try RecordingScene(format: format, texture: .noise(amplitude: 24, seed: 8), realTime: false)
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        _ = try scene.feed(recorders: [recorder], ticks: seconds * fps, realTime: false)
        let result = try stopAndWait(recorder, atTick: Tick(Int64(seconds * fps)))
        XCTAssertEqual(Int(result.videoFrames), seconds * fps)
        let probe = try FFprobe.probe(result.url)
        XCTAssertEqual(probe.stderr, "")
        XCTAssertEqual(probe.video?.codecName, "prores")
        XCTAssertEqual(probe.audio?.codecName, "pcm_s24le")
        XCTAssertEqual(probe.video?.duration ?? 0, Double(seconds), accuracy: 1.0 / Double(fps))
        XCTAssertEqual(probe.audio?.duration ?? 0, Double(seconds), accuracy: 0.02)
        let backend = recorder.encoder.backend as? VTCompressionBackend
        XCTAssertEqual(backend?.usingHardware, true)
        print("ProRes 422：\(result.videoBytes / 1024 / 1024) MB / \(seconds) s，编码延迟 max \(result.encoder.maxLatency.milliseconds) ms，encoder \(backend?.encoderID ?? "?")")
    }

    // MARK: 转封装 MP4

    func testRemuxToMP4_afterNormalStop() throws {
        let seconds = 5
        let recorder = makeRecorder("remux", remux: true)
        let scene = try RecordingScene(format: format, realTime: false)
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        _ = try scene.feed(recorders: [recorder], ticks: seconds * fps, realTime: false)
        let result = try stopAndWait(recorder, atTick: Tick(Int64(seconds * fps)))
        XCTAssertNil(result.remuxError, "转封装失败：\(result.remuxError ?? "")")
        guard let mp4 = result.mp4URL else { XCTFail("没有 mp4"); return }
        let probe = try FFprobe.probe(mp4)
        XCTAssertEqual(probe.stderr, "")
        XCTAssertEqual(probe.video?.nbFrames, seconds * fps)
        XCTAssertEqual(probe.video?.duration ?? 0, Double(seconds), accuracy: 1.0 / Double(fps))
        XCTAssertEqual(probe.audio?.duration ?? 0, Double(seconds), accuracy: 0.02)
        // .mov 仍在
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    }

    // MARK: 音频与视频同源：click 落在闪光帧的拍点上

    /// 录 5 秒后解码音轨：click 的位置精确在每个整秒（误差 ≤ 1 ms），证明音频 PTS 与视频拍点同源。
    func testAudioClicksLandOnFlashTicks() throws {
        let seconds = 5
        let recorder = makeRecorder("clicks")
        let scene = try RecordingScene(format: format, realTime: false)
        try recorder.start(at: RecordingStart(clock: scene.clock, tick: .zero))
        _ = try scene.feed(recorders: [recorder], ticks: seconds * fps, realTime: false)
        let result = try stopAndWait(recorder, atTick: Tick(Int64(seconds * fps)))
        let samples = try FFprobe.decodeAudioMono(result.url)
        XCTAssertEqual(samples.count, seconds * 48000)
        for k in 0..<seconds {
            let center = k * 48000
            let lo = max(0, center - 2000), hi = min(samples.count, center + 2000)
            var best = lo, bestV: Float = 0
            for i in lo..<hi where abs(samples[i]) > bestV { bestV = abs(samples[i]); best = i }
            // click 是 48 样本的满幅方波，AAC 后峰值落在窗口内；允许 ±48 样本（1 ms）
            XCTAssertLessThanOrEqual(abs(best - center), 48, "第 \(k) 个 click 峰在 \(best)，期望 \(center) ± 48")
            XCTAssertGreaterThan(bestV, 0.5, "第 \(k) 个 click 幅度")
        }
    }
}
