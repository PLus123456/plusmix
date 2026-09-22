// 虚拟摄像头（W3-C 交付 2）的主程序侧：帧 → CMSampleBuffer 不拷像素、PTS = 拍点；没有设备时消费者不阻塞、计数、每秒重试；
// 系统扩展安装器的状态映射与在未签名宿主里的失败路径。设备本身要签名的扩展才有（BLOCKED-签名）：QuickTime / FaceTime 里选到摄像头、
// L1 到虚拟摄像头出口的测量都在 App 级测试里 XCTSkip，解锁条件 = Team ID 签名 + /Applications。
import CoreMedia
import CoreVideo
import Foundation
import SystemExtensions
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherVirtualCamera

final class VirtualCameraTests: XCTestCase {
    private func nv12Frame(width: Int = 1920, height: Int = 1080, pts: HostTime) -> Frame {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        return Frame(pixelBuffer: pb!, pts: pts, duration: HostDuration(milliseconds: 16), color: .bt709Limited, inputNumber: 0, sequence: 1, ingressTime: pts)
    }

    func testConstants_sharedIdentifiersAreDistinctAndPrefixed() {
        XCTAssertNotEqual(VirtualCameraConstants.sourceStreamUID, VirtualCameraConstants.sinkStreamUID)
        XCTAssertNotEqual(VirtualCameraConstants.deviceUID, VirtualCameraConstants.sourceStreamUID)
        XCTAssertTrue(VirtualCameraConstants.extensionBundleIdentifier.hasPrefix(VirtualCameraConstants.allowedClientSigningIDPrefix))
        XCTAssertEqual(VirtualCameraConstants.width, 1920)
        XCTAssertEqual(VirtualCameraConstants.height, 1080)
    }

