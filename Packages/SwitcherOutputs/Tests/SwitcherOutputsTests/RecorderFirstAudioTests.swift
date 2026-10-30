import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// N10（Codex 10-22 审查、AO01 实录）：录制器收到的第一块音频晚于起点（来源开录时没就绪、入口积压丢了最早的块）时，原来只处理"早于起点要裁"，
/// 不补前导静音——首块写到样本 0，下一块才按漂移补静音，声音整体提前、总时长又基本对得上（47999 样本），时长检查看不出来。
/// 现在首块晚到先补起点到它之间的静音（受停止边界限制，同漂移分支）再锚定。四种：早到（裁，原有）、晚到、整块越过停止边界、只有一块。
/// 都是真录 1 s（320×240 / 60 fps，LPCM），ffmpeg 解码看首个非零样本的位置。
final class RecorderFirstAudioTests: XCTestCase {
    private let format = ProgramFormat(width: 320, height: 240, frameRate: .fps60)
    private let stopTick = Tick(60)

    override func setUpWithError() throws {
        try FFprobe.requireAvailable()
    }

    /// 一块 256 样本、两声道同值；`startSample` = 块首相对起点（t0）的样本位置（负 = 早于起点）。
    private struct Block {
        var startSample: Int
        var values: [Float]
        init(_ startSample: Int, _ value: Float) { self.startSample = startSample; values = Array(repeating: value, count: 256) }
        init(_ startSample: Int, values: [Float]) { self.startSample = startSample; self.values = values }
    }

    private func feed(_ blocks: [Block], to rec: Recorder, clock: TickClockSpec) {
        for b in blocks {
            b.values.withUnsafeBufferPointer { v in
                let pointers: [UnsafePointer<Float>] = [v.baseAddress!, v.baseAddress!]
                pointers.withUnsafeBufferPointer { buf in
                    rec.consumeAudio(planes: buf.baseAddress!, channelCount: 2, frameCount: b.values.count,
                                     hostTime: clock.t0 + HostDuration(seconds: Double(b.startSample) / 48000))
                }
            }
        }
    }

    /// 录 [0, 60) 拍、停在 60（1 s）。audioBeforeVideo：音频在第一帧视频之前送——writer 这时还没建，块留在环里，
    /// 先 setStopTick(60) 再喂视频，writer 建好时边界已知（"整块越过边界的首块"走 drainAudio 那条路，而不是在入口就丢）。
    private func record(_ name: String, codec: AudioCodec = .pcm, _ blocks: [Block], audioBeforeVideo: Bool = false) throws
        -> (result: RecordingResult, samples: [Float], counters: RecorderCounters) {
        let rec = Recorder(configuration: .init(url: TestPaths.file("\(name).mov"), format: format, audio: .init(codec: codec), minimumFreeBytes: 0))
        let clock = TickClockSpec(t0: HostClock.now(), frameRate: format.frameRate)
        try rec.start(at: RecordingStart(clock: clock, tick: .zero))
        let feeder = try PatternFeeder(configuration: .init(format: format))
        if audioBeforeVideo {
            feed(blocks, to: rec, clock: clock)
            XCTAssertEqual(rec.setStopTick(stopTick), stopTick)
        }
        _ = try feeder.feed(consumers: [rec], clock: clock, ticks: Tick.zero..<stopTick, pacing: .fastest(readyToAccept: { !rec.isQueueFull }))
        if !audioBeforeVideo { feed(blocks, to: rec, clock: clock) }
        let result = try stopAndWait(rec, atTick: stopTick)
        let samples = result.audioFrames > 0 ? try FFprobe.decodeAudioMono(result.url) : []
        return (result, samples, rec.counters)
    }

    private func firstLoud(_ samples: [Float], above threshold: Float = 0.1) -> Int? { samples.firstIndex { abs($0) > threshold } }

    /// 晚到（Codex 的 Audit20261022RecorderTests 搬过来改名，喂法照旧：先喂完视频、再送音频、再停）：首块在 t0 + 0.5 s、值 0.6，
    /// 后面 93 块静音 → 解码首个非零样本 = 24000 ± 1（原来是 0）；起点到首块之间是补的静音，不算漂移校正（原来第二块要硬校正一次）。
    /// 总长不断言：最后一块跨边界，它被处理时边界知不知道取决于 writer 队列排得快慢（裁不裁 64 个样本），见下面预告边界的几条。
    func testN10_lateFirstAudioKeepsTimestamp() throws {
        let blocks = (0..<94).map { Block(24000 + $0 * 256, $0 == 0 ? 0.6 : 0) }
        let (result, samples, c) = try record("n10-late-first-audio", blocks)
        let first = firstLoud(samples)
        print("N10 晚到：首个非零样本 \(first ?? -1)（期望 24000 ± 1），音轨 \(samples.count) 样本 / audioFrames \(result.audioFrames)，硬校正 \(c.audioCorrections)，越界 \(c.audioFramesBeyondStop)")
        XCTAssertEqual(try XCTUnwrap(first), 24000, accuracy: 1, "首块的时间戳是 t0 + 0.5 s")
        XCTAssertEqual(c.audioCorrections, 0, "首块的前导静音不是漂移校正；之后的块正好接上")
    }

