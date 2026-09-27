import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherOutputs
@testable import SwitcherISO

/// InputFrameTee / ISOFrameTap / SharedTickPlanner / DiskEstimate / RecordingFallback 的单元测试。
final class TeeTapPlannerTests: XCTestCase {
    func testTee_pushReachesPrimaryAndEveryBranch_removedBranchStopsReceiving() throws {
        let primary = LockFreeFrameSlot(capacity: 3)
        let tee = InputFrameTee(primary: primary)
        let a = try XCTUnwrap(tee.addBranch())
        let b = try XCTUnwrap(tee.addBranch())
        XCTAssertEqual(tee.branchCount, 2)
        let t = HostTime.now()
        tee.push(makeFrame(input: 1, sequence: 1, pts: t))
        XCTAssertEqual(primary.stats.pushed, 1)
        XCTAssertEqual(a.stats.pushed, 1)
        XCTAssertEqual(b.stats.pushed, 1)
        XCTAssertEqual(tee.latest(atOrBefore: t)?.sequence, 1, "latest 走主槽")
        XCTAssertEqual(a.latest(atOrBefore: t)?.sequence, 1)
        tee.removeBranch(a)
        XCTAssertEqual(tee.branchCount, 1)
        XCTAssertEqual(tee.retiredCount, 1, "摘下的分支先进 retired 表，静默期后释放")
        tee.push(makeFrame(input: 1, sequence: 2, pts: t + HostDuration(milliseconds: 16)))
        XCTAssertEqual(a.stats.pushed, 1, "摘掉之后不再收")
        XCTAssertEqual(b.stats.pushed, 2)
        XCTAssertEqual(primary.stats.pushed, 2)
        // 最多 maxBranches 个
        var extra: [LockFreeFrameSlot] = []
        while let s = tee.addBranch() { extra.append(s) }
        XCTAssertEqual(tee.branchCount, InputFrameTee.maxBranches)
        XCTAssertNil(tee.addBranch())
        tee.reclaimRetired(now: .now(), force: true)
        XCTAssertEqual(tee.retiredCount, 0)
    }

    func testTee_pushIsFast() throws {
        let tee = InputFrameTee(primary: LockFreeFrameSlot(capacity: 3))
        for _ in 0..<4 { _ = tee.addBranch() }
        let buffer = makePixelBuffer()
        var durations: [HostDuration] = []
        for i in 0..<2000 {
            let f = makeFrame(input: 1, sequence: UInt64(i), pts: .now(), buffer: buffer)
            let t0 = HostClock.now()
            tee.push(f)
            durations.append(HostClock.now() - t0)
        }
        let sorted = durations.map(\.milliseconds).sorted()
        let p99 = sorted[Int(Double(sorted.count) * 0.99)]
        print("tee push（主槽 + 4 分支）p99 \(String(format: "%.4f", p99)) ms，最大 \(String(format: "%.4f", sorted.last!)) ms")
        XCTAssertLessThan(p99, 0.1, "push 必须微秒级（输入线程）")
    }

    func testTap_picksLatestAtOrBeforeTickTime_repeatsWhenNoNewerFrame_countsNoFrame() throws {
        let tee = InputFrameTee(primary: LockFreeFrameSlot(capacity: 3))
        let branch = try XCTUnwrap(tee.addBranch())
        let sink = RecordingSink()
        let tap = ISOFrameTap(inputNumber: 3, branch: branch, sink: sink)
        let spec = TickClockSpec(t0: .now(), frameRate: .fps60)
        func pgm(_ tick: Int) -> RenderedFrame {
            let t = spec.time(of: Tick(Int64(tick)))
            return RenderedFrame(tick: Tick(Int64(tick)), tickTime: t, program: makeFrame(input: 0, sequence: UInt64(tick), pts: t), submitTime: t, gpuStart: t, gpuEnd: t)
        }
        // 第 0 拍：分支上还没有帧 → 没输出
        tap.consume(pgm(0))
        XCTAssertEqual(tap.counters.noFrame, 1)
        XCTAssertTrue(sink.frames.isEmpty)
        // 第 1 拍：两帧（序号 1 在拍点前、序号 2 在拍点后）→ 取 1
        tee.push(makeFrame(input: 3, sequence: 1, pts: spec.time(of: Tick(1)) - HostDuration(milliseconds: 4)))
        tee.push(makeFrame(input: 3, sequence: 2, pts: spec.time(of: Tick(1)) + HostDuration(milliseconds: 4)))
        tap.consume(pgm(1))
        // 第 2 拍：没有新帧 → 取 2（pts ≤ 第 2 拍）
        tap.consume(pgm(2))
        // 第 3 拍：还是 2 → 重复
        tap.consume(pgm(3))
        let got = sink.frames
        XCTAssertEqual(got.map(\.sequence), [1, 2, 2])
        XCTAssertEqual(got.map { $0.tick.rawValue }, [1, 2, 3], "换上的是这一拍的 tick")
        XCTAssertEqual(got.map(\.tickTime), [spec.time(of: Tick(1)), spec.time(of: Tick(2)), spec.time(of: Tick(3))], "拍点时刻 = 节目的")
        XCTAssertEqual(got.map(\.inputNumber), [3, 3, 3], "帧仍是该路输入的")
        let c = tap.counters
        XCTAssertEqual(c.forwarded, 3)
        XCTAssertEqual(c.repeated, 1)
        XCTAssertEqual(c.lastSequence, 2)
    }

