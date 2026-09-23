import CSwitcherNDI
import Foundation
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherInputsHarness
@testable import SwitcherNDI

/// NDI 回环（prompt 测试段）：本机发送端 → 本机 NDIInput。帧号连续；L1 ≤ 3 帧 + 抖动缓冲；关掉发送端 → noSignal 在 3 个帧间隔内；
/// 重开自动恢复；tally 回传；BGRA（alpha）路径；音频进环。没有 SDK：BLOCKED-SDK。
/// 发送端是测试自己用 CSwitcherNDI 建的（依赖方向不许 import SwitcherNDISend）；W2-D 真发送端 → 本输入的回环见
/// `testNDI_loopback_externalSource_manual`（设 SWITCHER_NDI_LOOP_SOURCE 指到它）。
final class NDILoopbackTests: XCTestCase {
    private static let nameCounter = Atomic<Int>(0)
    /// 两条计时断言的调度余量（用户 2026-09-23 批；reports/issues/W2A2-w3-inputs2-ndi-audio-interval-flaky-under-load.md）：阈值本来贴着理论值
    /// （音频块最大间隔 = 一块 + 抖动 24.667 ms；停送后 noSignal = 3 个帧间隔 + 一次 capture 超时 71.667 ms），整包 swift test 里并发的实时 / 高优先级线程多，
    /// NDI 收发线程或看门狗被调度晚 0.25–0.7 ms 就过线，单跑稳过。这 2 ms 只盖调度抖动，不改被测行为的口径。
    private static let schedulingMarginMs = 2.0
    private func uniqueName(_ base: String) -> String {
        let n = Self.nameCounter.add(1, ordering: .relaxed).newValue
        return "\(base) \(ProcessInfo.processInfo.processIdentifier)-\(n)"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard SwitcherNDIInfo.isSDKAvailable else {
            throw XCTSkip("BLOCKED-SDK：没有 NDI SDK（/Library/NDI SDK for Apple 或 NDI_SDK_DIR）")
        }
    }

    /// 起一路 NDIInput 收某个源；等到 live 或超时。
    private func makeInput(source: String, format: ProgramFormat, timing: ProgramTiming, slot: any FrameSlot, ring: (any AudioRing)? = nil,
                           options: NDIInput.Options = NDIInput.Options()) throws -> NDIInput {
        let config = InputConfig(number: 1, name: "NDI 回环", source: .ndi(sourceName: source))
        let input = try NDIInput(config: config, timing: timing, videoSlot: slot, audioRing: ring, options: options)
        try input.start()
        return input
    }

    // MARK: 发现

    func testNDI_discovery_findsLocalSender() throws {
        let sender = try TestNDISender(name: uniqueName("Switcher loop discover"))
        defer { sender.destroy() }
        let finder = try NDIFinder(showLocalSources: true)
        var found = false
        let deadline = HostClock.now() + HostDuration(seconds: 8)
        while HostClock.now() < deadline, !found {
            _ = finder.waitForChange(timeoutMs: 500)
            found = finder.source(named: sender.sourceName) != nil
        }
        XCTAssertTrue(found, "8 s 内应发现本机源 \(sender.sourceName)；当前：\(finder.currentSources)")
        let src = finder.source(named: sender.sourceName)
        print("发现：\(src.map { "\($0.name) @ \($0.url ?? "-")" } ?? "nil")；NDI 版本 \(SwitcherNDIInfo.sdkVersion)")
    }

    // MARK: 帧号连续 + 格式 + 时间戳（契约入口，不起引擎）

