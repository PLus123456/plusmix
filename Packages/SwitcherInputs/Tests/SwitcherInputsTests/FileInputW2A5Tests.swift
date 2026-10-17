import AVFoundation
import CoreVideo
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
@testable import SwitcherInputs

/// W2-A5（prompt 117）：Codex 2026-10-13 审查报的文件输入五条（reports/codex-debug-audit-20261013.md §1.4 D13 / D14 / D15、§1.2 D01、§5 末段）。
/// 每条先按 Codex 的触发条件复现（他的探针：1 s / 30 帧小文件、1080p60 节目、真帧槽），再验修好后的行为。
/// 小片段现场用 AVAssetWriter 写（帧号图案 640×360 30 fps，解码后能读回帧号）；方向用例另用 Tests/Fixtures/w2a5-rot90-320x240.mov（ffmpeg 造，README）。
final class FileInputW2A5Tests: XCTestCase {
    private func makeTiming(_ format: ProgramFormat = .hd1080p60, leadMs: Double = 80) -> ProgramTiming {
        ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: leadMs))
    }

    private func makeInput(timing: ProgramTiming, slot: LockFreeFrameSlot, path: String, endAction: FileEndAction = .loop,
                           rate: Double = 1) throws -> FileInput {
        try FileInput(number: 1, name: "文件", path: path, endAction: endAction, rate: rate, timing: timing, videoSlot: slot)
    }

    private func startAndWaitLive(_ input: FileInput, timeoutMs: Double = 3000) throws {
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: timeoutMs) { input.state == .live }, "start 后 \(timeoutMs) ms 内没进 live：\(input.state) \(input.lastError ?? "")")
    }

    private func anchor(of input: FileInput, timeoutMs: Double = 3000) throws -> Tick {
        XCTAssertTrue(waitUntil(timeoutMs: timeoutMs) { input.playbackStartTick != nil }, "锚点 \(timeoutMs) ms 内没定下来")
        return try XCTUnwrap(input.playbackStartTick)
    }

    private func picks(_ timing: ProgramTiming, slot: LockFreeFrameSlot, from: Tick, count: Int) -> [Pick] {
        TickDriver(timing: timing).run(from: from, count: count) { n, t in Pick(tick: n, tickTime: t, frame: slot.latest(atOrBefore: t)) }
    }

    /// 帧槽里现在那一帧的帧号。
    private func shownNumber(_ slot: LockFreeFrameSlot) -> Int? { frameNumber(of: slot.latest(atOrBefore: HostClock.now())) }

    /// 帧槽里 pts 已到的最新一帧（刚进 live 时第一帧的 pts 还在 pushLead 之后，等它到点）。
    private func currentFrame(_ slot: LockFreeFrameSlot, timeoutMs: Double = 1000) throws -> Frame {
        _ = waitUntil(timeoutMs: timeoutMs, pollMs: 1) { slot.latest(atOrBefore: HostClock.now()) != nil }
        return try XCTUnwrap(slot.latest(atOrBefore: HostClock.now()), "帧槽里 \(timeoutMs) ms 内没有到点的帧")
    }

    /// Codex 的探针素材：1 s、30 帧（30 fps）；这里画帧号图案（640×360：320 宽的图案块只有 4 像素，H.264 之后读不稳）。
    private static func oneSecondClip() throws -> URL {
        let url = RepoPaths.output.appendingPathComponent("w2a5-1s-30f.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try LoopClipWriter.write(to: url, width: 640, height: 360, fps: 30, frames: 30, content: .testPattern(background: .gray(level: 64)))
        }
        return url
    }

    private func sleepMs(_ ms: Double) { usleep(UInt32(ms * 1000)) }

    // MARK: D13 暂停紧跟定位

    /// Codex D13：1 s 文件推到第 4 帧时连着 `pause(); seek(toSeconds: 0.5)`（App 同一快照先 pause 再 seek——InputRuntime.syncPlayback 的顺序），
    /// 暂停还没被推帧线程落实，旧代码的 seek 换了代 / 锚点却留着"待落实"，推帧线程随后用上一代最后推出的帧（≈ 0.1 s）覆盖定位目标：
    /// 0.4 s 后仍停在 0.1 s。修好：新定位的代次优先于旧的暂停请求——停在 0.5 s（第 15 帧）、仍暂停、live；恢复后从 15 接着播。
    /// 反过来的顺序（seek 紧跟 pause）、暂停稳定后再定位（原来就对）一并钉住。
    func testD13_pauseThenSeekBeforePauseApplied_holdsAtSeekTarget() throws {
        let url = try Self.oneSecondClip()
        for order in ["pause→seek", "seek→pause", "暂停稳定后 seek"] {
            let timing = makeTiming()
            let slot = LockFreeFrameSlot(capacity: 3)
            let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .holdLastFrame)
            defer { input.stop() }
            try startAndWaitLive(input)
            XCTAssertTrue(waitUntil(timeoutMs: 3000, pollMs: 1) { input.counters.framesPushed >= 4 }, "\(order)：没推到第 4 帧")
            switch order {
            case "pause→seek":
                input.pause()
                XCTAssertFalse(input.pauseIsApplied, "\(order)：触发条件是暂停还没落实就来了定位")
                input.seek(toSeconds: 0.5)
            case "seek→pause":
                input.seek(toSeconds: 0.5)
                input.pause()
            default:
                input.pause()
                XCTAssertTrue(waitUntil(timeoutMs: 500, pollMs: 1) { input.pauseIsApplied }, "暂停没落实")
                input.seek(toSeconds: 0.5)
            }
            sleepMs(400)
            XCTAssertEqual(shownNumber(slot), 15, "\(order)：定位 0.5 s（第 15 帧）0.4 s 后画面该在 15：\(input.fileCountersSnapshot) \(input.counters)")
            XCTAssertEqual(input.positionSeconds, 0.5, accuracy: 1.0 / 30 / 2, "\(order)：位置该在 0.5 s")
            XCTAssertTrue(input.isPaused, "\(order)：仍暂停")
            XCTAssertEqual(input.state, .live, "\(order)：暂停不是无信号")
            sleepMs(150)
            XCTAssertEqual(shownNumber(slot), 15, "\(order)：一直停在 15")
            // 恢复：从停住的 15 接着播
            input.resume()
            let resumed = picks(timing, slot: slot, from: try anchor(of: input), count: 8).compactMap(\.number)
            XCTAssertEqual(resumed.first, 15, "\(order)：恢复后第一帧是停住的那帧：\(resumed)")
            XCTAssertTrue(resumed.allSatisfy { $0 >= 15 && $0 <= 19 }, "\(order)：恢复后接着 15 往后播（30 fps 文件、60 fps 节目每帧两拍）：\(resumed)")
            input.stop()
        }
    }

    /// D13 的同一个竞争窗口（不暂停时）：推帧线程读快照、睡到拍点的这段时间里来了定位，小文件重开 reader + 解首帧只要几 ms，
    /// 新代的首帧在推帧线程醒来前就进了队列——原来按"代数不等 = 旧代"扔掉，定位后首帧变成目标 + 1。连着定位 12 次，每次首个新帧号都是目标。
    func testD13_seekWhilePlaying_fastReopen_firstNewFrameIsTargetEveryTime() throws {
        let url = try Self.oneSecondClip()
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .loop)
        defer { input.stop() }
        try startAndWaitLive(input)
        var misses: [String] = []
        for (i, target) in [5, 20, 9, 27, 14, 3, 22, 11, 18, 7, 25, 16].enumerated() {
            sleepMs(Double(7 + (i * 5) % 13))   // 定位落在一拍里不同的相位
            input.seek(toFrame: target)
            let after = picks(timing, slot: slot, from: try anchor(of: input), count: 4).compactMap(\.number)
            if after.first != target { misses.append("目标 \(target)：\(after)") }
        }
        XCTAssertTrue(misses.isEmpty, "定位后首帧不是目标 \(misses.count) / 12 次：\(misses)")
        XCTAssertEqual(input.fileCountersSnapshot.seeks, 12)
    }

    // MARK: D14 片尾预解码窗口里开循环

    /// Codex D14：不循环的 1 s 文件，解码线程已收完 30 帧（放了结尾哨兵、只等换代）、推帧线程才推到第 28 帧，这时打开循环：
    /// 旧代码的 setter 只在 reachedEnd 已为真时才从头来，哨兵仍按"停在末帧"收尾 → noSignal、30 帧、loops 0、seeks 0（两次复现相同）。
    /// 修好：接着从头循环——不进 noSignal、loops 计数涨、不走定位（seeks 0）、帧号 29 → 0 接上。按 Codex 的条件跑两次，每次都要卡进窗口（机器忙卡不进就重来）。
    func testD14_loopEnabledWhileDecoderAtEOFButPacerNotYet_keepsLooping() throws {
        let url = try Self.oneSecondClip()
        var hits = 0, attempts = 0
        while hits < 2 && attempts < 10 {
            attempts += 1
            let timing = makeTiming()
            let slot = LockFreeFrameSlot(capacity: 3)
            let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .holdLastFrame)
            defer { input.stop() }
            try startAndWaitLive(input)
            // Codex 的探针：推到第 28 帧后再等 10 ms（解码线程这时已读到尾、放了哨兵在等换代；推帧线程离末帧显示完还有 ≥ 33 ms）
            let reached = waitUntil(timeoutMs: 3000, pollMs: 0.5) { input.counters.framesReceived >= 30 && input.counters.framesPushed >= 28 }
            sleepMs(10)
            let before = input.counters
            guard reached, before.framesPushed < 30, input.state == .live, input.decoderParkedAtEnd else {
                input.stop()
                continue   // 没卡进"解码线程已放哨兵、推帧线程只推到 28–29 帧"的窗口：重来
            }
            input.endAction = .loop
            hits += 1
            sleepMs(400)
            let fc = input.fileCountersSnapshot
            let c = input.counters
            XCTAssertEqual(input.state, .live, "第 \(hits) 次：开了循环不该进 noSignal（开之前 received \(before.framesReceived) pushed \(before.framesPushed)）：\(fc) \(c)")
            XCTAssertEqual(c.noSignalTransitions, 0, "第 \(hits) 次：中途也没进过 noSignal：\(c)")
            XCTAssertGreaterThanOrEqual(fc.loops, 1, "第 \(hits) 次：loops 该涨：\(fc)")
            XCTAssertEqual(fc.seeks, 0, "第 \(hits) 次：窗口里开循环是接着下一圈，不是定位从头：\(fc)")
            XCTAssertGreaterThan(c.framesPushed, 30, "第 \(hits) 次：开循环之后接着推第二圈：\(c)")
            XCTAssertNotNil(shownNumber(slot), "第 \(hits) 次：画面是图案帧")
            // 再看一秒：每拍帧号逐个往后（mod 30），第二圈接着播
            let more = picks(timing, slot: slot, from: timing.tick(at: HostClock.now()) + 2, count: 40).compactMap(\.number)
            var breaks = 0
            for i in 1..<more.count where more[i] != more[i - 1] && more[i] != (more[i - 1] + 1) % 30 { breaks += 1 }
            XCTAssertEqual(breaks, 0, "第 \(hits) 次：循环中帧号跳号：\(more)")
            XCTAssertEqual(input.state, .live)
            input.stop()
        }
        XCTAssertEqual(hits, 2, "\(attempts) 次里只卡进窗口 \(hits) 次")
    }

    /// D14 的对照：窗口里开了循环又马上关掉（哨兵还没播到）= 照旧停在这一圈的末帧：noSignal、帧槽留 29、位置 = 时长；之后再开循环 = 从头（W5-N 的路，seeks 1）。
    func testD14_loopToggledOnThenOffInWindow_stillEndsAtLastFrame() throws {
        let url = try Self.oneSecondClip()
        var hit = false, attempts = 0
        while !hit && attempts < 10 {
            attempts += 1
            let timing = makeTiming()
            let slot = LockFreeFrameSlot(capacity: 3)
            let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .holdLastFrame)
            defer { input.stop() }
            try startAndWaitLive(input)
            let reached = waitUntil(timeoutMs: 3000, pollMs: 0.5) { input.counters.framesReceived >= 30 && input.counters.framesPushed >= 28 }
            sleepMs(10)
            guard reached, input.counters.framesPushed < 30, input.decoderParkedAtEnd else { input.stop(); continue }
            hit = true
            input.endAction = .loop
            input.endAction = .holdLastFrame
            XCTAssertTrue(waitUntil(timeoutMs: 1000) { input.state == .noSignal }, "关回停在末帧：该播完进 noSignal：\(input.fileCountersSnapshot)")
            sleepMs(100)
            XCTAssertEqual(shownNumber(slot), 29, "帧槽保留末帧 29")
            XCTAssertEqual(input.positionSeconds, 1.0, accuracy: 1e-9, "播完停在末尾 = 时长")
            // 播完之后再开循环：当场从头（W5-N）
            input.endAction = .loop
            XCTAssertTrue(waitUntil(timeoutMs: 1000) { input.state == .live }, "播完再开循环该从头接着播")
            XCTAssertEqual(input.fileCountersSnapshot.seeks, 1, "播完之后开循环走从头定位：\(input.fileCountersSnapshot)")
            input.stop()
        }
        XCTAssertTrue(hit, "\(attempts) 次都没卡进窗口")
    }

    /// D14 带音轨：窗口里开循环之后声音也接着下一圈（音频块继续写、host time 连续），画面同上。
    func testD14_loopEnabledInWindow_withAudio_audioContinues() throws {
        let url = RepoPaths.output.appendingPathComponent("w2a5-1s-30f-audio.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try LoopClipWriter.write(to: url, width: 640, height: 360, fps: 30, frames: 30, content: .testPattern(background: .gray(level: 64)))
        }
        var hit = false, attempts = 0
        while !hit && attempts < 10 {
            attempts += 1
            let timing = makeTiming()
            let slot = LockFreeFrameSlot(capacity: 3)
            let ring = RecordingAudioRing(channelCount: 2)
            ring.keepSamplesUpTo = 0
            let input = try FileInput(number: 1, name: "文件", path: url.path, endAction: .holdLastFrame, timing: timing, videoSlot: slot, audioRing: ring)
            defer { input.stop() }
            try startAndWaitLive(input)
            XCTAssertEqual(input.info?.hasAudio, true)
            let reached = waitUntil(timeoutMs: 3000, pollMs: 0.5) { input.counters.framesReceived >= 30 && input.counters.framesPushed >= 28 }
            sleepMs(10)
            guard reached, input.counters.framesPushed < 30, input.decoderParkedAtEnd else { input.stop(); continue }
            hit = true
            input.endAction = .loop
            sleepMs(600)
            let fc = input.fileCountersSnapshot
            let c = input.counters   // stop 之前读：stop 自己会置一次 noSignal
            input.stop()
            let blocks = ring.recorded
            var gaps = 0
            if let first = blocks.first {
                for (i, b) in blocks.enumerated() {
                    let expected = first.hostTime + HostDuration(nanoseconds: Int64(i) * 256 * 1_000_000_000 / 48_000)
                    if abs(Int64(b.hostTime.ticks) - Int64(expected.ticks)) > 2 { gaps += 1 }
                }
            }
            print("D14 带音轨：\(fc)，环块 \(blocks.count)，host time 不连续 \(gaps)")
            XCTAssertEqual(c.noSignalTransitions, 0, "开了循环不该进过 noSignal：\(c)")
            XCTAssertGreaterThanOrEqual(fc.loops, 1, "loops 该涨：\(fc)")
            XCTAssertEqual(fc.seeks, 0, "接着下一圈，不是定位：\(fc)")
            // 1 s 片子 + 开循环后 0.6 s：写满 ≈ 1.5 s 的块（每块 256 帧）才说明声音接上了第二圈
            XCTAssertGreaterThanOrEqual(Double(blocks.count), 1.4 * 48_000 / 256, "声音没接着下一圈：\(blocks.count) 块，\(fc)")
            XCTAssertEqual(gaps, 0, "音频块 host time 连续（同一条时间线接着走）：\(gaps)")
        }
        XCTAssertTrue(hit, "\(attempts) 次都没卡进窗口")
    }

    // MARK: positionSeconds 播完后不取余

    /// Codex §5 末段（P3）：不循环的 1 s 文件停止出帧后 positionSeconds 仍对时长取余、继续走（实测 0.5333）。
    /// 修好：停在末尾 = 时长（停在末帧 / 黑场都是），之后不变；循环的照旧在 [0, 时长) 里。
    func testW2A5_positionSeconds_afterNonLoopEnd_staysAtDuration() throws {
        let url = try Self.oneSecondClip()
        for action in [FileEndAction.holdLastFrame, .black] {
            let timing = makeTiming()
            let slot = LockFreeFrameSlot(capacity: 3)
            let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: action)
            defer { input.stop() }
            try startAndWaitLive(input)
            XCTAssertTrue(waitUntil(timeoutMs: 3000) { input.state == .noSignal }, "\(action)：1 s 文件该播完")
            XCTAssertEqual(input.positionSeconds, 1.0, accuracy: 1e-9, "\(action)：播完 = 时长")
            sleepMs(300)
            XCTAssertEqual(input.positionSeconds, 1.0, accuracy: 1e-9, "\(action)：播完之后位置不再走")
            input.stop()
        }
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .loop)
        defer { input.stop() }
        try startAndWaitLive(input)
        var seen: [Double] = []
        for _ in 0..<30 { seen.append(input.positionSeconds); sleepMs(50) }
        XCTAssertTrue(seen.allSatisfy { $0 >= 0 && $0 < 1 }, "循环的位置在 [0, 时长) 里：\(seen)")
        XCTAssertGreaterThanOrEqual(input.fileCountersSnapshot.loops, 1, "1.5 s 至少转过一圈")
    }

    // MARK: D01 底层：速率钳位、定位不溢出

    /// Codex D01（底层一半）：`FileInput(rate: 0 / −1)` 在 precondition 崩、`rate: 1e-4` 近似成 0 后取倒数崩、`rate: 1e300` 换 Int64 溢出——整个进程 SIGTRAP。
    /// 修好：按 `FileSource.rateRange`（0.1…8，提案 031）钳进去 + lastError 一句，不崩；NaN 按 1。合法值没有提示；setter 同样钳、改回合法值提示清掉。
    func testD01_outOfRangeRate_clampedIntoRateRange_withLastError() throws {
        let path = RepoPaths.patternMov.path
        let cases: [(Double, Double)] = [(0, 0.1), (-1, 0.1), (1e-4, 0.1), (1e300, 8), (.nan, 1), (.infinity, 8), (-.infinity, 0.1), (8.0001, 8)]
        for (rate, expected) in cases {
            let input = try makeInput(timing: makeTiming(), slot: LockFreeFrameSlot(capacity: 3), path: path, rate: rate)
            XCTAssertEqual(input.rate, expected, accuracy: 1e-9, "速率 \(rate) 该钳到 \(expected)")
            XCTAssertEqual(input.lastError?.contains("播放速率"), true, "速率 \(rate)：lastError 该说一句：\(input.lastError ?? "nil")")
        }
        for rate in [FileSource.rateRange.lowerBound, 1, 1.5, FileSource.rateRange.upperBound] {
            let input = try makeInput(timing: makeTiming(), slot: LockFreeFrameSlot(capacity: 3), path: path, rate: rate)
            XCTAssertEqual(input.rate, rate, accuracy: 1e-9)
            XCTAssertNil(input.lastError, "合法速率 \(rate) 不该有提示")
        }
        // 跑起来：1e300 → 8 倍速（60 fps 文件在 60 fps 节目里每拍前进 8 帧），start 之后提示还在
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, path: path, rate: 1e300)
        defer { input.stop() }
        try startAndWaitLive(input)
        let numbers = picks(timing, slot: slot, from: try anchor(of: input) + 1, count: 12).compactMap(\.number)
        XCTAssertEqual(numbers.count, 12)
        for i in 1..<numbers.count { XCTAssertEqual((numbers[i] - numbers[i - 1] + 600) % 600, 8, "钳到 8 倍速：每拍前进 8 帧：\(numbers)") }
        XCTAssertEqual(input.lastError?.contains("播放速率"), true, "start 不该把钳位提示清掉：\(input.lastError ?? "nil")")
        XCTAssertEqual(input.state, .live)
        // setter：运行中给 0 / 1e-4 → 0.1 + 提示、不崩；改回 2 → 2、提示清掉
        input.rate = 0
        XCTAssertEqual(input.rate, 0.1, accuracy: 1e-9)
        XCTAssertEqual(input.lastError?.contains("播放速率"), true)
        input.rate = 1e-4
        XCTAssertEqual(input.rate, 0.1, accuracy: 1e-9)
        input.rate = 2
        XCTAssertEqual(input.rate, 2, accuracy: 1e-9)
        XCTAssertNil(input.lastError, "改回合法速率后提示清掉")
        // 从 8 倍速切下来：新锚点位置是按 8 倍速往前算两拍的（比解码线程领先），解码线程要追几拍（原来就这样，与钳位无关），从锚点后第 10 拍起看
        let fast = picks(timing, slot: slot, from: try anchor(of: input) + 10, count: 10).compactMap(\.number)
        XCTAssertEqual(fast.count, 10)
        for i in 1..<fast.count { XCTAssertEqual((fast[i] - fast[i - 1] + 600) % 600, 2, "速率 2：\(fast)") }
    }

    /// Codex D01：`seek(toSeconds: 1e300)` 在钳到时长之前就换 Rational / Int64，溢出崩。修好：先用 Double 钳到 [0, 时长] 再换算；
    /// 状态可解释——超过片长（含 1e300 / +∞）与原来"定位过尾 = 从头"同一口径，非有限 / 负数按 0；不在契约范围（0…一周）的给 lastError 一句；
    /// `seek(toFrame: Int.max)` 同样不溢出。之后合法的定位照常（5 s = 第 300 帧）、提示清掉。
    func testD01_hugeOrNonFiniteSeek_clampedBeforeConversion_noOverflow() throws {
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, path: RepoPaths.patternMov.path, endAction: .loop)
        defer { input.stop() }
        try startAndWaitLive(input)
        _ = picks(timing, slot: slot, from: try anchor(of: input), count: 30)   // 播到第 30 帧左右，"从头"才看得出来
        var seeks: UInt64 = 0
        for (seconds, outOfContract) in [(1e300, true), (Double.infinity, true), (Double.nan, true), (-5, true),
                                         (PlaybackLimits.maxSeekSeconds + 1, true), (12.5, false)] {
            input.seek(toSeconds: seconds)
            seeks += 1
            XCTAssertEqual(input.fileCountersSnapshot.seeks, seeks, "定位 \(seconds) 照样记一次")
            let after = picks(timing, slot: slot, from: try anchor(of: input), count: 6).compactMap(\.number)
            XCTAssertEqual(after.drop { $0 > 3 }.first, 0, "定位 \(seconds)：超过片长 / 非有限 / 负数 = 从头（第 0 帧）：\(after)")
            if outOfContract {
                XCTAssertEqual(input.lastError?.contains("定位"), true, "定位 \(seconds) 不在 0…一周：lastError 该说一句：\(input.lastError ?? "nil")")
            } else {
                XCTAssertNil(input.lastError, "定位 \(seconds) 在契约范围里（只是过了片尾）：不提示")
            }
            XCTAssertEqual(input.state, .live)
        }
        input.seek(toFrame: .max)
        let wrapped = picks(timing, slot: slot, from: try anchor(of: input), count: 6).compactMap(\.number)
        XCTAssertEqual(wrapped.drop { $0 > 3 }.first, 0, "seek(toFrame: Int.max) 不溢出、过尾从头：\(wrapped)")
        input.seek(toSeconds: 5)
        let mid = picks(timing, slot: slot, from: try anchor(of: input), count: 6).compactMap(\.number)
        XCTAssertEqual(mid.drop { $0 < 300 }.first, 300, "合法定位 5 s = 第 300 帧：\(mid)")
        XCTAssertNil(input.lastError, "合法定位之后提示清掉")
    }

    // MARK: D15 方向矩阵

    /// 仓库夹具：ffmpeg `-display_rotation 90` 打的 90° 矩阵（AVFoundation 读成 (0,−1,1,0,0,0)，逆时针 90° 才正），编码 320×240 四色象限。
    /// Codex D15：FileInput 原样出 320×240（不读 preferredTransform）。修好：出 240×320，四角与 AVFoundation 自己按矩阵转正的参照（AVAssetImageGenerator）一致。
    func testD15_rotatedFixture_outputsUpright240x320_matchingAVFoundation() throws {
        let url = RepoPaths.fixtures.appendingPathComponent("w2a5-rot90-320x240.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缺夹具：\(url.path)")
        let reference = try OrientationReference.image(url)
        XCTAssertEqual([reference.width, reference.height], [240, 320], "参照（AVAssetImageGenerator 按矩阵转正）")
        XCTAssertEqual(Quadrants.of(reference), "GWRB", "参照的四角（编码方向 RGBW 逆时针转 90°）")
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .loop)
        defer { input.stop() }
        try startAndWaitLive(input)
        XCTAssertEqual(input.info?.orientation, .rotate270, "矩阵 (0,−1,1,0) = 顺时针 270°（逆时针 90°）")
        XCTAssertEqual(input.info.map { [$0.width, $0.height] }, [320, 240], "info.width / height 仍是编码尺寸")
        XCTAssertEqual(input.info.map { [$0.displayWidth, $0.displayHeight] }, [240, 320], "转正后的尺寸")
        let frame = try currentFrame(slot)
        XCTAssertEqual([frame.width, frame.height], [240, 320], "第一帧该是转正后的 240×320")
        XCTAssertEqual(Quadrants.of(frame.pixelBuffer), Quadrants.of(reference), "第一帧内容方向与参照一致")
        XCTAssertEqual(frame.pixelFormat, .nv12)
        // 循环几圈之后仍是转正的（每圈重开 reader，转正不只做在第一帧上）
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { input.fileCountersSnapshot.loops >= 2 })
        let later = try currentFrame(slot)
        XCTAssertEqual([later.width, later.height], [240, 320])
        XCTAssertEqual(Quadrants.of(later.pixelBuffer), "GWRB")
        XCTAssertLessThanOrEqual(input.counters.distinctSurfaces, 16, "转正用的像素池稳定复用（渲染器纹理表每路 16 项）：\(input.counters)")
    }

    /// 八种轴对齐方向（四个旋转 × 是否镜像，带手机录像那样的平移）各写一段四色象限（AVAssetWriterInput.transform），
    /// FileInput 出的第一帧尺寸与四角都等于 AVAssetImageGenerator(appliesPreferredTrackTransform) 的参照。
    func testD15_allEightAxisAlignedTransforms_matchAVFoundationReference() throws {
        let w: CGFloat = 320, h: CGFloat = 240
        let cases: [(FileOrientation, CGAffineTransform)] = [
            (.identity, .identity),
            (.rotate90, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)),      // 手机竖拍（Home 键在下）
            (.rotate180, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)),
            (.rotate270, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)),
            (.flipHorizontal, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)),
            (.flipVertical, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)),
            (.transpose, CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)),
            (.transverse, CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)),
        ]
        var seen = Set<String>()
        for (expected, transform) in cases {
            let url = RepoPaths.output.appendingPathComponent("w2a5-orient-\(expected.rawValue).mov")
            try LoopClipWriter.write(to: url, width: Int(w), height: Int(h), fps: 30, frames: 10, content: .quadrants, transform: transform)
            let reference = try OrientationReference.image(url)
            let timing = makeTiming()
            let slot = LockFreeFrameSlot(capacity: 3)
            let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .loop)
            defer { input.stop() }
            try startAndWaitLive(input)
            XCTAssertEqual(input.info?.orientation, expected, "矩阵 \(transform)")
            let frame = try currentFrame(slot)
            XCTAssertEqual([frame.width, frame.height], [reference.width, reference.height], "\(expected)：尺寸与参照一致")
            let got = Quadrants.of(frame.pixelBuffer), want = Quadrants.of(reference)
            XCTAssertEqual(got, want, "\(expected)：四角与参照一致")
            XCTAssertFalse(want.contains("?"), "\(expected)：参照四角认得出：\(want)")
            seen.insert(want)
            input.stop()
        }
        XCTAssertEqual(seen.count, 8, "八种方向的参照两两不同（用例真的覆盖了八种）：\(seen)")
    }

    /// 用户在输入设置里设的旋转叠在转正之后、不重复转：同一个真渲染器（OfflineRenderer，与实时路径同一个合成 pass），
    /// FileInput 出的帧 + 用户旋转 R 与"AVFoundation 转正的参照图 + 同一个 R"画出来的 PGM 四角一致（R = 0 / 90 / 180 / 270），
    /// 且 R = 90 与 R = 0 不同（用户旋转真的叠上去了）。
    func testD15_userRotationStacksOnTopOfOrientation_notAppliedTwice() throws {
        let url = RepoPaths.fixtures.appendingPathComponent("w2a5-rot90-320x240.mov")
        let reference = try OrientationReference.image(url)
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, path: url.path, endAction: .loop)
        defer { input.stop() }
        try startAndWaitLive(input)
        let frame = try currentFrame(slot)
        input.stop()
        let renderer = try OfflineRenderer()
        let size = CGSize(width: 640, height: 640)
        var byRotation: [Double: String] = [:]
        for degrees in [0.0, 90, 180, 270] {
            var settings = InputSettings()
            settings.transform.rotationDegrees = degrees
            let state = MixerState(format: .hd1080p60,
                                   inputs: [InputConfig(number: 1, name: "文件", source: .file(path: url.path, endAction: .loop, rate: 1), settings: settings)],
                                   program: 1, preview: 0)
            let fromInput = try renderer.render(state: state, frames: [1: frame], size: size).program
            let fromReference = try renderer.render(state: state, inputs: [1: reference], size: size).program
            let a = Quadrants.ofContent(fromInput), b = Quadrants.ofContent(fromReference)
            XCTAssertEqual(a.colors, b.colors, "用户旋转 \(degrees)°：FileInput 的帧与参照画出来四角一致")
            XCTAssertEqual(a.box, b.box, "用户旋转 \(degrees)°：画面占的框一致")
            XCTAssertFalse(a.colors.contains("?"), "用户旋转 \(degrees)°：四角认得出：\(a.colors)")
            byRotation[degrees] = a.colors
        }
        XCTAssertNotEqual(byRotation[90], byRotation[0], "用户旋转 90° 真的叠上去了")
        XCTAssertEqual(Set(byRotation.values).count, 4, "四个用户旋转各不相同：\(byRotation)")
    }

    /// `FileOrientation(transform:)` 的归类：八种轴对齐矩阵（平移不影响）、带缩放的同样认、任意角度 / 退化 / 非有限的返回 nil（按原样出）。
    func testD15_orientationFromPreferredTransform_classification() {
        XCTAssertEqual(FileOrientation(transform: .identity), .identity)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)), .rotate90)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)), .rotate180)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)), .rotate270)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)), .rotate270, "ffmpeg -display_rotation 90 不带平移")
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)), .flipHorizontal)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)), .flipVertical)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)), .transpose)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)), .transverse)
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 0, b: 2, c: -2, d: 0, tx: 0, ty: 0)), .rotate90, "带缩放")
        XCTAssertEqual(FileOrientation(transform: CGAffineTransform(a: 1e-9, b: 1, c: -1, d: -1e-9, tx: 0, ty: 0)), .rotate90, "浮点噪声")
        XCTAssertNil(FileOrientation(transform: CGAffineTransform(rotationAngle: .pi / 4)), "45° 不认")
        XCTAssertNil(FileOrientation(transform: CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)), "退化矩阵")
        XCTAssertNil(FileOrientation(transform: CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)), "非有限")
        for o in FileOrientation.allCases {
            XCTAssertEqual(o.swapsAxes, [.rotate90, .rotate270, .transpose, .transverse].contains(o), "\(o) 宽高互换")
        }
    }
}