    func testPlanner_batchSharesOneTick_laterJoinerReusesWhileFuture_thenNewBatch() {
        let spec = TickClockSpec(t0: .now(), frameRate: .fps60)
        var planner = SharedTickPlanner.start
        let now = spec.time(of: Tick(100)) + HostDuration(milliseconds: 3)   // 现在 = 第 100 拍过 3 ms
        // 一批三路，生效拍 100 / 100 / 101 → 101 + 10 + 3 × 2 = 117
        let t1 = planner.plan(batch: [Tick(100), Tick(100), Tick(101)], clock: spec, now: now)
        XCTAssertEqual(t1, Tick(117))
        // 60 ms 后来一路（生效拍 103）：117 ≥ 103.6 + 6 → 沿用 117
        let t2 = planner.plan(appliedTick: Tick(103), clock: spec, now: spec.time(of: Tick(103)) + HostDuration(milliseconds: 10))
        XCTAssertEqual(t2, Tick(117), "上一批的拍还在未来 ≥ 6 拍就沿用")
        // 再晚（现在 = 112）：117 < 112 + 6 → 另起一批 = max(112 + 2, 112 + 10) = 122
        let t3 = planner.plan(appliedTick: Tick(112), clock: spec, now: spec.time(of: Tick(112)))
        XCTAssertEqual(t3, Tick(122))
        // 没记到生效拍：现在之后第 2 拍（另一批）
        var p2 = SharedTickPlanner.start
        XCTAssertEqual(p2.plan(appliedTick: nil, clock: spec, now: spec.time(of: Tick(50))), Tick(52))
        // 主线程来晚了（生效拍 40，现在 60）：不能早于现在 + 2
        var p3 = SharedTickPlanner.start
        XCTAssertEqual(p3.plan(appliedTick: Tick(40), clock: spec, now: spec.time(of: Tick(60))), Tick(62))
        // 边界：lead 10、不加每路、沿用只要 ≥ 现在 + 1
        var s = SharedTickPlanner.stop
        XCTAssertEqual(s.plan(batch: [Tick(200), Tick(201)], clock: spec, now: spec.time(of: Tick(201))), Tick(211))
        XCTAssertEqual(s.plan(appliedTick: Tick(209), clock: spec, now: spec.time(of: Tick(209)) + HostDuration(milliseconds: 5)), Tick(211))
        XCTAssertEqual(s.plan(appliedTick: Tick(211), clock: spec, now: spec.time(of: Tick(211))), Tick(221))
        s.reset()
        XCTAssertNil(s.pending)
    }

    /// W3-C3 交付 3：DiskEstimate 只出数——每秒写多少字节、还能录多少秒（没有码率 = +inf）；"约 1 小时 23 分"之类的文案归组装方
    /// （App 的 ISORoutes.remainingText 按同样的分档查表），包里的 `describe(seconds:)` 删了。
    func testS7_diskEstimateReturnsNumbersOnly() {
        // 视频码率 + 音频码率（bit/s）→ 字节 / 秒
        let h264 = DiskEstimate.bytesPerSecond(video: VideoEncodeSettings(bitrateBps: 8_000_000), audio: AudioEncodeSettings(bitrateBps: 160_000))
        XCTAssertEqual(h264, 1_020_000, accuracy: 0.5)
        XCTAssertEqual(DiskEstimate.bytesPerSecond(video: VideoEncodeSettings(codec: .hevc, bitrateBps: 20_000_000), audio: nil), 2_500_000, accuracy: 0.5, "只有视频")
        XCTAssertEqual(DiskEstimate.bytesPerSecond(video: nil, audio: AudioEncodeSettings(bitrateBps: 192_000)), 24_000, accuracy: 0.5, "只有 AAC")
        XCTAssertEqual(DiskEstimate.bytesPerSecond(video: nil, audio: nil), 0)
        // PCM 按 48 kHz × 声道 × 24 bit（Recorder 写 LPCM 用 24 bit），与码率设置无关
        XCTAssertEqual(DiskEstimate.bytesPerSecond(video: nil, audio: AudioEncodeSettings(codec: .pcm, bitrateBps: 0)), 48_000 * 2 * 3, accuracy: 0.5)
        XCTAssertEqual(DiskEstimate.bytesPerSecond(video: nil, audio: AudioEncodeSettings(codec: .pcm, bitrateBps: 999), audioChannels: 8), 48_000 * 8 * 3, accuracy: 0.5)
        // 秒 = (剩余 − 保留) / 每秒字节
        XCTAssertEqual(DiskEstimate.remainingSeconds(freeBytes: 1_020_000 * 100 + 1000, reserveBytes: 1000, bytesPerSecond: h264), 100, accuracy: 0.01)
        XCTAssertEqual(DiskEstimate.remainingSeconds(freeBytes: 10, reserveBytes: 100, bytesPerSecond: h264), 0, "保留比剩余多：0 秒，不是负数")
        XCTAssertEqual(DiskEstimate.remainingSeconds(freeBytes: 100, reserveBytes: 100, bytesPerSecond: h264), 0)
        XCTAssertEqual(DiskEstimate.remainingSeconds(freeBytes: 10, reserveBytes: 0, bytesPerSecond: 0), .infinity, "没有码率 = 不受磁盘限制（+inf；文案归 App）")
        // 大盘：8 TB 按 1.02 MB/s 约 90.8 天，双精度算得准（App 按分钟 / 小时分档）
        XCTAssertEqual(DiskEstimate.remainingSeconds(freeBytes: 8_000_000_000_000, reserveBytes: 0, bytesPerSecond: h264), 8_000_000_000_000 / 1_020_000, accuracy: 1e-3)
        // PGM + 4 路 ISO 的码率相加（App 的 OutputRuntime.estimate 就是这么加的）
        let routes = (0..<5).map { _ in DiskEstimate.bytesPerSecond(video: VideoEncodeSettings(bitrateBps: 6_000_000), audio: AudioEncodeSettings()) }
        XCTAssertEqual(routes.reduce(0, +), 5 * (6_000_000 + 160_000) / 8, accuracy: 0.5)
    }

