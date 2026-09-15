import AVFoundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherInputs

/// CameraInput：S6 权限、真机帧 / 时间戳、S5 热插拔（需要外接设备）。
final class CameraInputTests: XCTestCase {
    private func makeTiming() -> ProgramTiming { ProgramTiming(format: .hd1080p60, t0: HostClock.now()) }

    // MARK: S6 权限被拒：启动不崩、文案清楚；授权后自动恢复（手动部分见报告）

    func testS6_cameraPermissionDenied_startDoesNotCrash_messageIsClear() throws {
        let status = CapturePermission.status(for: .video)
        if status == .authorized {
            throw XCTSkip("本进程已有摄像头权限；S6 的拒绝路径要在系统设置里撤销权限后再跑（步骤见 reports/w2-inputs.md §2 S6）")
        }
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = CameraInput(number: 1, name: "cam", uniqueID: "0", timing: makeTiming(), videoSlot: slot)
        XCTAssertNoThrow(try input.start())
        // 权限被拒（或系统不弹提示就拒）→ error(文案)。请求期间先是"等待系统提示"的过渡文案，要等到最终结论
        func finalError() -> String? {
            if case .error(let m) = input.state, !m.contains("等待系统提示") { return m }
            return nil
        }
        let settled = waitUntil(timeoutMs: 5000) { finalError() != nil }
        if !settled, case .error(let m) = input.state {
            throw XCTSkip("系统正在等用户回答授权提示（\(m)）；回答后再跑")
        }
        XCTAssertTrue(settled, "5 s 内没进 error：\(input.state) \(input.lastError ?? "")")
        guard let message = finalError() else { return XCTFail("\(input.state)") }
        print("S6 文案：\(message)")
        XCTAssertTrue(message.contains("摄像头权限"), message)
        XCTAssertTrue(message.contains("系统设置") || message.contains("用途说明"), "文案要告诉用户去哪里改：\(message)")
        XCTAssertTrue(message.contains("自动恢复"), "文案要说明授权后自动恢复：\(message)")
        XCTAssertNil(slot.latest(atOrBefore: .now()), "没权限不该有帧")
        // 停得下来，且不崩
        input.stop()
        XCTAssertEqual(input.state, .noSignal)
        XCTAssertGreaterThanOrEqual(input.counters.errorTransitions, 1)
    }

    // MARK: 真机：帧到达、host time 时间戳、格式协商

    func testCamera_builtIn_deliversNV12FramesWithHostTimestamps() throws {
        let status = CapturePermission.status(for: .video)
        guard status == .authorized else {
            throw XCTSkip("BLOCKED-权限（TCC）：摄像头权限 \(status)。从 Terminal.app 跑 swift test 或用 Scripts/probe-app.sh")
        }
        guard let dev = CameraDevices.list().first else { throw XCTSkip("BLOCKED-硬件：没有摄像头") }
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = CameraInput(number: 3, name: dev.name, uniqueID: dev.uniqueID, timing: timing, videoSlot: slot)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 8000) { input.state == .live }, "8 s 内没进 live：\(input.state) \(input.lastError ?? "")")
        let negotiated = try XCTUnwrap(input.negotiated)
        print("协商：\(negotiated.candidate.width)×\(negotiated.candidate.height) @ \(negotiated.frameRate)（\(CameraDevices.fourCC(negotiated.candidate.mediaSubType))）匹配节目帧率 \(negotiated.matchesProgramFrameRate)")
        let driver = TickDriver(timing: timing)
        let picks = driver.run(from: driver.firstTick(afterMs: 30), count: 120) { n, t in Pick(tick: n, tickTime: t, frame: slot.latest(atOrBefore: t)) }
        let withFrame = picks.filter(\.hasFrame)
        XCTAssertGreaterThan(withFrame.count, 100, "2 s 里绝大多数拍都该有帧")
        for p in withFrame.prefix(200) {
            XCTAssertEqual(p.pixelFormat, .nv12, "\(p)")
            XCTAssertEqual(p.inputNumber, 3)
            if let pts = p.pts, let ing = p.ingressTime {
                XCTAssertLessThanOrEqual(pts, ing, "pts（采集时刻）应早于进帧槽时刻：\(p)")
                XCTAssertLessThan((ing - pts).milliseconds, 500, "采集到送达的延迟异常：\(p)")
            }
        }
        let ts = input.timestampStats
        print("时间戳：syncClock==host \(String(describing: ts.syncClockIsHostClock))，d 平均 \(ts.meanDelayMs) ms，max \(ts.maxDelayMs)，min \(ts.minDelayMs)，采集丢帧 \(ts.droppedByCapture)")
        XCTAssertNotNil(ts.syncClockIsHostClock)
        let c = input.counters
        let expectedFps = negotiated.frameRate
        XCTAssertGreaterThan(Double(c.framesPushed), expectedFps * 1.5, "2 s 至少 1.5 s 的帧：\(c)")
        XCTAssertLessThanOrEqual(c.distinctSurfaces, 16, "采集池应稳定复用：\(c.distinctSurfaces)")
        XCTAssertEqual(c.noSignalTransitions, 0)
    }

    // MARK: S5 热插拔：需要外接 USB 摄像头 / UVC 卡，用户手动拔插 20 次

    func testS5_hotplug20Cycles_noCrash_recoversWithin3s_numberKept() throws {
        guard let id = ProcessInfo.processInfo.environment["SWITCHER_HOTPLUG_CAMERA"] else {
            throw XCTSkip("BLOCKED-硬件：需要外接 USB 摄像头 / UVC 采集卡。跑法：SWITCHER_HOTPLUG_CAMERA=<uniqueID> swift test --filter testS5，或 Scripts/hotplug-timer.sh <uniqueID>（后者在 .app 里跑，带权限）")
        }
        guard CapturePermission.status(for: .video) == .authorized else { throw XCTSkip("BLOCKED-权限（TCC）") }
        let cycles = Int(ProcessInfo.processInfo.environment["SWITCHER_HOTPLUG_CYCLES"] ?? "20") ?? 20
        let timing = makeTiming()
        let slot = LockFreeFrameSlot(capacity: 3)
        let input = CameraInput(number: 5, name: "hotplug", uniqueID: id, timing: timing, videoSlot: slot)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 10000) { input.state == .live }, "设备起不来：\(input.state) \(input.lastError ?? "")")
        let result = HotplugTimer.run(input: input, cycles: cycles, cycleTimeoutSeconds: 120) { print($0) }
        print(result.summary)
        XCTAssertEqual(result.completedCycles, cycles)
        XCTAssertEqual(input.number, 5)
        XCTAssertLessThanOrEqual(result.maxRecoverySeconds, 3, "恢复 ≤ 3 s：\(result.summary)")
    }
}