    /// 同上，默认的 AAC：解码出的首个响样本也在 t0 + 0.5 s 附近（AAC 帧 1024 样本、起音会被抹开一点，只要求在一帧之内；原来在 0）。
    func testN10_lateFirstAudioKeepsTimestamp_aac() throws {
        let blocks = (0..<94).map { Block(24000 + $0 * 256, $0 == 0 ? 0.6 : 0) }
        let (_, samples, _) = try record("n10-late-first-audio-aac", codec: .aac, blocks)
        let first = firstLoud(samples)
        print("N10 晚到（AAC）：首个响样本 \(first ?? -1)（期望 24000 附近，一个 AAC 帧之内）")
        XCTAssertEqual(try XCTUnwrap(first), 24000, accuracy: 1024)
    }

    /// 早到（原有的裁切照旧）：首块从 t0 − 100 样本开始，前 100 个样本（0.9）在起点之前要裁掉；第 47 块（11932）的 0.6 落在它自己的位置上；
    /// 边界预告过，跨边界的最后一块裁到边界，总长 48000。
    func testN10_earlyFirstAudioStillTrimmedToOrigin() throws {
        let toneAt = 156 + 46 * 256
        var blocks = [Block(-100, values: Array(repeating: 0.9, count: 100) + Array(repeating: 0, count: 156))]
        blocks += (0..<187).map { Block(156 + $0 * 256, 156 + $0 * 256 == toneAt ? 0.6 : 0) }
        let (result, samples, c) = try record("n10-early-first-audio", blocks, audioBeforeVideo: true)
        print("N10 早到：首个非零样本 \(firstLoud(samples) ?? -1)（期望 \(toneAt)），最大值 \(samples.map { abs($0) }.max() ?? 0)，音轨 \(samples.count)")
        // ffmpeg 立体声下混单声道是两路各乘 1/√2 再加：0.9 → 1.27、0.6 → 0.85
        XCTAssertNil(firstLoud(samples, above: 1.0), "起点之前的 100 个样本被裁掉了")
        XCTAssertEqual(try XCTUnwrap(firstLoud(samples)), toneAt, accuracy: 1)
        XCTAssertEqual(samples.count, 48000, accuracy: 1)
        XCTAssertEqual(c.audioCorrections, 0)
        XCTAssertGreaterThan(result.audioFrames, 0)
    }

    /// 只有一块、晚到：首块在 t0 + 0.5 s，之后再没有音频 → 文件里 24000 个样本的静音 + 这一块（声音在 24000，原来在 0）；
    /// 音轨没到边界，录制器等到宽限到期照常封口。
    func testN10_singleLateBlockOnly() throws {
        let (result, samples, c) = try record("n10-single-late-block", [Block(24000, 0.6)])
        print("N10 只有一块：首个非零样本 \(firstLoud(samples) ?? -1)（期望 24000），音轨 \(samples.count) 样本")
        XCTAssertEqual(try XCTUnwrap(firstLoud(samples)), 24000, accuracy: 1)
        XCTAssertEqual(samples.count, 24256, accuracy: 1, "补的静音 + 这一块")
        XCTAssertEqual(result.audioFrames, 24256, accuracy: 1)
        XCTAssertEqual(c.audioCorrections, 0)
    }

    /// 首块整块越过停止边界（块首 = t0 + 1.2 s ≥ 边界 1 s；块在环里等 writer 时边界已经预告）：照旧只计越界、不写，也不补静音
    /// （补到边界的话就和"入口直接丢"的同一块结果不一样了）；音轨里一个样本都没有，录制照常完成。
    func testN10_firstAudioBlockBeyondStop() throws {
        let (result, samples, c) = try record("n10-first-block-beyond-stop", [Block(57600, 0.6)], audioBeforeVideo: true)
        print("N10 整块越界：audioFrames \(result.audioFrames)，越界样本 \(c.audioFramesBeyondStop)，视频 \(result.videoFrames)")
        XCTAssertEqual(result.videoFrames, 60)
        XCTAssertEqual(result.audioFrames, 0, "越界的块不写，起点到边界也不补静音")
        XCTAssertEqual(c.audioFramesBeyondStop, 256)
        XCTAssertTrue(samples.isEmpty)
        let probe = try FFprobe.probe(result.url)
        XCTAssertEqual(probe.exitCode, 0, probe.stderr)
        XCTAssertEqual(probe.video?.duration ?? 0, 1, accuracy: 1.0 / 60, "视频照常")
    }

    /// 首块跨过停止边界（块首 t0 + 0.999 s，256 样本，边界 1 s）：前导静音 + 块裁到边界，音轨正好到边界、声音在 47952。
    func testN10_lateFirstBlockStraddlingStop_paddedAndTrimmedToBoundary() throws {
        let start = 48000 - 48
        let (result, samples, c) = try record("n10-first-block-straddles-stop", [Block(start, 0.6)], audioBeforeVideo: true)
        print("N10 首块跨边界：首个非零样本 \(firstLoud(samples) ?? -1)（期望 \(start)），音轨 \(samples.count)，越界 \(c.audioFramesBeyondStop)")
        XCTAssertEqual(try XCTUnwrap(firstLoud(samples)), start, accuracy: 1)
        XCTAssertEqual(samples.count, 48000, accuracy: 1, "不越过边界")
        XCTAssertEqual(Int(result.audioFrames), 48000, accuracy: 1)
        XCTAssertEqual(Int(c.audioFramesBeyondStop), 256 - 48, accuracy: 1, "块里边界之后的样本只计数")
    }
}