    /// 切备用目录的路径；失败归因（W3-C3：只看文案里与语言无关的错误码 + 剩余空间，不再认中文字样——
    /// 那是 W1-E 录制器给人看的文案、系统描述也随语言变；录制器自己按下限停的按它的读数归，见 RecorderDiskTests）。
    func testS7_fallbackURL_and_classifyByErrorCodeAndFreeSpace() throws {
        let dir = TestPaths.file("fallback-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = URL(fileURLWithPath: "/Volumes/Tiny/show-2026-09-19-10-00-00.mov")
        let u1 = RecordingFallback.url(for: original, directory: dir.path)
        XCTAssertEqual(u1.lastPathComponent, "show-2026-09-19-10-00-00.mov")
        XCTAssertEqual(u1.deletingLastPathComponent().path, dir.path)
        FileManager.default.createFile(atPath: u1.path, contents: Data())
        XCTAssertEqual(RecordingFallback.url(for: original, directory: dir.path).lastPathComponent, "show-2026-09-19-10-00-00-2.mov", "同名已存在就加序号")

        // 磁盘错误码（S7 实测：写满时 AVAssetWriter 报 -11807，下面挂着 ENOSPC）：空间还多也归磁盘
        XCTAssertEqual(DiskGuard.classify(message: "视频写入失败：Error Domain=AVFoundationErrorDomain Code=-11807 \"Operation Stopped\"", freeBytes: 10_000_000_000), .disk, "AVError.diskFull")
        XCTAssertEqual(DiskGuard.classify(message: "Error Domain=NSPOSIXErrorDomain Code=28 \"No space left on device\"", freeBytes: 10_000_000_000), .disk, "ENOSPC")
        XCTAssertEqual(DiskGuard.classify(message: "Error Domain=NSCocoaErrorDomain Code=640", freeBytes: 10_000_000_000), .disk, "NSFileWriteOutOfSpaceError")
        XCTAssertEqual(DiskGuard.classify(message: "The disk is full; not enough space", freeBytes: 10_000_000_000), .disk)
        XCTAssertEqual(DiskGuard.classify(message: "视频写入失败：Error Domain=AVFoundationErrorDomain Code=-11800", freeBytes: 1_000_000), .disk, "剩余不足 64 MB 的写失败归磁盘")
        XCTAssertEqual(DiskGuard.classify(message: "编码器启动失败：sessionCreateFailed(-12903)", freeBytes: 10_000_000_000), .other)
        // 空间充足、没有磁盘错误码的写失败：other（W3-C3 之前"写入失败"四个字就算磁盘；拔盘这种写不下去的情况剩余空间量出来是 0，仍归磁盘）
        XCTAssertEqual(DiskGuard.classify(message: "视频写入失败：Error Domain=AVFoundationErrorDomain Code=-11800 \"这项操作无法完成\"", freeBytes: 10_000_000_000), .other)
        XCTAssertEqual(DiskGuard.freeBytes(for: URL(fileURLWithPath: "/Volumes/switcher-no-such-volume-\(UUID().uuidString)/x.mov")), 0, "卷不在（拔了）：剩余 0")
    }
}
