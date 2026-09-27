import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherISO

/// W3-C3 交付 3 的两处 ISO 侧兜底，都不靠 W1-E 录制器给人看的（中文）失败文案：
/// - 录制器自己按下限停的（它记下的剩余空间低于它的 minimumFreeBytes）归磁盘——以前靠文案里的"磁盘"二字认；
/// - 在跑的录制器在 Stats 里的 disk_free_mb：`Recorder.freeBytes` 只看 importantUsage 键，非启动卷（磁盘镜像 / 外置盘）上恒 0
///   （问题单 W3C-w1-outputs-recorder-freebytes-nonboot-volume，W1-E 还没修），读到 0 时用 `DiskGuard.freeBytes` 重新量。
final class RecorderDiskTests: XCTestCase {
    private let format = ProgramFormat.hd720p60

    private func start(_ recorder: Recorder) throws {
        let clock = TickClockSpec(t0: HostClock.now() + HostDuration(milliseconds: 100), frameRate: format.frameRate)
        try recorder.start(at: RecordingStart(clock: clock, tick: .zero))
    }

    /// 停掉（一帧没写，结果是失败，不关心），等它回调完。
    private func discard(_ recorder: Recorder) {
        let done = DispatchSemaphore(value: 0)
        recorder.stop { _ in done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }

    func testS7_recorderStoppedByItsOwnMinimumIsDisk_withoutReadingMessageText() throws {
        let url = TestPaths.file("w3c3-below-minimum-\(UUID().uuidString.prefix(6)).mov")
        // 下限设成比任何盘都大：录制器一起步就按"低于下限"停（与写到阈值时同一条路：先记下读数，再比下限）
        let recorder = Recorder(configuration: .init(url: url, format: format, audio: nil, minimumFreeBytes: UInt64.max, name: "below-minimum"))
        XCTAssertThrowsError(try start(recorder)) { XCTAssertEqual($0 as? Recorder.Error, .diskFull(freeBytes: recorder.counters.diskFreeBytes)) }
        guard case .failed(let message) = recorder.state else { return XCTFail("应已失败：\(recorder.state)") }
        print("录制器按自己的下限停，失败文案（W1-E 的）：\(message)")
        XCTAssertLessThan(recorder.counters.diskFreeBytes, recorder.configuration.minimumFreeBytes, "失败前记下的读数")
        XCTAssertGreaterThan(DiskGuard.freeBytes(for: url), DiskGuard.lowWaterBytes, "本机启动卷空间充足：光看剩余空间认不出")
        XCTAssertEqual(DiskGuard.failureCause(of: recorder), .disk, "按录制器自己的读数与下限归磁盘，不看文案")
        XCTAssertEqual(DiskGuard.classify(recorder: recorder, message: message, freeBytes: DiskGuard.freeBytes(for: url)), .disk)

        // 监视器报的失败事件用同一个归因
        let monitor = RecordingDiskMonitor(warnBelowBytes: 0, interval: 60)
        monitor.add(recorder, key: 7, minimumFreeBytes: 0)
        final class Events: @unchecked Sendable {
            let lock = NSLock()
            var list: [RecordingDiskMonitor.Event] = []
        }
        let events = Events()
        monitor.onEvent = { key, event in if key == 7 { events.lock.withLock { events.list.append(event) } } }
        XCTAssertEqual(monitor.pollOnce(), 1)
        let got = events.lock.withLock { events.list }
        guard case .failed(let cause, let reported, _)? = got.first else { return XCTFail("应报失败：\(got)") }
        XCTAssertEqual(cause, .disk)
        XCTAssertEqual(reported, message, "文案原样转给组装方（给人看的由它处理），归因不靠它")
        XCTAssertEqual(monitor.pollOnce(), 0, "失败只报一次")

        // 下限为 0（App 的设法，下限交给监视器）的录制器不会走这条路：别的失败照常按错误码 + 剩余空间归
        let other = Recorder(configuration: .init(url: TestPaths.file("w3c3-min0.mov"), format: format, audio: nil, minimumFreeBytes: 0, name: "min0"))
        XCTAssertEqual(DiskGuard.classify(recorder: other, message: "编码器启动失败：sessionCreateFailed(-12903)", freeBytes: 10_000_000_000), .other)
        XCTAssertEqual(DiskGuard.classify(recorder: other, message: "Error Domain=NSPOSIXErrorDomain Code=28", freeBytes: 10_000_000_000), .disk)
        XCTAssertNil(DiskGuard.failureCause(of: other), "没失败：nil")
    }

    func testS7_runningRecorderDiskFreeFallsBackToDiskGuard_nonBootVolume() throws {
        let volume = try TinyVolume.mount("w3c3-freebytes")
        defer { volume.detach() }
        let url = volume.mountPoint.appendingPathComponent("iso-1.mov")
        let onImage = Recorder(configuration: .init(url: url, format: format, video: VideoEncodeSettings(bitrateBps: 2_000_000), audio: nil,
                                                    minimumFreeBytes: 0, name: "on-image"))
        try start(onImage)
        defer { discard(onImage) }
        let c = onImage.counters
        let measured = DiskGuard.freeBytes(for: url)
        let entry = DiskGuard.statsEntry(for: onImage, counters: c, previous: nil, windowSeconds: 1)
        print("镜像上：录制器自己读到 \(c.diskFreeBytes) 字节（W1-E 的 Recorder.freeBytes），DiskGuard 量到 \(measured) 字节，Stats disk_free_mb = \(entry.diskFreeMb)")
        XCTAssertGreaterThan(measured, 30 * 1_048_576, "50 MB 的镜像")
        XCTAssertEqual(entry.diskFreeMb, Double(measured) / 1_048_576, accuracy: 2, "非启动卷上不再报 0（录制器读到 0 时由 DiskGuard 重新量；W1-E 修好之后就是它自己的读数）")
        var plain = c.statsEntry(previous: nil, windowSeconds: 1, state: onImage.state.statsName)
        XCTAssertEqual(plain.state, "recording")
        plain.diskFreeMb = entry.diskFreeMb
        XCTAssertEqual(entry, plain, "除了 disk_free_mb，其余与 RecorderCounters.statsEntry 相同")

        // 启动卷上：录制器自己的读数不是 0，原样用（不多量一次）
        let onBoot = Recorder(configuration: .init(url: TestPaths.file("w3c3-boot.mov"), format: format, video: VideoEncodeSettings(bitrateBps: 2_000_000),
                                                   audio: nil, minimumFreeBytes: 0, name: "on-boot"))
        try start(onBoot)
        defer { discard(onBoot) }
        let b = onBoot.counters
        XCTAssertGreaterThan(b.diskFreeBytes, 0)
        XCTAssertEqual(DiskGuard.diskFreeBytes(of: onBoot, counters: b), b.diskFreeBytes)
        XCTAssertEqual(DiskGuard.statsEntry(for: onBoot, counters: b, previous: nil, windowSeconds: 1).diskFreeMb, Double(b.diskFreeBytes) / 1_048_576)
        // 还没起过的录制器（读数 0）：也量得出来
        let idle = Recorder(configuration: .init(url: url.deletingLastPathComponent().appendingPathComponent("iso-2.mov"), format: format, audio: nil, name: "idle"))
        XCTAssertEqual(Double(DiskGuard.diskFreeBytes(of: idle, counters: idle.counters)), Double(measured), accuracy: 2 * 1_048_576)
    }
}

/// hdiutil 建的小盘（非启动卷；S7 用例同一个做法），测完卸掉。
struct TinyVolume {
    let image: URL
    let mountPoint: URL

    static func mount(_ name: String, megabytes: Int = 50) throws -> TinyVolume {
        let image = TestPaths.file("\(name).dmg")
        let mount = TestPaths.file("\(name)-volume")
        try? FileManager.default.removeItem(at: image)
        _ = try? runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard (try? runProcess("/usr/bin/hdiutil", ["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "W3C3Tiny", "-quiet", image.path]))?.code == 0 else {
            throw XCTSkip("hdiutil create 失败")
        }
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard (try? runProcess("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-quiet", "-mountpoint", mount.path]))?.code == 0 else {
            try? FileManager.default.removeItem(at: image)
            throw XCTSkip("hdiutil attach 失败")
        }
        return TinyVolume(image: image, mountPoint: mount)
    }

    func detach() {
        _ = try? runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        try? FileManager.default.removeItem(at: image)
    }
}