/// AVFoundation 自己按 preferredTransform 转正的参照图（AVAssetImageGenerator，appliesPreferredTrackTransform = true）。
enum OrientationReference {
    final class Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func image(_ url: URL) throws -> CGImage {
        let result = FileAsset.blocking { () async throws -> Box in
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return Box(try await gen.image(at: .zero).image)
        }
        return try result.get().image
    }
}

/// 四色象限的读法：四个象限中心（1/4、3/4 处）认成 R / G / B / W（认不出写 ?），按左上、右上、左下、右下拼成串（"RGBW" = 编码方向原样）。
/// 阈值对 BT.601 / 709、limited / full 都成立（纯红 Cr 高、纯蓝 Cb 高、纯绿 Cb / Cr 都低、白 Y 高 Cb / Cr 居中）。
enum Quadrants {
    static let points: [(Double, Double)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]

    static func classify(y: Int, cb: Int, cr: Int) -> Character {
        if y > 200, abs(cb - 128) < 30, abs(cr - 128) < 30 { return "W" }
        if cr > 180, cb < 140 { return "R" }
        if cb > 180, cr < 160 { return "B" }
        if cb < 100, cr < 100, y > 100 { return "G" }
        return "?"
    }

    static func classify(r: Int, g: Int, b: Int) -> Character {
        if r > 200, g > 200, b > 200 { return "W" }
        if r > 150, g < 100, b < 100 { return "R" }
        if g > 150, r < 100, b < 100 { return "G" }
        if b > 150, r < 100, g < 100 { return "B" }
        return "?"
    }

