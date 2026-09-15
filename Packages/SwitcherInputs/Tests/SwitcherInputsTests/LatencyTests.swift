import AVFoundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherInputs
import SwitcherInputsHarness

/// L1 内部延迟（测试标准 §1 L 系列，§4：≤ 3 帧 / 目标 ≤ 2 帧；W2-A：摄像头 ≤ 3、屏幕 ≤ 3、文件 ≤ 2）。
/// 口径：帧的 ingressTime（进帧槽那一刻）→ 该帧出现在编码器输入（PGM 消费者 consume 入口）的时刻。
/// 组装：真状态机 + 真 Metal 渲染器 + 真引擎（带到达余量的挑帧入口）+ 真帧槽（包一层记录）。
/// 摄像头 / 屏幕需要 TCC 权限：本进程没有就 XCTSkip（BLOCKED-权限），用 Scripts/probe-app.sh 或从 Terminal.app 跑。
final class LatencyTests: XCTestCase {
    private func report(_ label: String, _ s: LatencyStats, format: ProgramFormat) -> String {
        let f = s.frames(at: format.frameRate)
        return String(format: "%@ L1：%d 样本，平均 %.2f ms（%.2f 帧），p50 %.2f，p99 %.2f ms（%.2f 帧），max %.2f ms（%.2f 帧），min %.2f；没帧 %d 拍，重复 %d 拍",
                      label, s.samples, s.meanMs, f.mean, s.p50Ms, s.p99Ms, f.p99, s.maxMs, f.max, s.minMs, s.ticksWithoutFrame, s.ticksReused)
    }

    private func run(config: InputConfig, seconds: Double, pacing: Bool = true,
                     make: (InputEngineHarness, LatencyFrameSlot) throws -> any Input) async throws -> (LatencyStats, Stats, InputEngineHarness) {
        let format = ProgramFormat.hd1080p60
        var engineOptions = EngineOptions()
        engineOptions.pacing.enabled = pacing
        let harness = try InputEngineHarness(format: format, configs: [config], engineOptions: engineOptions)
        let slot = harness.makeSlot(forInput: config.number)
        let input = try make(harness, slot)
        harness.add(input)
        let ticks = Int64(seconds * 60)
        try await harness.start(lastTick: Tick(ticks - 1))
        // 等跑满
        let deadline = HostClock.now() + HostDuration(seconds: seconds + 3)
        while HostClock.now() < deadline, let c = harness.engine.clock, c.ticksDispatched + c.ticksSkipped < UInt64(ticks) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stats = harness.engine.makeStats()
        await harness.stop()
        let l1 = try XCTUnwrap(harness.latency(ofInput: config.number))
        return (l1, stats, harness)
    }

    func testL1_fileInput_within2Frames() async throws {
        let config = InputConfig(number: 1, name: "文件", source: .file(path: RepoPaths.patternMov.path, endAction: .loop, rate: 1))
        let (l1, stats, harness) = try await run(config: config, seconds: 6) { h, slot in
            try FileInput(config: config, timing: h.timing, videoSlot: slot)
        }
        let line = report("文件", l1, format: harness.format)
        print(line)
        let frames = l1.frames(at: harness.format.frameRate)
        XCTAssertGreaterThan(l1.samples, 300, line)
        XCTAssertLessThanOrEqual(frames.mean, 2, "文件 L1 平均应 ≤ 2 帧：\(line)")
        XCTAssertLessThanOrEqual(frames.p99, 2, "文件 L1 p99 应 ≤ 2 帧：\(line)")
        XCTAssertLessThanOrEqual(frames.max, 3, "文件 L1 最大值：\(line)")
        XCTAssertEqual(stats.perInput[1]?.dup ?? 0, 0, "60 fps 文件进 60 fps 节目不该重复：\(stats)")
        XCTAssertLessThanOrEqual(stats.perInput[1]?.drop ?? 0, 3, "\(stats)")
        XCTAssertEqual(stats.missedRender, 0, "\(stats)")
    }

