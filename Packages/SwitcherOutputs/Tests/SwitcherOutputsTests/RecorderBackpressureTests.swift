import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// D05 顺带（prompt 118 交付 1）：端到端录制背压探针——录制器的音频入口环被人为拖慢的消费者顶满，写 PCM 录像再读回来逐块核。
///
/// 拖慢：`AudioBlockRing.consumerStallMicrosecondsForTesting`（只在 DEBUG 构建里有）让 writer 每次 pop 之后睡 10 ms 才读块 →
/// 消费 ≤ 100 块 / 秒 < 生产 187.5 块 / 秒（256 帧一块），环（256 块）约 2.9 s 后满，之后一直满、满了丢最旧。
/// 音轨（LPCM 24 bit，样本能逐值核）：
/// - 声道 0 = 块签名：第 k 块整块都是 (k mod 2048 + 1) / 4096（24 bit 精确）。写进文件的每一段要么是完整的一块、要么是录制器补的静音（0），
///   块号严格递增（丢块 = 跳号）。原实现环满之后几乎每块都读到后来覆盖进去的块：块号倒退、同一块写两遍。
/// - 声道 1 = 1 kHz 正弦 + 每秒一声 click（TestSignal，按绝对样本号连续），给人听丢块 / 补静音处是什么声音。
/// 默认录 6 s（满约 3 s）；`SWITCHER_D05_BACKPRESSURE_SECONDS=23` 是 prompt 要的"满 20 s"。录像留在 $SWITCHER_TEST_OUTPUT 或临时目录。
final class RecorderBackpressureTests: XCTestCase {
    func testD05_A1_recorderBackpressure_recordedBlocksWholeOrDropped() throws {
        #if DEBUG
        try FFprobe.requireAvailable()
        let seconds = ProcessInfo.processInfo.environment["SWITCHER_D05_BACKPRESSURE_SECONDS"].flatMap(Double.init) ?? 6
        let stallMicros = UInt32(ProcessInfo.processInfo.environment["SWITCHER_D05_STALL_US"].flatMap(Int.init) ?? 10_000)
        let format = ProgramFormat.hd720p60
        let ticks = Int(seconds * Double(format.frameRate.nominalFramesPerSecond))
        let url = TestPaths.file("d05-backpressure-\(Int(seconds))s.mov")
        let recorder = Recorder(configuration: .init(url: url, format: format, video: VideoEncodeSettings(bitrateBps: 2_000_000),
                                                     audio: AudioEncodeSettings(codec: .pcm), name: "d05-backpressure"))
        let feeder = try PatternFeeder(configuration: .init(format: format))
        let t0 = HostClock.now() + HostDuration(milliseconds: 300)
        let clock = TickClockSpec(t0: t0, frameRate: format.frameRate)
        let signal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: format.frameRate))
        let audio = SignatureToneFeeder(signal: signal)
        AudioBlockRing.consumerStallMicrosecondsForTesting.store(stallMicros, ordering: .relaxed)
        defer { AudioBlockRing.consumerStallMicrosecondsForTesting.store(0, ordering: .relaxed) }
        try recorder.start(at: RecordingStart(clock: clock, tick: .zero))
        let fed = try feeder.feed(consumers: [recorder], clock: clock, ticks: Tick.zero..<Tick(Int64(ticks)), pacing: .realTime) { _, tickTime in
            audio.feed(upTo: tickTime, to: recorder)
        }
        let whileFull = recorder.counters
        // 喂完：不再拖慢，让环尽快排空、按边界封口
        AudioBlockRing.consumerStallMicrosecondsForTesting.store(0, ordering: .relaxed)
        audio.flush(upToSample: signal.sampleIndex(at: clock.time(of: Tick(Int64(ticks)))), to: recorder)
        let result = try stopAndWait(recorder, atTick: Tick(Int64(ticks)))
        let c = recorder.counters
        let pcm = try decodePCMStereo(result.url)
        let a = SignatureAnalysis(channel0: pcm.left)
        let tone = ToneGapAnalysis(channel1: pcm.right)
        print("""
            D05 背压探针（\(seconds) s，pop 后睡 \(stallMicros) µs）：喂 \(audio.blocksFed) 块 / \(fed.framesFed) 帧（视频晚点 \(fed.lateTicks)）
              录制器：环满丢块 \(c.audioBlocksDropped)（喂完那一刻 \(whileFull.audioBlocksDropped)），补静音 / 丢样本硬校正 \(c.audioCorrections) 次，
                     writer 不接丢样本 \(c.audioFramesDroppedTimeout)，封口后到的 \(c.audioFramesDroppedAfterStop)，越界 \(c.audioFramesBeyondStop)；
                     视频写入 \(result.videoFrames) 帧（writer 不接 \(c.videoFramesRejected)），音频写入 \(result.audioFrames) 帧 = \(String(format: "%.2f", Double(result.audioFrames) / 48000)) s
              声道 0（块签名）：\(a)
              声道 1（1 kHz 正弦）：\(tone)
              录像：\(result.url.path)
            """)
        XCTAssertGreaterThan(c.audioBlocksDropped, 0, "环确实被顶满过（消费者被拖慢）")
        XCTAssertGreaterThan(a.wholeBlocks, 0, "写进去了块")
        XCTAssertEqual(a.misplaced, 0, "块的样本不是它自己 PTS 那一块的（读到了 pop 之后才推进来的块）：\(a.firstProblem)")
        XCTAssertEqual(a.notWhole, 0, "一段里混了两块：\(a.firstProblem)")
        XCTAssertEqual(a.repeatedOrBackwards, 0, "同一块写了两遍 / 块号倒退：\(a.firstProblem)")
        #else
        throw XCTSkip("要 DEBUG 构建：拖慢消费者的开关 AudioBlockRing.consumerStallMicrosecondsForTesting 只在 DEBUG 里有")
        #endif
    }

    /// 读回音轨：两声道各一份 float（ffmpeg 把 24 bit LPCM 转成 f32le，n / 2^23 精确）。
    private func decodePCMStereo(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let raw = url.deletingPathExtension().appendingPathExtension("f32")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: FFprobe.ffmpegPath)
        p.arguments = ["-v", "error", "-y", "-i", url.path, "-map", "0:a:0", "-f", "f32le", "-c:a", "pcm_f32le", raw.path]
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = try Data(contentsOf: raw)
        try? FileManager.default.removeItem(at: raw)
        let interleaved: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(interleaved.count / 2)
        right.reserveCapacity(interleaved.count / 2)
        var i = 0
        while i + 1 < interleaved.count { left.append(interleaved[i]); right.append(interleaved[i + 1]); i += 2 }
        return (left, right)
    }
}

