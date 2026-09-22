// W3-C S7（App 级）：录到 hdiutil 建的 50 MB 小镜像。(a) 剩余空间低于下限 → 只停那路录制、状态行提示、快照的 enabled 回 false，
// 推流（有 MediaMTX 时真推，否则跳过这一项）帧数不减、missed_render 不增；(b) 下限 0 + 备用目录 → 真写满后自动切到备用目录继续录。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherISO
@testable import Switcher

@MainActor
final class DiskProtectionAppTests: XCTestCase {
    private func mountTinyVolume(name: String) throws -> (mount: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/s7", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let image = base.appendingPathComponent("\(name).dmg")
        let mount = base.appendingPathComponent("\(name)-volume", isDirectory: true)
        try? FileManager.default.removeItem(at: image)
        _ = try? AppTest.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard (try? AppTest.run("/usr/bin/hdiutil", ["create", "-size", "50m", "-fs", "APFS", "-volname", "S7\(name)", "-quiet", image.path]))?.code == 0 else {
            throw XCTSkip("hdiutil create 失败")
        }
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard (try? AppTest.run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-quiet", "-mountpoint", mount.path]))?.code == 0 else {
            throw XCTSkip("hdiutil attach 失败")
        }
        return (mount, { _ = try? AppTest.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]); try? FileManager.default.removeItem(at: image) })
    }

    /// 噪声底纹的合成源（静态图案压不出码率，写不满盘）。
    private func noisyShow(recordDirectory: String, bitrate: Int) -> Show {
        var show = AppTest.controller.documents.emptyShow(name: "s7")
        show.inputs = [InputConfig(number: 1, name: "噪声", source: .synthetic(settings: SyntheticSourceSettings(
            frameRate: .fps60, width: 1920, height: 1080, background: .noise(level: 128, amplitude: 40, seed: 7), audio: true)))]
        show.mixer.program = 1
        show.outputs[0].settings.video = VideoEncodeSettings(codec: .h264, bitrateBps: bitrate)
        show.outputs[0].settings.record = RecordSettings(directory: recordDirectory)
        return show
    }

    private func start(_ show: Show) throws -> SwitcherSession {
        _ = try AppTest.runningSession()   // 等启动时的 replaceSession 完成，否则这次 replaceSession 会被 replacing 挡掉
        let done = AppTest.expectationBox()
        Task { await AppTest.controller.replaceSession(show: show); done.value = true }
        guard AppTest.waitUntil(20, { done.value && AppTest.controller.session?.isRunning == true }) else { throw XCTSkip("节目没起来") }
        let session = try XCTUnwrap(AppTest.controller.session)
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 10), .live)
        return session
    }

    func testS7_lowSpaceStopsOnlyRecording_streamAndRenderUnaffected() throws {
        let (mount, cleanup) = try mountTinyVolume(name: "a")
        defer { cleanup() }
        var show = noisyShow(recordDirectory: mount.path, bitrate: 20_000_000)
        var mtx: MediaMTXHarness?
        if FileManager.default.isExecutableFile(atPath: MediaMTXHarness.binary), let m = try? MediaMTXHarness(recordDir: FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/s7-mtx")) {
            mtx = m
            show.outputs.append(OutputState(number: 2, kind: .stream, name: "推流", enabled: false,
                                            settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(), stream: StreamSettings(url: m.rtmpURL("s1")))))   // mediamtx.yml 只配了 s1 / s2 / s3
        }
        defer { mtx?.stop() }
        let session = try start(show)
        let wc = AppTest.controller.windowController
        XCTAssertEqual(session.outputs.minimumFreeBytes, 200 * 1024 * 1024, "默认下限 200 MB（50 MB 的盘从一开始就低于它）")
        AppTest.pump(seconds: 1.5)
        if mtx != nil {
            session.send(.startStream(output: 2))
            XCTAssertTrue(AppTest.waitUntil(15) { wc.bottomBar.encoderEntry(forOutput: 2)?.state == "publishing" }, "推流应先连上")
        }
        let statsBefore = try XCTUnwrap(session.stats)
        var notices: [String] = []
        let noticeToken = session.observeNotices { notices.append($0) }
        defer { noticeToken.invalidate() }
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil }, "录制器应起来（下限由监视器管，录制器自己不查空间）")
        // 监视器 1 s 内看到剩余 < 200 MB → 停这一路、发 stopRecord、提示
        XCTAssertTrue(AppTest.waitUntil(6) { session.state.outputs.first { $0.number == 1 }?.enabled == false }, "低于下限应发 stopRecord 让快照回 false")
        XCTAssertTrue(AppTest.waitUntil(10) { session.outputs.recorders[1] == nil }, "那路录制应停下")
        print("S7(a) 提示：\(notices)；磁盘事件：\(session.outputs.diskEvents)")
        XCTAssertTrue(notices.contains { $0.contains("磁盘") }, "状态行应提示过磁盘：\(notices)")
        guard case .belowMinimum? = session.outputs.diskEvents[1] else { return XCTFail("应是低于下限事件：\(String(describing: session.outputs.diskEvents[1]))") }
        // 之后 3 s：推流帧数继续增、missed_render 不增
        let streamFrames0 = wc.bottomBar.encoderEntry(forOutput: 2)?.frames ?? 0
        AppTest.pump(seconds: 3)
        let statsAfter = try XCTUnwrap(session.stats)
        if mtx != nil {
            let streamFrames1 = wc.bottomBar.encoderEntry(forOutput: 2)?.frames ?? 0
            print("S7(a) 推流帧数 \(streamFrames0) → \(streamFrames1)")
            XCTAssertGreaterThan(streamFrames1, streamFrames0 + 120, "推流帧数不减、继续增")
            XCTAssertEqual(wc.bottomBar.encoderEntry(forOutput: 2)?.state, "publishing")
        } else {
            print("S7(a)：没有 mediamtx，推流部分未测（BLOCKED-工具）")
        }
        XCTAssertEqual(statsAfter.missedRender, statsBefore.missedRender, "missed_render 不增")
        XCTAssertGreaterThan(statsAfter.tick, statsBefore.tick + 120, "渲染在走")
        // 再按录制：failed 清了之后能再起（又会因低空间停，这里只看它能起）
        XCTAssertNil(session.outputs.failed[1], "enabled 回 false 后 failed 应清掉，下次还能起")
    }

    func testS7_diskFullSwitchesToFallbackDirectory_recordingContinues() throws {
        try AppTest.requireFFprobe()
        let (mount, cleanup) = try mountTinyVolume(name: "b")
        defer { cleanup() }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/s7-fallback", isDirectory: true)
        try? FileManager.default.removeItem(at: fallback)
        let session = try start(noisyShow(recordDirectory: mount.path, bitrate: 40_000_000))
        session.outputs.minimumFreeBytes = 0
        session.outputs.fallbackDirectory = fallback.path
        AppTest.pump(seconds: 1.5)
        let statsBefore = try XCTUnwrap(session.stats)
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil })
        let firstURL = try XCTUnwrap(session.outputs.recorders[1]?.url)
        XCTAssertEqual(firstURL.deletingLastPathComponent().path, mount.path)
        // 写满（40 Mbps 噪声约 10 s）→ 切备用目录
        XCTAssertTrue(AppTest.waitUntil(40) { session.outputs.recorders[1]?.onFallback == true }, "应切到备用目录：\(session.outputs.diskEvents)")
        let secondURL = try XCTUnwrap(session.outputs.recorders[1]?.url)
        print("S7(b)：\(firstURL.lastPathComponent) 写满 → 备用 \(secondURL.path)；提示：\(session.lastNotice ?? "")；事件：\(String(describing: session.outputs.diskEvents[1]))")
        XCTAssertEqual(secondURL.deletingLastPathComponent().path, fallback.path)
        XCTAssertTrue((session.lastNotice ?? "").contains("备用目录"))
        XCTAssertEqual(session.state.outputs.first { $0.number == 1 }?.enabled, true, "切备用目录不停录制")
        AppTest.pump(seconds: 3)
        session.send(.stopRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(20) { session.outputs.recorders.isEmpty && session.outputs.lastResults[1] != nil })
        let result = try XCTUnwrap(session.outputs.lastResults[1])
        XCTAssertEqual(result.url, secondURL, "最后的结果是备用目录那个文件")
        XCTAssertGreaterThanOrEqual(result.videoFrames, 120, "备用文件至少录了 2 s")
        let probe = try AppTest.ffprobeStreams(secondURL)
        XCTAssertEqual(probe.errors, "")
        let statsAfter = try XCTUnwrap(session.stats)
        XCTAssertEqual(statsAfter.missedRender, statsBefore.missedRender, "整个过程 missed_render 不增")
    }
}
