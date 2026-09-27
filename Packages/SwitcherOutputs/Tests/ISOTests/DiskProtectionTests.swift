import Darwin
import Foundation
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherISO

/// S7 磁盘满：录到 hdiutil 建的 50 MB 小镜像直到满。两路录到小盘（1 号按监视器的剩余下限被停、2 号真写满失败），
/// 一路录到正常目录、一个只数帧的消费者（推流的替身）同吃同一批 PGM 帧：小盘上的两路停下并归因为磁盘、
/// 正常那路帧数 = 拍数、替身帧数 = 拍数（推流帧数不减）；RecordingDiskMonitor 先报低空间再报下限 / 失败；
/// 备用目录策略：失败事件到了就在下一拍把那一路重起到备用目录，之后的拍都进新文件。渲染（missed_render）在 App 级 S7 测试里看。
/// 录制器自己的 minimumFreeBytes 设 0：它的 freeBytes 在磁盘镜像上是 0（探针 3），下限由监视器管（DiskGuard.freeBytes 用对键）。
final class DiskProtectionTests: XCTestCase {
    func testS7_recordToFull50MBImage_onlyThoseRecordersStop_streamCountUnchanged_fallbackRestarts() throws {
        try Tools.requireFFprobe()
        let image = TestPaths.file("s7-tiny.dmg")
        let mount = TestPaths.file("s7-tiny-volume")
        try? FileManager.default.removeItem(at: image)
        _ = try? runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard (try? runProcess("/usr/bin/hdiutil", ["create", "-size", "50m", "-fs", "HFS+", "-volname", "W3CTiny", "-quiet", image.path]))?.code == 0 else {
            throw XCTSkip("hdiutil create 失败，跳过 S7")
        }
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard (try? runProcess("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-quiet", "-mountpoint", mount.path]))?.code == 0 else {
            throw XCTSkip("hdiutil attach 失败，跳过 S7")
        }
        defer { _ = try? runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"]); try? FileManager.default.removeItem(at: image) }
        let fallbackDir = TestPaths.file("s7-fallback")
        try? FileManager.default.removeItem(at: fallbackDir)
        try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)