    func testSampleBuffer_wrapsSameIOSurfaceWithTickPTS_formatDescriptionCached() throws {
        let output = VirtualCameraOutput(format: .hd1080p60)
        let t = HostTime.now()
        let frame = nv12Frame(pts: t)
        let tickTime = t + HostDuration(milliseconds: 5)
        let sb = try output.makeSampleBuffer(frame, tickTime: tickTime)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(sb) === frame.pixelBuffer, "不拷像素：同一个 CVPixelBuffer")
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sb), tickTime.cmTime, "PTS = 拍点时刻")
        XCTAssertEqual(CMSampleBufferGetDuration(sb), ProgramFormat.hd1080p60.frameDuration.cmTime)
        let fd = try XCTUnwrap(CMSampleBufferGetFormatDescription(sb))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fd), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(fd).width, 1920)
        let sb2 = try output.makeSampleBuffer(nv12Frame(pts: t), tickTime: tickTime)
        XCTAssertTrue(CMSampleBufferGetFormatDescription(sb2) === fd, "同格式同尺寸复用格式描述（每帧零分配之外的部分）")
        let sb3 = try output.makeSampleBuffer(nv12Frame(width: 1280, height: 720, pts: t), tickTime: tickTime)
        XCTAssertFalse(CMSampleBufferGetFormatDescription(sb3) === fd, "尺寸变了换一份")
    }

    /// 本机没有扩展：找不到设备，消费者照收帧（不阻塞、丢并计数）、状态 searching、按间隔重试；stop 干净退出。
    func testOutput_noDevice_searchingRetriesAndDropsWithoutBlocking() throws {
        let devices = CMIOSinkStreamClient.allDevices()
        print("CMIO 设备：\(devices.map { "\($0.name) [\($0.uid)]" })")
        XCTAssertNil(CMIOSinkStreamClient.findDevice(uid: VirtualCameraConstants.deviceUID), "本机没装扩展（BLOCKED-签名）")
        for d in devices { XCTAssertNil(CMIOSinkStreamClient.findSinkStream(device: d.id), "普通摄像头没有 sink 方向的流：\(d.name)") }
        let client = CMIOSinkStreamClient()
        XCTAssertThrowsError(try client.open()) { XCTAssertEqual($0 as? CMIOSinkStreamClient.Error, .deviceNotFound) }
        XCTAssertFalse(client.send(try VirtualCameraOutput(format: .hd1080p60).makeSampleBuffer(nv12Frame(pts: .now()), tickTime: .now())), "没打开就送 = false")

        let output = VirtualCameraOutput(format: .hd1080p60)
        output.retryInterval = HostDuration(milliseconds: 200)
        XCTAssertEqual(output.state, .idle)
        output.start()
        XCTAssertEqual(output.state, .searching)
        let spec = TickClockSpec(t0: .now(), frameRate: .fps60)
        var pushDurations: [Double] = []
        let frame = nv12Frame(pts: .now())
        for i in 0..<60 {
            let t = spec.time(of: Tick(Int64(i)))
            let r = RenderedFrame(tick: Tick(Int64(i)), tickTime: t, program: frame, submitTime: t, gpuStart: t, gpuEnd: t)
            let t0 = HostClock.now()
            output.consume(r)
            pushDurations.append((HostClock.now() - t0).milliseconds)
            usleep(16_667)
        }
        _ = waitUntil(2) { output.countersSnapshot.droppedNoDevice + output.countersSnapshot.droppedQueueFull >= 60 }
        let c = output.countersSnapshot
        let p99 = pushDurations.sorted()[Int(Double(pushDurations.count) * 0.99)]
        print("无设备：收 \(c.framesIn) 丢（无设备）\(c.droppedNoDevice) 丢（队列）\(c.droppedQueueFull) 送 \(c.framesSent) 找设备 \(c.connectAttempts) 次，push p99 \(String(format: "%.4f", p99)) ms，最近错误：\(c.lastError ?? "无")")
        XCTAssertEqual(c.framesIn, 60)
        XCTAssertEqual(c.framesSent, 0)
        XCTAssertEqual(c.droppedNoDevice + c.droppedQueueFull, 60, "没有设备全部丢掉并计数")
        XCTAssertGreaterThanOrEqual(c.connectAttempts, 3, "1 s 里按 200 ms 间隔重试了好几次")
        XCTAssertLessThanOrEqual(c.connectAttempts, 8, "重试有间隔，不是每帧都找")
        XCTAssertEqual(c.lastError, "\(CMIOSinkStreamClient.Error.deviceNotFound)")
        XCTAssertLessThan(p99, 0.1, "consume 只入队，微秒级")
        XCTAssertEqual(output.state, .searching)
        output.stop()
        XCTAssertEqual(output.state, .stopped)
        output.consume(RenderedFrame(tick: .zero, tickTime: .now(), program: frame, submitTime: .now(), gpuStart: .now(), gpuEnd: .now()))
        XCTAssertEqual(output.countersSnapshot.framesIn, 60, "stop 之后不再收")
    }

    /// 提案 013：虚拟摄像头在 Stats 里的一项。frames = 排进 sink stream 的帧；dropped = 三种丢的和；state 在 013 的列表里。
    func testP3_013_virtualCameraStatsEntry() throws {
        let output = VirtualCameraOutput(format: .hd1080p60)
        output.retryInterval = HostDuration(milliseconds: 200)
        // idle
        var e = output.statsEntry(output: 5)
        XCTAssertEqual(e.output, 5)
        XCTAssertEqual(e.kind, "virtualCamera")
        XCTAssertEqual(e.state, "idle")
        XCTAssertEqual(e.frames, 0)
        XCTAssertEqual(e.dropped, 0)
        XCTAssertTrue(Stats.DisplayEntry.kinds.contains(e.kind))
        // 找设备中（扩展没装 / 没激活）
        output.start()
        e = output.statsEntry(output: 5)
        XCTAssertEqual(e.state, "waitingExtension")
        // 送几帧：没有设备 → dropped 递增、frames 不动（有签名的扩展时 frames 才涨，见 BLOCKED-签名）
        let spec = TickClockSpec(t0: .now(), frameRate: .fps60)
        let frame = nv12Frame(pts: .now())
        for i in 0..<10 {
            let t = spec.time(of: Tick(Int64(i)))
            output.consume(RenderedFrame(tick: Tick(Int64(i)), tickTime: t, program: frame, submitTime: t, gpuStart: t, gpuEnd: t))
            usleep(5_000)
        }
        _ = waitUntil(2) { output.statsEntry(output: 5).dropped >= 10 }
        e = output.statsEntry(output: 5)
        let c = output.countersSnapshot
        XCTAssertEqual(e.frames, c.framesSent, "frames = 已送出（与 countersSnapshot 同源，铁律 4）")
        XCTAssertEqual(e.dropped, c.droppedQueueFull &+ c.droppedNoDevice &+ c.droppedSink)
        XCTAssertGreaterThanOrEqual(e.dropped, 10)
        XCTAssertTrue(Stats.DisplayEntry.states.contains(e.state), e.state)
        // 停掉
        output.stop()
        XCTAssertEqual(output.statsEntry(output: 5).state, "stopped")
        // 与 W3-C2（prompt 65）复核的对照：有签名扩展时 state = publishing、frames 随送出递增
        if output.state == .connected { XCTAssertEqual(output.statsEntry(output: 5).state, "publishing") }
    }

    func testInstaller_statusMapping() {
        XCTAssertEqual(SystemExtensionInstaller.status(for: .completed, version: "0.1.0"), .installed(version: "0.1.0"))
        XCTAssertEqual(SystemExtensionInstaller.status(for: .willCompleteAfterReboot, version: "0.1.0"), .needsReboot)
        let notFound = NSError(domain: OSSystemExtensionErrorDomain, code: OSSystemExtensionError.Code.extensionNotFound.rawValue, userInfo: [NSLocalizedDescriptionKey: "Extension not found"])
        guard case .failed(let m1) = SystemExtensionInstaller.status(for: notFound) else { return XCTFail() }
        XCTAssertTrue(m1.contains("BLOCKED-签名"), m1)
        let badSig = NSError(domain: OSSystemExtensionErrorDomain, code: OSSystemExtensionError.Code.codeSignatureInvalid.rawValue, userInfo: [:])
        guard case .failed(let m2) = SystemExtensionInstaller.status(for: badSig) else { return XCTFail() }
        XCTAssertTrue(m2.contains("签名"), m2)
        XCTAssertEqual(SystemExtensionInstaller.status(for: NSError(domain: OSSystemExtensionErrorDomain, code: OSSystemExtensionError.Code.authorizationRequired.rawValue, userInfo: [:])), .needsUserApproval)
        guard case .failed = SystemExtensionInstaller.status(for: NSError(domain: "x", code: 1, userInfo: [:])) else { return XCTFail() }
        XCTAssertEqual(SystemExtensionInstaller.describe(.needsUserApproval), "等待在「系统设置 → 隐私与安全性」里允许")
        XCTAssertTrue(SystemExtensionInstaller.developerModeHint.contains("SIP"))
    }

    /// 在没有扩展 / 未签名的宿主里发激活请求：不崩，几秒内回到 failed（文案带 BLOCKED-签名）。真正的激活 BLOCKED-签名。
    @MainActor
    func testInstaller_activateInUnsignedHost_failsWithClearMessage() throws {
        let installer = SystemExtensionInstaller()
        var statuses: [SystemExtensionInstaller.Status] = []
        installer.onStatusChange = { statuses.append($0) }
        installer.activate()
        XCTAssertEqual(installer.status, .requesting)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if case .failed = installer.status { break }
            if case .needsUserApproval = installer.status { break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        print("未签名宿主里的激活请求：\(statuses.map(SystemExtensionInstaller.describe))")
        switch installer.status {
        case .failed(let message):
            XCTAssertFalse(message.isEmpty)
        case .needsUserApproval:
            XCTFail("未签名宿主不该走到用户批准")
        default:
            throw XCTSkip("8 s 内没有回调（系统扩展服务没应答）；激活本身 BLOCKED-签名")
        }
    }
}

extension XCTestCase {
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2000)
        }
        return condition()
    }
}