/// 声道 0 = 块签名、声道 1 = TestSignal 的正弦（按绝对样本号），256 帧一块，PTS = 块首样本时刻。
final class SignatureToneFeeder {
    static let blockFrames = 256
    let signal: TestSignal
    private(set) var nextSample: Int64 = 0
    private(set) var blocksFed = 0
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let planes: UnsafeMutablePointer<UnsafePointer<Float>>

    init(signal: TestSignal) {
        self.signal = signal
        left = .allocate(capacity: Self.blockFrames)
        right = .allocate(capacity: Self.blockFrames)
        planes = .allocate(capacity: 2)
        planes[0] = UnsafePointer(left)
        planes[1] = UnsafePointer(right)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        planes.deallocate()
    }

    /// 第 k 块（k = 块首样本号 / 256）的签名值：(k mod 2048 + 1) / 4096，24 bit 里精确（= 整数 × 2^-12）。
    static func signature(block k: Int64) -> Float { Float(k % 2048 + 1) / 4096 }

    private func push(frames n: Int, to recorder: Recorder) {
        let v = Self.signature(block: nextSample / Int64(Self.blockFrames))
        for i in 0..<n { left[i] = v }
        signal.render(into: right, frameCount: n, startingAt: nextSample)
        recorder.consumeAudio(planes: UnsafePointer(planes), channelCount: 2, frameCount: n, hostTime: signal.hostTime(ofSample: nextSample))
        nextSample += Int64(n)
        blocksFed += 1
    }

    func feed(upTo time: HostTime, to recorder: Recorder) {
        let target = signal.sampleIndex(at: time)
        while target - nextSample >= Int64(Self.blockFrames) { push(frames: Self.blockFrames, to: recorder) }
    }

    func flush(upToSample end: Int64, to recorder: Recorder) {
        while nextSample < end { push(frames: Int(min(Int64(Self.blockFrames), end - nextSample)), to: recorder) }
    }
}