    private func cameraL1(pacing: Bool) async throws -> (LatencyStats, Stats, InputEngineHarness, String) {
        let status = CapturePermission.status(for: .video)
        guard status == .authorized else {
            throw XCTSkip("BLOCKED-权限（TCC）：摄像头权限 \(status)，本进程的责任进程没有相机用途说明，系统不弹提示。从 Terminal.app 跑 swift test，或 Scripts/probe-app.sh run --input camera:0")
        }
        guard let dev = CameraDevices.list().first else { throw XCTSkip("BLOCKED-硬件：没有摄像头") }
        let config = InputConfig(number: 1, name: dev.name, source: .camera(uniqueID: dev.uniqueID))
        let (l1, stats, harness) = try await run(config: config, seconds: 8, pacing: pacing) { h, slot in
            try CameraInput(config: config, timing: h.timing, videoSlot: slot)
        }
        let line = report("摄像头 \(dev.name)（到达余量\(pacing ? "开" : "关")）", l1, format: harness.format)
        print(line)
        if let ps = harness.engine.pacingStats(forInput: 1) { print("  到达余量 \(ps.margin.milliseconds) ms，窗口最大到达延迟 \(ps.windowMaxLatency.milliseconds) ms，迟到 \(ps.lateFrames)") }
        return (l1, stats, harness, line)
    }

    /// 产品配置（引擎默认开到达余量）。目前 ❌：余量 = 16 s 内最大的 d（ingress − pts，摄像头 ≈ 55–100 ms）+ 保护带，
    /// 每帧多等 余量 − d ≈ 20–70 ms，p99 ≈ 3.8 帧；见 reports/issues/W2A-w1-core-arrival-pacing-vs-camera-latency.md。
    func testL1_cameraInput_within3Frames() async throws {
        let (l1, stats, harness, line) = try await cameraL1(pacing: true)
        let frames = l1.frames(at: harness.format.frameRate)
        XCTAssertGreaterThan(l1.samples, 100, line)
        XCTAssertLessThanOrEqual(frames.mean, 3, "摄像头 L1 平均应 ≤ 3 帧：\(line)")
        XCTAssertLessThanOrEqual(frames.p99, 3, "摄像头 L1 p99 应 ≤ 3 帧：\(line)")
        XCTAssertEqual(stats.missedRender, 0)
    }

    /// 对照：引擎走契约入口 latest(atOrBefore:)（不带余量），摄像头的帧到了下一拍就用——这是输入本身的延迟。
    func testL1_cameraInput_contractEntry_within3Frames() async throws {
        let (l1, stats, harness, line) = try await cameraL1(pacing: false)
        let frames = l1.frames(at: harness.format.frameRate)
        XCTAssertGreaterThan(l1.samples, 100, line)
        XCTAssertLessThanOrEqual(frames.mean, 3, "摄像头 L1 平均应 ≤ 3 帧：\(line)")
        XCTAssertLessThanOrEqual(frames.p99, 3, "摄像头 L1 p99 应 ≤ 3 帧：\(line)")
        XCTAssertEqual(stats.missedRender, 0)
        XCTAssertLessThanOrEqual(stats.perInput[1]?.drop ?? 0, 3, "30 fps 摄像头进 60 fps 节目不该丢帧：\(stats)")
    }

    func testL1_screenInput_within3Frames() async throws {
        guard ScreenInput.hasPermission else {
            throw XCTSkip("BLOCKED-权限（TCC）：屏幕录制未授权（本进程的责任进程没有权限，系统不弹提示）。从 Terminal.app 跑，或 Scripts/probe-app.sh run --input screen:0")
        }
        let displays = try await ScreenTargets.displays()
        guard let d = displays.first else { throw XCTSkip("BLOCKED-硬件：没有显示器") }
        let config = InputConfig(number: 1, name: "屏幕", source: .screen(target: .display(id: d.id), frameRate: nil, captureAudio: false))
        let (l1, stats, harness) = try await run(config: config, seconds: 8) { h, slot in
            try ScreenInput(config: config, timing: h.timing, videoSlot: slot)
        }
        let line = report("屏幕 \(d.id)", l1, format: harness.format)
        print(line)
        let frames = l1.frames(at: harness.format.frameRate)
        XCTAssertGreaterThan(l1.samples, 100, line)
        XCTAssertLessThanOrEqual(frames.mean, 3, "屏幕 L1 平均应 ≤ 3 帧：\(line)")
        XCTAssertLessThanOrEqual(frames.p99, 3, "屏幕 L1 p99 应 ≤ 3 帧：\(line)")
        XCTAssertEqual(stats.missedRender, 0)
    }
}