    func testNDI_loopback_uyvy_framesContinuous_formatAndTimestamps() throws {
        let format = ProgramFormat.hd1080p60
        let timing = ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: 300))
        let sender = try TestNDISender(name: uniqueName("Switcher loop uyvy"))
        defer { sender.destroy() }
        let slot = RecordingSlot(inner: LockFreeFrameSlot(capacity: 3))
        let input = try makeInput(source: sender.sourceName, format: format, timing: timing, slot: slot)
        defer { input.stop() }
        let first = timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: 200))
        sender.start(width: 1920, height: 1080, clock: timing.clock, frameRate: format.frameRate, format: .uyvy, inputID: 3, firstTick: first, audio: false)
        XCTAssertTrue(waitUntil(timeoutMs: 10_000) { input.state == .live }, "10 s 内应 live：\(input.lastError ?? "-")")
        // 收 4 s
        Thread.sleep(forTimeInterval: 4)
        sender.stopSending()
        Thread.sleep(forTimeInterval: 0.2)
        let frames = slot.pushedFrames
        let c = input.ndiCounters
        print("UYVY 回环：推 \(frames.count) 帧，格式 \(c.lastFormat)，抖动均值 \(String(format: "%.2f", c.jitterMeanMs)) ms / 最大 \(String(format: "%.2f", c.jitterMaxMs)) ms，"
              + "d = ingress − pts 均值 \(String(format: "%.2f", c.arrivalMinusPtsMeanMs)) / 最大 \(String(format: "%.2f", c.arrivalMinusPtsMaxMs)) / 最小 \(String(format: "%.2f", c.arrivalMinusPtsMinMs)) ms，"
              + "SDK 丢 \(c.sdkVideoDropped)，发送晚点 \(sender.lateTicks.load(ordering: .relaxed))")
        XCTAssertGreaterThan(frames.count, 180, "4 s 应收到 ≥ 180 帧（60 fps）")
        XCTAssertTrue(frames.allSatisfy { $0.pixelFormat == .uyvy && $0.width == 1920 && $0.height == 1080 }, "全部 UYVY 1080p")
        XCTAssertTrue(c.lastFormat.hasPrefix("1920x1080 UYVY 60/1"), c.lastFormat)
        // 帧号：每帧都解得出、严格 +1 连续（回环本机丢帧应为 0；允许起流头几帧的 SDK 丢帧，所以只看稳态：去掉前 10 帧）
        let steady = Array(frames.dropFirst(10))
        let numbers = steady.compactMap(\.frameNumber)
        XCTAssertEqual(numbers.count, steady.count, "每帧都能解出帧号（SpeedHQ 压缩后块均值仍清楚）")
        // 缺号（丢帧）不许有；同一帧号连续出现两次（发送端 / SDK 重复送）记下来看
        let missing = zip(numbers, numbers.dropFirst()).filter { $1 > $0 + 1 }
        let duplicates = zip(numbers, numbers.dropFirst()).filter { $1 == $0 }
        let odd = zip(numbers, numbers.dropFirst()).filter { $1 < $0 }
        if !missing.isEmpty || !duplicates.isEmpty || !odd.isEmpty {
            // 邻域诊断：帧号、序号、pts 差、ingress 差
            for (i, f) in steady.enumerated() {
                guard i > 0, let n = f.frameNumber, let m = steady[i - 1].frameNumber, n != m + 1 else { continue }
                let lo = max(0, i - 3), hi = min(steady.count - 1, i + 3)
                for j in lo...hi {
                    let g = steady[j]
                    let dPts = j > 0 ? (g.pts - steady[j - 1].pts).milliseconds : 0
                    let dIn = j > 0 ? (g.ingress - steady[j - 1].ingress).milliseconds : 0
                    print(String(format: "  [%d] 帧号 %@ 序号 %llu Δpts %.2f ms Δingress %.2f ms d %.2f ms", j, g.frameNumber.map(String.init) ?? "nil", g.sequence, dPts, dIn, (g.ingress - g.pts).milliseconds))
                }
            }
        }
        XCTAssertEqual(missing.count, 0, "帧号不许缺：\(missing.prefix(5))")
        XCTAssertEqual(odd.count, 0, "帧号不许倒退：\(odd.prefix(5))")
        XCTAssertLessThanOrEqual(duplicates.count, 2, "连续重复的帧号：\(duplicates.prefix(5))")
        print("帧号：\(numbers.first ?? 0)…\(numbers.last ?? 0)，缺号 \(missing.count)，重复 \(duplicates.count)")
        // 时间戳：pts 单调、间隔 ≈ 16.67 ms（抖动缓冲 J = 1 → pts ≈ 到达 + 16.67 ms，d ≈ −16.67 + 抖动）
        let pts = frames.map(\.pts)
        XCTAssertTrue(zip(pts, pts.dropFirst()).allSatisfy { $1 > $0 }, "pts 单调递增")
        let intervals = zip(pts, pts.dropFirst()).map { ($1 - $0).milliseconds }
        let meanInterval = intervals.reduce(0, +) / Double(intervals.count)
        XCTAssertEqual(meanInterval, 16.667, accuracy: 0.5, "平均 pts 间隔 = 帧间隔")
        XCTAssertEqual(c.arrivalMinusPtsMeanMs, -16.667 + c.jitterMeanMs, accuracy: 1.5, "d = jitter − J×T（J = 1）")
        XCTAssertEqual(c.framesPushed, c.framesReceived - c.framesUnsupported - c.framesPoolExhausted)
        XCTAssertEqual(c.framesUnsupported, 0)
        XCTAssertLessThanOrEqual(c.framesPoolExhausted, 0)
    }

    // MARK: L1（真引擎 + 真渲染器 + 真帧槽），三种抖动缓冲深度

    private func measureL1(jitterFrames: Int, seconds: Double) async throws -> (LatencyStats, Stats, NDIInputCounters, RecordingSlot, Int) {
        let format = ProgramFormat.hd1080p60
        let sender = try TestNDISender(name: uniqueName("Switcher loop L1 J\(jitterFrames)"))
        defer { sender.destroy() }
        let config = InputConfig(number: 1, name: "NDI", source: .ndi(sourceName: sender.sourceName))
        // 发送端先跑起来（发现 + 连接要 1–3 s），引擎的 t0 再定
        let harness = try InputEngineHarness(format: format, configs: [config], leadMs: 4000)
        let latencySlot = harness.makeSlot(forInput: 1)
        let recording = RecordingSlot(inner: latencySlot)
        var options = NDIInput.Options()
        options.jitterBufferFrames = jitterFrames
        let input = try NDIInput(config: config, timing: harness.timing, videoSlot: recording, options: options)
        harness.add(input)
        let clock = harness.timing.clock
        // 发送端从第 0 拍（引擎 t0）起发：之前不推帧，帧槽的 drop 才是真丢帧（引擎起来前进槽的帧被挤掉是设计内的，W2-A 报告 §5 第 9 条）；
        // 发现 + 连接在 4 s 的 lead 里完成
        sender.start(width: 1920, height: 1080, clock: clock, frameRate: format.frameRate, format: .uyvy, inputID: 1,
                     firstTick: .zero, audio: false)
        let ticks = Int64(seconds * 60)
        try await harness.start(lastTick: Tick(ticks - 1))
        let deadline = HostClock.now() + HostDuration(seconds: seconds + 6)
        while HostClock.now() < deadline, let c = harness.engine.clock, c.ticksDispatched + c.ticksSkipped < UInt64(ticks) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stats = harness.engine.makeStats()
        let counters = input.ndiCounters
        await harness.stop()
        let l1 = try XCTUnwrap(harness.latency(ofInput: 1))
        // 引擎挑到的帧号连续性：LatencyFrameSlot 记的每拍 ingress → 推送记录里的帧号
        let byIngress = Dictionary(recording.pushedFrames.map { ($0.ingress.ticks, $0.frameNumber) }, uniquingKeysWith: { a, _ in a })
        var picked: [UInt32] = []
        for t in 0..<ticks {
            if let e = latencySlot.entry(forTick: Tick(t)), e.isNew, let n = byIngress[e.ingressTime.ticks] ?? nil { picked.append(n) }
        }
        let gaps = zip(picked, picked.dropFirst()).filter { $1 != $0 + 1 }.count
        return (l1, stats, counters, recording, gaps)
    }

    private func report(_ label: String, _ s: LatencyStats, _ c: NDIInputCounters) -> String {
        let f = s.frames(at: .fps60)
        return String(format: "%@ L1：%d 样本，平均 %.2f ms（%.2f 帧），p50 %.2f，p99 %.2f ms（%.2f 帧），max %.2f ms（%.2f 帧），min %.2f；没帧 %d 拍，重复 %d 拍；抖动均值 %.2f / 最大 %.2f ms；d 均值 %.2f ms",
                      label, s.samples, s.meanMs, f.mean, s.p50Ms, s.p99Ms, f.p99, s.maxMs, f.max, s.minMs, s.ticksWithoutFrame, s.ticksReused,
                      c.jitterMeanMs, c.jitterMaxMs, c.arrivalMinusPtsMeanMs)
    }

    /// prompt：L1 ≤ 3 帧 + 抖动缓冲（默认 J = 1）；帧号连续。
    func testNDI_loopback_L1_within3FramesPlusJitterBuffer_framesContinuous() async throws {
        let (l1, stats, c, _, gaps) = try await measureL1(jitterFrames: 1, seconds: 8)
        let line = report("NDI 1080p60 回环（J = 1）", l1, c)
        print(line)
        print("  per_input: \(stats.perInput[1].map { "fps \($0.fps) dup \($0.dup) drop \($0.drop) latency \($0.latencyMs) / \($0.latencyMaxMs)" } ?? "-")，missed_render \(stats.missedRender)，挑到的帧号跳号 \(gaps)")
        let frames = l1.frames(at: .fps60)
        XCTAssertGreaterThan(l1.samples, 300, line)
        XCTAssertLessThanOrEqual(frames.mean, 3 + 1, "L1 平均 ≤ 3 帧 + 抖动缓冲 1 帧：\(line)")
        XCTAssertLessThanOrEqual(frames.p99, 3 + 1, "L1 p99 ≤ 3 帧 + 抖动缓冲 1 帧：\(line)")
        XCTAssertEqual(gaps, 0, "引擎每拍挑到的新帧帧号应连续")
        XCTAssertEqual(stats.missedRender, 0)
        XCTAssertEqual(c.framesUnsupported, 0)
        XCTAssertLessThanOrEqual(stats.perInput[1]?.drop ?? 0, 3, "60 fps NDI 进 60 fps 节目不该丢帧（起流头几帧除外）：\(stats.perInput[1].map { "\($0)" } ?? "-")")
        XCTAssertLessThanOrEqual(l1.ticksWithoutFrame, 60, "起流后 1 s 内该有帧")
    }

    /// 报告项：抖动缓冲深度与延迟的实测关系（J = 0 / 1 / 2 各跑 5 s，打印）。
    func testNDI_loopback_L1_vsJitterBufferDepth_report() async throws {
        for j in 0...2 {
            let (l1, stats, c, _, gaps) = try await measureL1(jitterFrames: j, seconds: 5)
            print(report("NDI 1080p60 回环 J = \(j)", l1, c) + "；dup \(stats.perInput[1]?.dup ?? 0) drop \(stats.perInput[1]?.drop ?? 0) 跳号 \(gaps)")
            XCTAssertGreaterThan(l1.samples, 150)
            XCTAssertLessThanOrEqual(l1.frames(at: .fps60).p99, Double(3 + j), "J = \(j)：p99 ≤ 3 + J 帧")
        }
    }

    // MARK: 无信号与恢复

    func testNDI_loopback_senderStops_noSignalWithin3Intervals_restartsRecover() throws {
        let format = ProgramFormat.hd720p60
        let timing = ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: 300))
        let name = uniqueName("Switcher loop nosignal")
        var sender: TestNDISender? = try TestNDISender(name: name)
        let sourceName = sender!.sourceName
        let slot = RecordingSlot(inner: LockFreeFrameSlot(capacity: 3))
        let input = try makeInput(source: sourceName, format: format, timing: timing, slot: slot)
        defer { input.stop() }
        sender!.start(width: 1280, height: 720, clock: timing.clock, frameRate: format.frameRate, firstTick: timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: 100)))
        XCTAssertTrue(waitUntil(timeoutMs: 10_000) { input.state == .live }, "应 live：\(input.lastError ?? "-")")
        Thread.sleep(forTimeInterval: 1.0)
        // 1. 发送端停止送帧（源还在）：3 个帧间隔（50 ms）内 noSignal。用最后一帧 ingress 到状态变化的时间量
        sender!.stopSending()
        let stopAt = HostClock.now()
        XCTAssertTrue(waitUntil(timeoutMs: 2000, pollMs: 1) { input.state == .noSignal }, "停止送帧后应 noSignal")
        let noSignalAt = HostClock.now()
        let lastIngress = slot.pushedFrames.last?.ingress ?? stopAt
        let sinceLastFrame = (noSignalAt - lastIngress).milliseconds
        let interval = timing.frameDuration.milliseconds
        print("停止送帧：最后一帧 → noSignal \(String(format: "%.1f", sinceLastFrame)) ms（3 个帧间隔 = \(String(format: "%.1f", 3 * interval)) ms，加轮询粒度 ≤ 1 帧）；文案：\(input.lastError ?? "-")")
        XCTAssertLessThanOrEqual(sinceLastFrame, 3 * interval + interval + 5 + Self.schedulingMarginMs, "noSignal 应在 3 个帧间隔内（+ 一次 capture 超时的粒度 + 调度余量）")
        XCTAssertNotNil(input.lastError)
        // 2. 恢复送帧：自动回 live
        sender!.start(width: 1280, height: 720, clock: timing.clock, frameRate: format.frameRate, firstTick: timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: 50)))
        XCTAssertTrue(waitUntil(timeoutMs: 5000) { input.state == .live }, "恢复送帧后应回 live")
        Thread.sleep(forTimeInterval: 0.5)
        // 3. 销毁发送端（源消失）→ noSignal；重新创建同名发送端（新端口）→ 自动重连回 live
        let framesBefore = slot.pushedFrames.count
        sender!.destroy()
        sender = nil
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { input.state == .noSignal }, "源消失后应 noSignal")
        let goneAt = HostClock.now()
        Thread.sleep(forTimeInterval: 1.0)
        let sender2 = try TestNDISender(name: name)
        defer { sender2.destroy() }
        XCTAssertEqual(sender2.sourceName, sourceName, "同名源")
        sender2.start(width: 1280, height: 720, clock: timing.clock, frameRate: format.frameRate, firstTick: timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: 100)))
        let recovered = waitUntil(timeoutMs: 20_000) { input.state == .live }
        let recoverMs = (HostClock.now() - goneAt).milliseconds - 1000
        let c = input.ndiCounters
        print("源消失 → 重开：恢复用时 \(String(format: "%.0f", recoverMs)) ms（不含等待的 1 s），重连 \(c.reconnects) 次，连接数 \(c.connections)，源变化事件 \(c.sourceChanges)，文案：\(input.lastError ?? "-")")
        XCTAssertTrue(recovered, "重开发送端后应自动恢复：\(input.lastError ?? "-")")
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { slot.pushedFrames.count > framesBefore + 30 }, "恢复后继续收帧")
    }

    // MARK: tally 回传

    func testNDI_loopback_tallyReachesSender() throws {
        let format = ProgramFormat.hd720p60
        let timing = ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: 300))
        let sender = try TestNDISender(name: uniqueName("Switcher loop tally"))
        defer { sender.destroy() }
        let slot = RecordingSlot(inner: LockFreeFrameSlot(capacity: 3))
        let input = try makeInput(source: sender.sourceName, format: format, timing: timing, slot: slot)
        defer { input.stop() }
        sender.start(width: 1280, height: 720, clock: timing.clock, frameRate: format.frameRate, firstTick: timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: 100)))
        XCTAssertTrue(waitUntil(timeoutMs: 10_000) { input.state == .live }, input.lastError ?? "-")
        XCTAssertEqual(sender.tally(), Tally(program: false, preview: false), "起始 tally 全灭")
        input.setTally(Tally(program: true, preview: false))
        let t0 = HostClock.now()
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { sender.tally(timeoutMs: 50).program }, "PGM tally 应到发送端")
        print("tally PGM 到达发送端用时 \(String(format: "%.0f", (HostClock.now() - t0).milliseconds)) ms")
        input.setTally(Tally(program: false, preview: true))
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { let t = sender.tally(timeoutMs: 50); return t.preview && !t.program }, "PVW tally")
        input.setTally(.off)
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { sender.tally(timeoutMs: 50) == .off }, "tally 灭")
    }

    // MARK: BGRA（带 alpha）路径

    func testNDI_loopback_bgraWithAlpha_receivesBGRA_alphaPreserved() throws {
        let format = ProgramFormat.hd720p60
        let timing = ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: 300))
        let sender = try TestNDISender(name: uniqueName("Switcher loop bgra"))
        defer { sender.destroy() }
        let slot = RecordingSlot(inner: LockFreeFrameSlot(capacity: 3))
        let input = try makeInput(source: sender.sourceName, format: format, timing: timing, slot: slot)
        defer { input.stop() }
        sender.start(width: 1280, height: 720, clock: timing.clock, frameRate: format.frameRate, format: .bgra(alpha: 128), inputID: 5,
                     firstTick: timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: 100)))
        XCTAssertTrue(waitUntil(timeoutMs: 10_000) { input.state == .live }, input.lastError ?? "-")
        Thread.sleep(forTimeInterval: 1.5)
        // 抓一帧看像素：下半 alpha 128、上半 255（帧号块在上半，别盖住）；灰底 128 预乘后下半 ≈ 64
        let frame = try XCTUnwrap(slot.inner.latest(atOrBefore: HostClock.now() + HostDuration(seconds: 1)))
        XCTAssertEqual(frame.pixelFormat, .bgra, "带 alpha 的源应给 BGRA")
        XCTAssertEqual(frame.color, .sRGBFull)
        let pb = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let left = base + 600 * stride + 300 * 4, right = base + 300 * stride + 1000 * 4
        print("BGRA 回环像素：下半 B\(left[0]) G\(left[1]) R\(left[2]) A\(left[3])，上半 B\(right[0]) G\(right[1]) R\(right[2]) A\(right[3])")
        XCTAssertEqual(Int(left[3]), 128, accuracy: 3, "alpha 保留")
        XCTAssertEqual(Int(right[3]), 255)
        XCTAssertEqual(Int(left[2]), 64, accuracy: 6, "预乘后的 RGB 原样过来（SDK 不动 RGB）")
        XCTAssertEqual(Int(right[2]), 128, accuracy: 6)
        let decoded = TestPattern.decode(pixelBuffer: pb)
        XCTAssertNotNil(decoded?.frameNumber, "BGRA 帧的帧号解得出")
        XCTAssertTrue(input.ndiCounters.lastFormat.contains("BGRA"), input.ndiCounters.lastFormat)
    }

    // MARK: 音频

    func testNDI_loopback_audioBlocksIntoRing_timestampsMonotonicAndAligned() throws {
        let format = ProgramFormat.hd720p60
        let timing = ProgramTiming(format: format, t0: HostClock.now() + HostDuration(milliseconds: 300))
        let sender = try TestNDISender(name: uniqueName("Switcher loop audio"))
        defer { sender.destroy() }
        let slot = RecordingSlot(inner: LockFreeFrameSlot(capacity: 3))
        let ring = RecordingAudioRing(channelCount: 2)
        let input = try makeInput(source: sender.sourceName, format: format, timing: timing, slot: slot, ring: ring)
        defer { input.stop() }
        let first = timing.nextTick(atOrAfter: HostClock.now() + HostDuration(milliseconds: 100))
        sender.start(width: 1280, height: 720, clock: timing.clock, frameRate: format.frameRate, firstTick: first, audio: true)
        XCTAssertTrue(waitUntil(timeoutMs: 10_000) { input.state == .live }, input.lastError ?? "-")
        Thread.sleep(forTimeInterval: 3)
        sender.stopSending()
        Thread.sleep(forTimeInterval: 0.2)
        let blocks = ring.recorded
        let c = input.ndiCounters
        print("音频：\(blocks.count) 块，\(c.audioFramesWritten) 帧，重采样块 \(c.audioBlocksResampled)，拒 \(c.audioFramesRejected)")
        XCTAssertGreaterThan(blocks.count, 100, "3 s 60 fps 每拍一块 → ≥ 100 块")
        XCTAssertEqual(c.audioBlocksResampled, 0, "48 kHz 源不重采样")
        XCTAssertTrue(blocks.allSatisfy { (799...801).contains($0.frameCount) }, "每块 800 ± 1 帧（48000 / 60，发送端按拍点取整）：\(Set(blocks.map(\.frameCount)))")
        XCTAssertEqual(Double(blocks.map(\.frameCount).reduce(0, +)) / Double(blocks.count), 800, accuracy: 0.5)
        // 首样本 host time 单调，相邻块间隔 ≈ 块时长（16.67 ms；抖动缓冲映射把网络抖动压掉了，允许 ±5 ms）
        let times = blocks.map(\.hostTime)
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $1 > $0 }, "块 host time 单调")
        let gaps = zip(times, times.dropFirst()).map { ($1 - $0).milliseconds }
        let meanGap = gaps.reduce(0, +) / Double(gaps.count)
        XCTAssertEqual(meanGap, 16.667, accuracy: 0.3)
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, 16.667 + 8 + Self.schedulingMarginMs, "最大间隔不超过一块 + 抖动（+ 调度余量）")
        // 内容：1 kHz 正弦 −20 dBFS，两声道相同；click（+1.0）每秒一个
        let all = blocks.flatMap(\.channel0)
        let peak = all.map(abs).max() ?? 0
        XCTAssertEqual(peak, 1.0, accuracy: 0.02, "click 满幅到达")
        let nonClick = all.filter { abs($0) < 0.5 }
        let rms = (nonClick.reduce(0) { $0 + Double($1 * $1) } / Double(max(nonClick.count, 1))).squareRoot()
        XCTAssertEqual(rms, 0.1 / 2.0.squareRoot(), accuracy: 0.01, "正弦 RMS = 0.1 / √2")
        XCTAssertEqual(blocks[10].channel0, blocks[10].channel1, "两声道同内容")
        // A/V：视频 pts 与音频 hostTime 同一映射，都带 J×T；比较"闪光帧的 pts"与"click 所在块的时间"
        let clicks: [HostTime] = blocks.compactMap { b in
            guard let i = b.channel0.firstIndex(where: { $0 > 0.9 }) else { return nil }
            return b.hostTime + HostDuration(nanoseconds: Int64(i) * 1_000_000_000 / 48_000)
        }
        print("click 时刻：\(clicks.count) 个")
        XCTAssertGreaterThanOrEqual(clicks.count, 2)
    }

    // MARK: 外部（W2-D 真发送端）回环，手动

    /// `SWITCHER_NDI_LOOP_SOURCE="<机器名> (Switcher PGM test)" swift test --filter testNDI_loopback_externalSource_manual`，
    /// 另一个终端跑 W2-D 的 `SWITCHER_NDI_LIVE_SECONDS=60 swift test --package-path Packages/SwitcherOutputs --filter NDISendTests/testLiveSend`。
    /// 验证 W2-D 发送端 → 本输入：帧号连续、L1。
    func testNDI_loopback_externalSource_manual() async throws {
        guard let source = ProcessInfo.processInfo.environment["SWITCHER_NDI_LOOP_SOURCE"], !source.isEmpty else {
            throw XCTSkip("设 SWITCHER_NDI_LOOP_SOURCE 指到 W2-D 发送端的源名才跑（真 NDISend → NDIInput 回环）")
        }
        let format = ProgramFormat.hd1080p60
        let config = InputConfig(number: 1, name: "NDI 外部", source: .ndi(sourceName: source))
        let harness = try InputEngineHarness(format: format, configs: [config], leadMs: 3000)
        let latencySlot = harness.makeSlot(forInput: 1)
        let recording = RecordingSlot(inner: latencySlot)
        let input = try NDIInput(config: config, timing: harness.timing, videoSlot: recording)
        harness.add(input)
        let ticks: Int64 = 8 * 60
        try await harness.start(lastTick: Tick(ticks - 1))
        let deadline = HostClock.now() + HostDuration(seconds: 8 + 6)
        while HostClock.now() < deadline, let c = harness.engine.clock, c.ticksDispatched + c.ticksSkipped < UInt64(ticks) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stats = harness.engine.makeStats()
        await harness.stop()
        let l1 = try XCTUnwrap(harness.latency(ofInput: 1))
        print(report("外部源 \(source)", l1, input.ndiCounters))
        print("  推 \(recording.pushedFrames.count) 帧，帧号跳号 \(recording.frameNumberGaps)，per_input \(stats.perInput[1].map { "dup \($0.dup) drop \($0.drop)" } ?? "-")，状态 \(input.state)，\(input.lastError ?? "")")
        XCTAssertGreaterThan(l1.samples, 200, "应从外部源收到帧：\(input.lastError ?? "-")")
        XCTAssertEqual(recording.frameNumberGaps, 0)
        XCTAssertLessThanOrEqual(l1.frames(at: .fps60).p99, 4)
    }

    // MARK: 没有 SDK 时的行为（有 SDK 时这条跳过；对称的那条在 NDIUnavailableTests）

    func testNDI_sdkInfo_print() {
        print("NDI SDK：\(SwitcherNDIInfo.sdkVersion)")
        XCTAssertTrue(SwitcherNDIInfo.isSDKAvailable)
    }
}