/// 声道 0 逐段核：连续同值的一段 = 一块（或录制器补的静音 0）。第一段（起点裁过）与最后一段（边界裁过）可以不满一块。
/// 判据：
/// - 错位：块的内容号与它在文件里的位置（起点 = 0 号块，录制器按 PTS 摆、补静音，误差 ≤ 一帧 ≈ 3 块）差 > 8 块——
///   原实现环满时读到的是 pop 之后才推进来的块（内容号比位置大约一个环容量 = 256 块），正是这一项；
/// - 不整块：中间某段长度不是 256 的整数倍（一块里混了两块）；
/// - 重复 / 倒退：同一块连写两遍、或内容号比上一段小。
struct SignatureAnalysis: CustomStringConvertible {
    var wholeBlocks = 0
    var silenceRuns = 0
    var silenceFrames = 0
    var misplaced = 0
    var maxMisplacementBlocks = 0
    var notWhole = 0
    var repeatedOrBackwards = 0
    var skippedBlocks = 0
    var firstProblem = ""

    var problems: Int { misplaced + notWhole + repeatedOrBackwards }

    init(channel0 samples: [Float]) {
        let blockFrames = SignatureToneFeeder.blockFrames
        var runs: [(value: Float, start: Int, length: Int)] = []
        var i = 0
        while i < samples.count {
            var j = i + 1
            while j < samples.count && samples[j] == samples[i] { j += 1 }
            runs.append((samples[i], i, j - i))
            i = j
        }
        func note(_ text: String) { if firstProblem.isEmpty { firstProblem = text } }
        var lastBlock: Int?
        for (index, run) in runs.enumerated() {
            if run.value == 0 {
                silenceRuns += 1
                silenceFrames += run.length
                continue
            }
            let id = Int((run.value * 4096).rounded()) - 1   // 内容号 mod 2048
            let edge = index == 0 || index == runs.count - 1
            if run.length % blockFrames != 0 && !edge {
                notWhole += 1
                note("第 \(run.start) 帧起一段 \(run.length) 帧（块号 \(id)），不是整块")
            }
            let blocksInRun = max(1, run.length / blockFrames)
            if blocksInRun > 1 {
                repeatedOrBackwards += blocksInRun - 1
                note("第 \(run.start) 帧起块号 \(id) 连写了 \(blocksInRun) 块")
            }
            // 位置号：这一段的最后一个样本所在的块（起点那一段被裁过头，用尾巴算）
            let positionBlock = (run.start + run.length - 1) / blockFrames
            var d = (id - positionBlock % 2048 + 2048) % 2048
            if d >= 1024 { d -= 2048 }
            maxMisplacementBlocks = max(maxMisplacementBlocks, abs(d))
            if abs(d) > 8 {
                misplaced += 1
                note("第 \(run.start) 帧（该是 \(positionBlock % 2048) 号块的位置）写的是 \(id) 号块的样本，差 \(d) 块")
            }
            if let last = lastBlock {
                let step = (id - last + 2048) % 2048
                if step == 0 || step >= 1024 {
                    repeatedOrBackwards += 1
                    note("第 \(run.start) 帧：块号 \(last) 之后是 \(id)（倒退 / 重复）")
                } else {
                    skippedBlocks += step - 1
                }
            }
            lastBlock = id
            wholeBlocks += blocksInRun
        }
    }

    var description: String {
        "整块 \(wholeBlocks)，跳号（丢的块）\(skippedBlocks)，补静音 \(silenceRuns) 段共 \(String(format: "%.1f", Double(silenceFrames) / 48)) ms；"
            + "错位 \(misplaced)（最大差 \(maxMisplacementBlocks) 块）、不整块 \(notWhole)、重复 / 倒退 \(repeatedOrBackwards)"
            + (firstProblem.isEmpty ? "" : "（首例 \(firstProblem)）")
    }
}

/// 声道 1（1 kHz 正弦，−20 dBFS）听感的代理量：静音段（补的静音）与相位跳变（相邻样本差远超正弦的最大斜率 = 咔哒声）。
struct ToneGapAnalysis: CustomStringConvertible {
    var silentGaps = 0
    var longestGapMs = 0.0
    var jumps = 0

    init(channel1 samples: [Float]) {
        var zeros = 0
        for i in 0..<samples.count {
            if samples[i] == 0 { zeros += 1; continue }
            if zeros >= 48 {   // ≥ 1 ms 的整段 0（正弦过零只有 1 个样本是 0）
                silentGaps += 1
                longestGapMs = max(longestGapMs, Double(zeros) / 48)
            }
            zeros = 0
            if i > 0, samples[i - 1] != 0, abs(samples[i] - samples[i - 1]) > 0.04 { jumps += 1 }
        }
    }

    var description: String {
        "≥ 1 ms 的静音段 \(silentGaps)（最长 \(String(format: "%.1f", longestGapMs)) ms），相邻样本跳变 > 0.04（正弦最大斜率 0.013 的 3 倍）\(jumps) 处（click 的两条边每秒 2 处）"
    }
}