        let format = ProgramFormat.hd1080p60
        let fps = 60
        let seconds = 16
        let ticks = seconds * fps
        let feeder = try PatternFeeder(configuration: .init(format: format, inputID: 0, texture: .noise(amplitude: 40, seed: 7)))
        let t0 = HostClock.now() + HostDuration(milliseconds: 400)
        let clock = TickClockSpec(t0: t0, frameRate: format.frameRate)
        let signal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: format.frameRate))
        let highRate = VideoEncodeSettings(codec: .h264, bitrateBps: 40_000_000)
        XCTAssertGreaterThan(DiskGuard.freeBytes(for: mount.appendingPathComponent("x.mov")), 40 * 1024 * 1024, "DiskGuard 在镜像上算得出剩余空间")
        XCTAssertGreaterThan(Recorder.freeBytes(for: mount.appendingPathComponent("x.mov")), 30 * 1_048_576,
                             "Recorder.freeBytes 在镜像上不再是 0（问题单 W3C-w1-outputs-recorder-freebytes-nonboot-volume，G4 2026-09-27 修）")
        // 1 号：监视器按下限 12 MB 报 belowMinimum → 测试停它；2 号：下限 0，真写到满
        let doomedA = Recorder(configuration: .init(url: mount.appendingPathComponent("doomed-a.mov"), format: format, video: highRate,
                                                    audio: AudioEncodeSettings(), minimumFreeBytes: 0, name: "doomed-a"))
        let doomedB = Recorder(configuration: .init(url: mount.appendingPathComponent("doomed-b.mov"), format: format, video: highRate,
                                                    audio: AudioEncodeSettings(), minimumFreeBytes: 0, name: "doomed-b"))
        let healthy = Recorder(configuration: .init(url: TestPaths.file("s7-healthy.mov"), format: format,
                                                    video: VideoEncodeSettings(codec: .h264, bitrateBps: 6_000_000), audio: AudioEncodeSettings(), name: "healthy"))
        let stream = CountingConsumer(name: "stream-standin")
        let start = RecordingStart(clock: clock, tick: .zero)
        try doomedA.start(at: start)
        try doomedB.start(at: start)
        try healthy.start(at: start)

        // 监视：警戒线 30 MB，每 200 ms 轮询；1 号下限 12 MB（事件 → 停它）、2 号下限 0（写到满 → 失败事件 → 切备用目录）
        let monitor = RecordingDiskMonitor(warnBelowBytes: 30 * 1024 * 1024, interval: 0.2)
        monitor.add(doomedA, key: 1, minimumFreeBytes: 12 * 1024 * 1024)
        monitor.add(doomedB, key: 2, minimumFreeBytes: 0)
        monitor.add(healthy, key: 3, minimumFreeBytes: 200 * 1024 * 1024)
        final class EventLog: @unchecked Sendable {
            let lock = NSLock()
            var events: [(Int, RecordingDiskMonitor.Event, HostTime)] = []
            let fallbackWanted = Atomic<Bool>(false)
            let stopAWanted = Atomic<Bool>(false)
        }
        let log = EventLog()
        monitor.onEvent = { key, event in
            log.lock.withLock { log.events.append((key, event, .now())) }
            if key == 2, case .failed(let cause, _, _) = event, cause == .disk { log.fallbackWanted.store(true, ordering: .releasing) }
            if key == 1, case .belowMinimum = event { log.stopAWanted.store(true, ordering: .releasing) }
        }
        monitor.start()

        // 实时喂 16 s；备用目录的录制器在失败事件后的下一拍起
        var consumers: [any FrameConsumer] = [doomedA, doomedB, healthy, stream]
        var audioTargets: [any AudioBlockConsumer] = [doomedA, doomedB, healthy]
        let signalFeeder = SignalFeeder(signal: signal)
        var fallback: Recorder?
        var fallbackStartTick: Tick?
        var fallbackFeeder: SignalFeeder?
        var late = 0
        var stoppedATick: Tick?
        let stopAOutcome = ResultBox<RecordingResult>()
        for tick in 0..<ticks {
            let t = Tick(Int64(tick))
            let tickTime = clock.time(of: t)
            mach_wait_until(tickTime.ticks)
            if (HostClock.now() - tickTime).seconds > format.frameDuration.doubleValue { late += 1 }
            if stoppedATick == nil, log.stopAWanted.load(ordering: .acquiring) {
                stoppedATick = t + 1
                doomedA.stop(atTick: t + 1) { r in stopAOutcome.set(r) }   // S7：低于阈值 → 只停这一路（组装方做的事）
                print("S7：第 \(tick) 拍收到 1 号低于下限的事件，停在第 \(tick + 1) 拍")
            }
            if fallback == nil, log.fallbackWanted.load(ordering: .acquiring) {
                let url = RecordingFallback.url(for: doomedB.configuration.url, directory: fallbackDir.path)
                let startTick = t + 1
                let r = Recorder(configuration: .init(url: url, format: format, video: VideoEncodeSettings(codec: .h264, bitrateBps: 6_000_000),
                                                      audio: AudioEncodeSettings(), name: "fallback"))
                try r.start(at: RecordingStart(clock: clock, tick: startTick))
                consumers.append(r)
                audioTargets.append(r)
                fallbackFeeder = SignalFeeder(signal: signal, startSample: signal.sampleIndex(at: clock.time(of: startTick)))
                fallback = r
                fallbackStartTick = startTick
                print("S7：第 \(tick) 拍收到磁盘失败事件，备用目录录制器从第 \(startTick) 拍起：\(url.path)")
            }
            let frame = try feeder.makeFrame(tick: t, tickTime: tickTime)
            for c in consumers { c.consume(frame) }
            signalFeeder.feed(upTo: tickTime, to: audioTargets.filter { $0 !== fallback })
            if let fallback, let ff = fallbackFeeder { ff.feed(upTo: tickTime, to: [fallback]) }
        }
        let end = Tick(Int64(ticks))
        signalFeeder.flush(upToSample: signal.sampleIndex(at: clock.time(of: end)), to: [healthy])
        if let fallback, let ff = fallbackFeeder { ff.flush(upToSample: signal.sampleIndex(at: clock.time(of: end)), to: [fallback]) }
        monitor.pollOnce()
        monitor.stop()
        let healthyResult = try stopAndWait(healthy, atTick: end)
        let fallbackResult = try fallback.map { try stopAndWait($0, atTick: end) }

        let events = log.lock.withLock { log.events }
        for (key, e, at) in events { print("S7 事件：路 \(key) \(e)（t + \(String(format: "%.2f", (at - t0).seconds)) s）") }
        print("S7：doomed-a \(doomedA.state) 写入 \(doomedA.counters.videoFrames) 帧；doomed-b \(doomedB.state) 写入 \(doomedB.counters.videoFrames) 帧；"
              + "healthy \(healthyResult.videoFrames) 帧 跳帧 \(healthyResult.encoder.skipped)；替身 \(stream.frames) 帧；喂帧晚点 \(late)")

        // 1 号：按下限被停，文件完整（帧数 = 停止拍）；2 号：真写满，失败且归因为磁盘
        let aStop = try XCTUnwrap(stoppedATick, "1 号应收到过下限事件")
        let aResult = try stopAOutcome.get().get()
        XCTAssertEqual(Int(aResult.videoFrames), Int(aStop.rawValue), "1 号按下限停：帧数 = 停止拍")
        XCTAssertEqual(try Tools.probe(aResult.url).errors, "", "1 号文件完整")
        XCTAssertEqual(doomedA.state, .finished)
        guard case .failed(let messageB) = doomedB.state else { return XCTFail("doomed-b 应失败，实际 \(doomedB.state)") }
        XCTAssertEqual(DiskGuard.failureCause(of: doomedB), .disk, "2 号真写满：\(messageB)")
        print("S7：2 号写满的失败文案：\(messageB)")
        // 其他消费者不受影响：录到正常目录的帧数 = 拍数，推流替身帧数 = 拍数
        XCTAssertEqual(Int(healthyResult.videoFrames), ticks, "正常目录那路帧数不受影响")
        XCTAssertEqual(healthyResult.encoder.skipped, 0)
        XCTAssertEqual(Int(stream.frames), ticks, "推流替身的帧数不减")
        XCTAssertEqual(try Tools.probe(healthyResult.url).errors, "")
        // 监视器：1 号先低空间再下限（不失败）；2 号先低空间再失败；正常那路没有事件
        func index(_ list: [(Int, RecordingDiskMonitor.Event, HostTime)], _ match: (RecordingDiskMonitor.Event) -> Bool) -> Int? {
            list.firstIndex { match($0.1) }
        }
        let a = events.filter { $0.0 == 1 }, b = events.filter { $0.0 == 2 }
        let aLow = index(a) { if case .lowSpace = $0 { true } else { false } }
        let aMin = index(a) { if case .belowMinimum = $0 { true } else { false } }
        XCTAssertNotNil(aLow, "1 号应报过低空间")
        XCTAssertNotNil(aMin, "1 号应报过下限")
        if let l = aLow, let m = aMin { XCTAssertLessThan(l, m, "先低空间后下限") }
        XCTAssertNil(index(a) { if case .failed = $0 { true } else { false } }, "1 号是被停的，不该失败")
        let bLow = index(b) { if case .lowSpace = $0 { true } else { false } }
        let bFail = index(b) { if case .failed = $0 { true } else { false } }
        XCTAssertNotNil(bLow, "2 号应报过低空间")
        XCTAssertNotNil(bFail, "2 号应报过失败")
        if let l = bLow, let f = bFail { XCTAssertLessThan(l, f, "先低空间后失败") }
        XCTAssertEqual(b.filter { if case .failed = $0.1 { true } else { false } }.count, 1, "失败只报一次")
        XCTAssertTrue(events.filter { $0.0 == 3 }.isEmpty, "正常目录那路不该有事件")
        // 备用目录：2 号失败后重起的录制器录了剩下的拍，文件可解析
        let fb = try XCTUnwrap(fallbackResult, "应已切到备用目录")
        let fbStart = try XCTUnwrap(fallbackStartTick)
        XCTAssertEqual(Int(fb.videoFrames), Int(end.rawValue - fbStart.rawValue), "备用文件帧数 = 起点到结束的拍数")
        XCTAssertGreaterThanOrEqual(fb.videoFrames, UInt64(2 * fps), "至少录到 2 s")
        XCTAssertEqual(fb.url.deletingLastPathComponent().path, fallbackDir.path)
        XCTAssertEqual(try Tools.probe(fb.url).errors, "")
        // 失败的录制 stop 也要能返回（返回失败），不挂
        for r in [doomedB] {
            let sem = DispatchSemaphore(value: 0)
            r.stop { result in
                if case .success = result { XCTFail("失败的录制 stop 不该成功") }
                sem.signal()
            }
            XCTAssertEqual(sem.wait(timeout: .now() + 10), .success)
        }
    }
}