    /// NV12 / BGRA 像素缓冲。
    static func of(_ pb: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var out = ""
        for (fx, fy) in points {
            let x = Int(Double(w) * fx), y = Int(Double(h) * fy)
            if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA {
                guard let base = CVPixelBufferGetBaseAddress(pb) else { return "?" }
                let p = base.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
                out.append(classify(r: Int(p[2]), g: Int(p[1]), b: Int(p[0])))
            } else {
                guard let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return "?" }
                let luma = yp.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x]
                let c = cp.assumingMemoryBound(to: UInt8.self) + (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(pb, 1) + (x / 2) * 2
                out.append(classify(y: Int(luma), cb: Int(c[0]), cr: Int(c[1])))
            }
        }
        return out
    }

    /// RGBA 位图（行 0 = 图像顶行）。
    private static func rgba(_ image: CGImage) -> (UnsafeMutablePointer<UInt8>, CGContext) {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (ctx.data!.assumingMemoryBound(to: UInt8.self), ctx)
    }

    static func of(_ image: CGImage) -> String {
        let (px, ctx) = rgba(image)
        return withExtendedLifetime(ctx) {
            String(points.map { (fx, fy) -> Character in
                let p = px + Int(Double(image.height) * fy) * image.width * 4 + Int(Double(image.width) * fx) * 4
                return classify(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]))
            })
        }
    }

    /// 渲染出来的 PGM：先找非黑内容的外框（适配进节目框后有黑边），再在框的四个象限中心取色。
    static func ofContent(_ image: CGImage) -> (colors: String, box: [Int]) {
        let (px, ctx) = rgba(image)
        return withExtendedLifetime(ctx) {
            var minX = image.width, minY = image.height, maxX = -1, maxY = -1
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let p = px + y * image.width * 4 + x * 4
                    if Int(p[0]) + Int(p[1]) + Int(p[2]) > 120 {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else { return ("????", []) }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            let colors = String(points.map { (fx, fy) -> Character in
                let p = px + (minY + Int(Double(bh) * fy)) * image.width * 4 + (minX + Int(Double(bw) * fx)) * 4
                return classify(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]))
            })
            // 框按 4 像素取整比较（两条路的采样 / 缩放滤波在边上差一两个像素）
            return (colors, [minX / 4, minY / 4, bw / 4, bh / 4])
        }
    }
}
