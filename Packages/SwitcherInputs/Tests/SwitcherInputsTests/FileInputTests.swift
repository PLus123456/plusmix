import AVFoundation
import CoreVideo
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherInputs

/// FileInput 单元测试（W2-A prompt "单元"一节）：素材 Tests/Fixtures/pattern.mov（1080p60 10 s，帧号 = 帧序号，输入 ID 0，
/// 闪光每 60 帧，AAC click 每整秒）。每个测试起一个真帧槽（SwitcherEngine.LockFreeFrameSlot）+ 真实时间的拍点循环，
/// 用契约入口 `latest(atOrBefore: t_n)` 挑帧（不带余量），解图案得帧号。
final class FileInputTests: XCTestCase {
    private func makeTiming(_ format: ProgramFormat, leadMs: Double = 80) -> ProgramTiming {
        ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: leadMs))
    }

    private func makeInput(timing: ProgramTiming, slot: LockFreeFrameSlot, endAction: FileEndAction = .loop, rate: Double = 1,
                           audioRing: (any AudioRing)? = nil, path: String = RepoPaths.patternMov.path) throws -> FileInput {
        try FileInput(number: 1, name: "文件", path: path, endAction: endAction, rate: rate,
                      timing: timing, videoSlot: slot, audioRing: audioRing)
    }

    /// 起输入并等它进 live（第一帧已推进帧槽）。
    private func startAndWaitLive(_ input: FileInput, timeoutMs: Double = 3000) throws {
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: timeoutMs) { input.state == .live }, "start 后 \(timeoutMs) ms 内没进 live：\(input.state) \(input.lastError ?? "")")
    }

    /// 等锚点定下来（start / seek 后要等目标帧解出来）。
    private func anchor(of input: FileInput, timeoutMs: Double = 3000) throws -> Tick {
        XCTAssertTrue(waitUntil(timeoutMs: timeoutMs) { input.playbackStartTick != nil }, "锚点 \(timeoutMs) ms 内没定下来")
        return try XCTUnwrap(input.playbackStartTick)
    }

    private func picks(_ driver: TickDriver, slot: LockFreeFrameSlot, from: Tick, count: Int) -> [Pick] {
        driver.run(from: from, count: count) { n, t in Pick(tick: n, tickTime: t, frame: slot.latest(atOrBefore: t)) }
    }

    // MARK: 60 fps 节目下帧号连续

    func testFile_60fpsProgram_frameNumbersConsecutiveFromZero() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        let start = try anchor(of: input)
        let result = picks(driver, slot: slot, from: start, count: 120)
        let numbers = result.map(\.number)
        XCTAssertEqual(numbers.first, 0, "播放从拍 \(start) 起，第一拍就该是第 0 帧：\(result.prefix(3)) \(input.fileCountersSnapshot) \(input.counters)")
        for i in 1..<numbers.count {
            XCTAssertEqual(numbers[i], numbers[i - 1].map { $0 + 1 }, "第 \(i) 拍帧号不连续：\(result[i - 1]) → \(result[i])")
        }
        input.stop()   // 先停，帧槽统计才不会被最后一拍之后推进来的帧污染
        // pts = 拍点 − 半个节目帧（相位提前量），每帧的 ingressTime 早于 pts
        for p in result {
            guard let pts = p.pts, let ingress = p.ingressTime else { continue }
            XCTAssertEqual(pts, p.tickTime - timing.frameDuration / 2, "帧 \(p) 的 pts 应是拍点减半帧")
            XCTAssertLessThan(ingress, pts, "文件帧应在 pts 之前进帧槽（提前推）")
            XCTAssertEqual(p.inputNumber, 1)
            XCTAssertEqual(p.pixelFormat, .nv12)
        }
        let s = slot.stats
        XCTAssertEqual(s.reused, 0, "60 进 60 不该有重复：\(s)")
        XCTAssertEqual(s.dropped, 0, "不该有丢弃：\(s)")
        let c = input.counters
        XCTAssertGreaterThanOrEqual(c.framesPushed, 120)
        XCTAssertLessThanOrEqual(c.distinctSurfaces, 16, "解码器像素池应稳定复用（渲染器纹理表每路 16 项）：\(c.distinctSurfaces)")
        let fc = input.fileCountersSnapshot
        XCTAssertEqual(fc.ticksStarved, 0, "解码器不该让推帧线程等：\(fc)")
    }

    // MARK: 30 fps 节目下每个帧号只出现一次

    func testFile_30fpsProgram_eachFrameNumberAppearsOnce() throws {
        let timing = makeTiming(.hd1080p30)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        let result = picks(driver, slot: slot, from: try anchor(of: input), count: 60)
        let numbers = result.compactMap(\.number)
        XCTAssertEqual(numbers.count, 60, "每拍都该有帧：\(result.filter { $0.number == nil })")
        XCTAssertEqual(numbers.first, 0)
        XCTAssertEqual(Set(numbers).count, numbers.count, "有帧号出现了两次：\(result)")
        for i in 1..<numbers.count {
            XCTAssertEqual(numbers[i] - numbers[i - 1], 2, "60 fps 文件在 30 fps 节目里每拍前进 2 帧：\(result[i - 1]) → \(result[i])")
        }
        XCTAssertEqual(slot.stats.reused, 0)
        XCTAssertEqual(slot.stats.dropped, 0, "输入自己按拍选帧，帧槽里不该出现设计外丢弃")
        let c = input.counters
        XCTAssertGreaterThanOrEqual(c.framesRejected, 55, "被速率跳过的帧计在 framesRejected：\(c)")
        XCTAssertLessThanOrEqual(c.framesReceived - c.framesPushed - c.framesRejected, 4, "收到 = 推出 + 跳过 + 预解码队列里的：\(c)")
    }

    // MARK: 循环边界无跳号无重复

    func testFile_loopBoundary_noSkipNoRepeat() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, endAction: .loop)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        // 先定位到第 590 帧，再跨过 599 → 0 的边界
        input.seek(toFrame: 590)
        let seekTick = try anchor(of: input)
        let result = picks(driver, slot: slot, from: seekTick, count: 40)
        let numbers = result.compactMap(\.number)
        XCTAssertEqual(numbers.count, 40, "每拍都该有帧：\(result)")
        XCTAssertEqual(numbers.first, 590, "定位后首帧就是 590：\(result.prefix(3))")
        for i in 1..<numbers.count {
            XCTAssertEqual(numbers[i], (numbers[i - 1] + 1) % 600, "循环边界跳号 / 重复：\(result[i - 1]) → \(result[i])")
        }
        XCTAssertTrue(numbers.contains(599) && numbers.contains(0), "应跨过边界：\(numbers)")
        // 跨边界后 pts 仍然逐拍递增半帧相位
        for p in result { if let pts = p.pts { XCTAssertEqual(pts, p.tickTime - timing.frameDuration / 2) } }
        XCTAssertEqual(input.state, .live)
        XCTAssertEqual(slot.stats.reused, 0)
    }

    // MARK: 定位到第 300 帧后首帧就是 300

    func testFile_seekToFrame300_firstFrameIs300() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        let before = picks(driver, slot: slot, from: try anchor(of: input), count: 20)
        XCTAssertEqual(before.last?.number, 19)
        input.seek(toFrame: 300)
        let seekTick = try anchor(of: input)
        XCTAssertGreaterThan(seekTick, before.last!.tick, "定位生效的拍必须在未来")
        let after = picks(driver, slot: slot, from: seekTick, count: 30)
        // 定位后帧槽里可能还留着旧帧一两拍（解码器要重开），但第一个新帧号必须是 300，之后连续
        let fresh = after.compactMap(\.number).drop { $0 < 300 }
        XCTAssertEqual(fresh.first, 300, "定位后首帧不是 300：\(after.prefix(5))")
        let firstNewIndex = after.firstIndex { ($0.number ?? 0) >= 300 } ?? 0
        XCTAssertLessThanOrEqual(firstNewIndex, 3, "定位后 3 拍内该出新帧：\(after.prefix(5))")
        var expected = 300
        for n in fresh {
            XCTAssertEqual(n, expected, "定位后帧号不连续：\(after)")
            expected += 1
        }
        XCTAssertEqual(input.positionSeconds, Double(expected) / 60, accuracy: 0.1)
    }

    // MARK: 暂停时 pts 仍每拍刷新

    func testFile_pausedStillRefreshesPtsEveryTick() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        let running = picks(driver, slot: slot, from: try anchor(of: input), count: 12)
        input.pause()
        XCTAssertTrue(input.isPaused)
        // 暂停命令要等输入线程处理；跳过两拍再看
        let pauseTick = running.last!.tick + 3
        let paused = picks(driver, slot: slot, from: pauseTick, count: 30)
        let held = Set(paused.dropFirst(2).compactMap(\.number))
        XCTAssertEqual(held.count, 1, "暂停后应停在同一帧：\(paused)")
        let reusedBefore = slot.stats.reused
        // 后 25 拍：每拍都有一帧、pts 都等于该拍的拍点（每拍重新 push，不是帧槽的 reused）
        for p in paused.dropFirst(5) {
            XCTAssertTrue(p.hasFrame)
            XCTAssertEqual(p.pts, p.tickTime, "暂停时 pts 应每拍刷新为拍点：\(p)")
        }
        XCTAssertEqual(slot.stats.reused, reusedBefore, "暂停期间不该靠帧槽 reused 撑住画面")
        XCTAssertEqual(input.state, .live, "暂停不是无信号")
        // 恢复：从停住的帧继续
        input.resume()
        XCTAssertFalse(input.isPaused)
        let resumeTick = try anchor(of: input)
        let resumed = picks(driver, slot: slot, from: resumeTick, count: 20)
        let numbers = resumed.compactMap(\.number)
        XCTAssertEqual(numbers.first, held.first, "恢复后第一帧应是停住的那帧：\(resumed.prefix(3))")
        for i in 1..<numbers.count { XCTAssertEqual(numbers[i], numbers[i - 1] + 1, "恢复后不连续：\(resumed)") }
    }

    // MARK: 无信号：播完不循环 → noSignal 在 3 个帧间隔内置位，渲染不阻塞

    func testNoSignal_fileEndsWithoutLoop_noSignalWithinThreeIntervalsAndLatestNeverBlocks() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, endAction: .holdLastFrame)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        input.seek(toFrame: 590)
        let seekTick = try anchor(of: input)
        var noSignalAt: HostTime?
        var lastFrameTick: Tick?
        var maxLatestNs: Int64 = 0
        let result = driver.run(from: seekTick, count: 30) { n, t -> Pick in
            let before = HostClock.now()
            let f = slot.latest(atOrBefore: t)
            maxLatestNs = max(maxLatestNs, (HostClock.now() - before).nanoseconds)
            if frameNumber(of: f) == 599, lastFrameTick == nil { lastFrameTick = n }
            if noSignalAt == nil, input.state == .noSignal { noSignalAt = HostClock.now() }
            return Pick(tick: n, tickTime: t, frame: f)
        }
        XCTAssertNotNil(lastFrameTick, "没看到末帧 599：\(result)")
        XCTAssertEqual(input.state, .noSignal, "播完不循环应进 noSignal")
        XCTAssertNotNil(noSignalAt)
        if let lastFrameTick, let noSignalAt {
            let lastPts = timing.time(of: lastFrameTick)
            let intervals = (noSignalAt - lastPts).seconds / timing.frameDuration.seconds
            XCTAssertLessThanOrEqual(intervals, 3.0, "noSignal 置位晚于末帧 3 个帧间隔：\(intervals)")
        }
        // 帧槽保留最后一帧：之后每拍 latest 仍返回 599（reused），从不返回 nil，且不阻塞
        let tail = result.suffix(10)
        for p in tail { XCTAssertEqual(p.number, 599, "无信号后帧槽应保留末帧：\(p)") }
        XCTAssertLessThan(maxLatestNs, 1_000_000, "latest 不该阻塞（最大 \(maxLatestNs) ns）")
        XCTAssertGreaterThan(slot.stats.reused, 0)
        XCTAssertGreaterThanOrEqual(input.counters.noSignalTransitions, 1)
    }

    /// 结束动作 black：末帧之后帧槽里是一帧黑场，然后 noSignal。
    func testFile_endActionBlack_pushesBlackFrameThenNoSignal() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, endAction: .black)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        input.seek(toFrame: 595)
        let result = picks(driver, slot: slot, from: try anchor(of: input), count: 20)
        let last = result.last!
        XCTAssertTrue(last.hasFrame)
        XCTAssertNil(last.number, "末帧之后应是黑场（解不出帧号）：\(result)")
        XCTAssertEqual(last.probe.first, 16, "NV12 黑场 Y = 16：\(last.probe)")
        XCTAssertEqual(input.state, .noSignal)
    }

    // MARK: 速率

    func testFile_rate2_advancesTwoFramesPerTick() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, rate: 2)
        defer { input.stop() }
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        let result = picks(driver, slot: slot, from: try anchor(of: input), count: 40)
        let numbers = result.compactMap(\.number)
        XCTAssertEqual(numbers.count, 40)
        for i in 1..<numbers.count { XCTAssertEqual(numbers[i] - numbers[i - 1], 2, "速率 2 应每拍前进 2 帧：\(result)") }
    }

    // MARK: 音频：块的 host time 与视频同一时间基，样本连续

    func testFile_audioBlocksAlignedToVideoTimeline() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let ring = RecordingAudioRing(channelCount: 2)
        let input = try makeInput(timing: timing, slot: slot, audioRing: ring)
        defer { input.stop() }
        XCTAssertNotNil(input.audioRing)
        try startAndWaitLive(input)
        let driver = TickDriver(timing: timing)
        let start = try anchor(of: input)
        let anchor = timing.time(of: start)
        _ = picks(driver, slot: slot, from: start, count: 130)   // 约 2.2 s，跨过 1 s 和 2 s 的 click
        let blocks = ring.recorded
        XCTAssertGreaterThan(blocks.count, 300, "2 s 应写入 ≈ 400 块（每块 256 帧）：\(blocks.count)")
        // 1. 首块 host time = 锚点（第 0 帧显示的拍点），块与块连续（每块 256 帧、host time 步进 256/48000 s）
        XCTAssertEqual(blocks.first?.hostTime, anchor, "第一块的 host time 应是播放起点拍点")
        var expectedFrames: UInt64 = 0
        for (i, b) in blocks.enumerated() {
            XCTAssertEqual(b.frameCount, 256)
            let expected = anchor + HostDuration(nanoseconds: Int64(expectedFrames) * 1_000_000_000 / 48_000)
            XCTAssertEqual(Int64(b.hostTime.ticks) - Int64(expected.ticks), 0, accuracy: 2, "第 \(i) 块 host time 不连续")
            expectedFrames += UInt64(b.frameCount)
        }
        // 2. 每块在它的样本"发生之后"才写（像真设备）：写入时刻的顺序无法从记录里读，但 host time 必须单调
        for i in 1..<blocks.count { XCTAssertGreaterThan(blocks[i].hostTime, blocks[i - 1].hostTime) }
        // 3. click（满幅 +1.0）在整秒：第 k 个 click 的样本序号 = 48000 k（pattern.mov 的 click 在每整秒 ± 1 ms）
        let samples = blocks.flatMap(\.channel0)
        func peakIndex(around center: Int) -> Int? {
            let lo = max(0, center - 4800), hi = min(samples.count, center + 4800)
            guard lo < hi else { return nil }
            var best = lo, bestV: Float = -1
            for i in lo..<hi where samples[i] > bestV { bestV = samples[i]; best = i }
            return bestV > 0.9 ? best : nil
        }
        for k in 1...2 {
            let idx = peakIndex(around: 48_000 * k)
            XCTAssertNotNil(idx, "第 \(k) 秒附近没有 click")
            if let idx { XCTAssertEqual(abs(idx - 48_000 * k), 0, accuracy: 48, "click 偏离整秒 \(idx - 48_000 * k) 样本") }
        }
        let c = input.counters
        XCTAssertEqual(c.audioFramesRejected, 0)
    }

    // MARK: 带 alpha 的素材输出预乘 BGRA（ProRes 4444 / HEVC alpha）

    func testFile_alphaSources_outputPremultipliedBGRA() throws {
        for codec in [AVVideoCodecType.proRes4444, .hevcWithAlpha] {
            let url = RepoPaths.output.appendingPathComponent("alpha-\(codec.rawValue).mov")
            try AlphaMovieWriter.write(to: url, codec: codec, width: 320, height: 240, frames: 30)
            let timing = makeTiming(.hd1080p60)
            let slot = LockFreeFrameSlot(capacity: 3)
            let input = try makeInput(timing: timing, slot: slot, endAction: .loop, path: url.path)
            defer { input.stop() }
            try startAndWaitLive(input)
            XCTAssertTrue(input.hasAlpha, "\(codec.rawValue) 应识别为带 alpha")
            let driver = TickDriver(timing: timing)
            let result = picks(driver, slot: slot, from: try anchor(of: input), count: 6)
            guard let last = result.last, last.hasFrame, last.probe.count == 4 else { return XCTFail("\(codec.rawValue) 没有帧：\(result)") }
            XCTAssertEqual(last.pixelFormat, .bgra, "带 alpha 的素材应输出 BGRA")
            let (b, g, r, a) = (last.probe[0], last.probe[1], last.probe[2], last.probe[3])
            // 素材是 alpha 0.5 的纯红（ProRes 4444 按它的默认口径写直通 255，HEVC alpha 按它的默认口径写预乘 128）。
            // 探针（报告 §5）：AVAssetReader 解成 BGRA 时 RGB 电平会被色彩转换压到 ≈ 0.91×（255 → 233、128 → 115），
            // 所以预乘后的 R 落在 100–140：直通没预乘会是 ≈ 233，预乘两次会是 ≈ 58。
            XCTAssertEqual(a, 128, accuracy: 12, "\(codec.rawValue) alpha")
            XCTAssertGreaterThan(r, 100, "\(codec.rawValue) 预乘后的 R（预乘了两次？）")
            XCTAssertLessThan(r, 140, "\(codec.rawValue) 预乘后的 R（直通 alpha 没有预乘？）")
            XCTAssertLessThan(max(b, g), 24, "\(codec.rawValue) 预乘后 B/G 应接近 0")
        }
    }

    // MARK: 错误：文件不存在 → error(文案)

    func testFile_missingFile_stateIsErrorWithMessage() throws {
        let timing = makeTiming(.hd1080p60)
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = try makeInput(timing: timing, slot: slot, path: "/nonexistent/does-not-exist.mov")
        defer { input.stop() }
        XCTAssertThrowsError(try input.start())
        guard case .error(let message) = input.state else { return XCTFail("应是 error：\(input.state)") }
        XCTAssertTrue(message.contains("does-not-exist.mov"), "文案要带路径：\(message)")
    }
}
