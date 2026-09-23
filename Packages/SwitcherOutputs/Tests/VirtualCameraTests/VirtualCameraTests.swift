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

    /// 提案 013：虚拟摄像头在 Stats 里的一项。frames = 排进 sink stream 的帧；state 在 013 的列表里。
    /// W3-C2 复核：dropped = "被扩展丢弃"（契约注释）——连上之后送不进 / 扩展没输出的帧，**不含**扩展没装时丢掉的
    /// （那段是 waitingExtension，没在发布；数字仍在 countersSnapshot.droppedNoDevice 里给状态行用）。
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
        // 送几帧：没有设备 → frames 不动、dropped 不动（没在发布），无设备的丢帧只进 countersSnapshot
        let spec = TickClockSpec(t0: .now(), frameRate: .fps60)
        let frame = nv12Frame(pts: .now())
        for i in 0..<10 {
            let t = spec.time(of: Tick(Int64(i)))
            output.consume(RenderedFrame(tick: Tick(Int64(i)), tickTime: t, program: frame, submitTime: t, gpuStart: t, gpuEnd: t))
            usleep(5_000)
        }
        XCTAssertTrue(waitUntil(2) { output.countersSnapshot.droppedNoDevice + output.countersSnapshot.droppedQueueFull >= 10 })
        e = output.statsEntry(output: 5)
        let c = output.countersSnapshot
        XCTAssertEqual(e.frames, c.framesSent, "frames = 已送出（与 countersSnapshot 同源，铁律 4）")
        XCTAssertEqual(e.dropped, c.droppedQueueFull &+ c.droppedSink &+ c.droppedExtension, "dropped = 连上之后丢的三项")
        XCTAssertEqual(c.droppedNoDevice, 10, "没设备的 10 帧都记在这里")
        XCTAssertEqual(e.dropped, 0, "扩展没装时丢的不是'被扩展丢弃'")
        XCTAssertEqual(e.undelivered, 10, "提案 018：没连上时丢的进 undelivered")
        XCTAssertEqual(e.undelivered, c.droppedNoDevice, "与 countersSnapshot 同源（铁律 4）")
        XCTAssertEqual(e.state, "waitingExtension")
        XCTAssertTrue(Stats.DisplayEntry.states.contains(e.state), e.state)
        // 停掉
        output.stop()
        XCTAssertEqual(output.statsEntry(output: 5).state, "stopped")
        // 连上之后的 publishing / frames / dropped 由 testVirtualCamera_fakeSink… 用假 sink 覆盖（真扩展 BLOCKED-签名）
    }

    // MARK: W3-C2：假 sink 覆盖连上之后的路（真扩展要 Team ID 签名，BLOCKED-签名）

    /// 送帧、排队失败、扩展回报、掉线回到找设备、打开失败的两种状态。
    func testVirtualCamera_fakeSinkPublishing_framesDroppedAndStates() throws {
        let sink = FakeSink()
        let output = VirtualCameraOutput(format: .hd1080p60, sink: sink)
        output.retryInterval = HostDuration(milliseconds: 20)
        output.sinkLossThreshold = 8
        output.start()
        defer { output.stop() }
        let frame = nv12Frame(pts: .now())
        var tick: Int64 = 0
        func feed(_ n: Int) {
            for _ in 0..<n {
                let t = HostTime.now()
                output.consume(RenderedFrame(tick: Tick(tick), tickTime: t, program: frame, submitTime: t, gpuStart: t, gpuEnd: t))
                tick += 1
                usleep(4_000)
            }
        }
        // 1. 连上：publishing，frames = 排进去的帧，序号从 0 连续挂在样本上
        feed(30)
        XCTAssertTrue(waitUntil(2) { output.statsEntry(output: 7).frames == 30 })
        var e = output.statsEntry(output: 7)
        XCTAssertEqual(e.state, "publishing")
        XCTAssertEqual(e.dropped, 0)
        XCTAssertEqual(e.undelivered, 0, "一上来就连上了：没有没送出去的")
        XCTAssertEqual(sink.sequences, Array(0..<30), "每帧挂 CMIO 序号（扩展按它回报'已输出'）")
        // 2. sink 队列满 5 帧（没到掉线门限）：dropped = 5，frames 不动；序号不跳（没排进去的帧不占号）
        sink.acceptSends = false
        feed(5)
        XCTAssertTrue(waitUntil(2) { output.countersSnapshot.droppedSink == 5 })
        sink.acceptSends = true
        feed(3)
        XCTAssertTrue(waitUntil(2) { output.statsEntry(output: 7).frames == 33 })
        e = output.statsEntry(output: 7)
        XCTAssertEqual(e.dropped, 5)
        XCTAssertEqual(sink.sequences.suffix(3), [30, 31, 32])
        // 3. 扩展回报：已输出 28、序号跳过 2 → dropped 加上扩展丢的
        sink.report = SinkOutputReport(output: 28, dropped: 2)
        feed(1)
        XCTAssertTrue(waitUntil(2) { output.countersSnapshot.droppedExtension == 2 })
        e = output.statsEntry(output: 7)
        XCTAssertEqual(e.dropped, 5 + 2)
        XCTAssertEqual(output.countersSnapshot.framesOutput, 28)
        // 4. 连续送不进（扩展停了 / 被卸载）→ 关掉重找；设备不在 → waitingExtension，之后的帧不算 dropped
        sink.acceptSends = false
        sink.openError = CMIOSinkStreamClient.Error.deviceNotFound
        feed(20)
        XCTAssertTrue(waitUntil(2) { output.state == .searching })
        XCTAssertTrue(waitUntil(2) { output.statsEntry(output: 7).state == "waitingExtension" })
        let droppedAtLoss = output.statsEntry(output: 7).dropped
        let undeliveredAtLoss = output.statsEntry(output: 7).undelivered
        feed(10)
        XCTAssertTrue(waitUntil(2) { output.countersSnapshot.droppedNoDevice >= 10 })
        XCTAssertEqual(output.statsEntry(output: 7).dropped, droppedAtLoss, "没连上时丢的不进 dropped")
        XCTAssertGreaterThanOrEqual(output.statsEntry(output: 7).undelivered, undeliveredAtLoss + 10, "提案 018：进 undelivered")
        XCTAssertEqual(output.statsEntry(output: 7).undelivered, output.countersSnapshot.droppedNoDevice)
        XCTAssertGreaterThanOrEqual(sink.closes, 1)
        // 5. 设备在、但流起不来（签名不符被扩展拒、sink 流没了……）→ failed
        sink.openError = CMIOSinkStreamClient.Error.startFailed(-1)
        feed(10)
        XCTAssertTrue(waitUntil(2) { output.statsEntry(output: 7).state == "failed" }, output.statsEntry(output: 7).state)
        // 6. 好了：重连，序号从 0 重新开始
        sink.openError = nil
        sink.acceptSends = true
        let before = sink.sequences.count
        feed(10)
        XCTAssertTrue(waitUntil(2) { output.statsEntry(output: 7).state == "publishing" })
        XCTAssertTrue(waitUntil(2) { sink.sequences.count > before })
        XCTAssertEqual(sink.sequences[before], 0, "新连接从 0 编号")
    }

    /// 扩展经 CMIO 的"已输出"通知（CMIOExtensionStream.notifyScheduledOutputChanged → 本进程的 kCMIOStreamPropertyScheduledOutputNotificationProc）
    /// 回报每一帧；序号跳过的就是扩展丢的。走真的 C 回调入口（注册到 sink stream 上的就是它），不需要扩展。
    func testVirtualCamera_scheduledOutputNotificationsCountExtensionDrops() throws {
        let tracker = ScheduledOutputTracker()
        let proc = ScheduledOutputTracker.notificationProc
        let refCon = Unmanaged.passUnretained(tracker).toOpaque()
        tracker.beginConnection()
        for seq: UInt64 in [0, 1, 2, 5, 6] { proc(seq, 0, refCon) }
        XCTAssertEqual(tracker.report, SinkOutputReport(output: 5, dropped: 2), "3、4 没输出 = 扩展丢了")
        proc(6, 0, refCon)   // 重复 / 乱序：不算新的丢
        XCTAssertEqual(tracker.report.dropped, 2)
        // 新连接：序号从 0 重来，不和上一个连接比
        tracker.beginConnection()
        proc(0, 0, refCon)
        proc(3, 0, refCon)
        XCTAssertEqual(tracker.report, SinkOutputReport(output: 8, dropped: 4))
        // 第一条通知之前的序号也算（扩展起流时扔掉的开头几帧）
        tracker.beginConnection()
        proc(2, 0, refCon)
        XCTAssertEqual(tracker.report.dropped, 6)
        proc(0, 0, nil)   // 没有 refCon 的通知不崩
    }

    /// CMIO 序号挂在 CMSampleBuffer 上（CMIOSampleBuffer.h 不在 Swift 模块里，dlsym 取 C 函数；探针：附件键 com.apple.cmio.buffer_attachment.sequence_number）。
    func testVirtualCamera_sequenceNumberRoundTripsOnSampleBuffer() throws {
        let output = VirtualCameraOutput(format: .hd1080p60)
        let sb = try output.makeSampleBuffer(nv12Frame(pts: .now()), tickTime: .now())
        XCTAssertEqual(CMIOSequenceNumber.get(sb), CMIOSequenceNumber.invalid, "默认没有序号")
        CMIOSequenceNumber.set(sb, 41)
        XCTAssertEqual(CMIOSequenceNumber.get(sb), 41)
        CMIOSequenceNumber.set(sb, 42)
        XCTAssertEqual(CMIOSequenceNumber.get(sb), 42)
        XCTAssertTrue(CMIOSequenceNumber.usesCFunctions, "本机 CoreMediaIO 导出了 CMIOSampleBufferSet/GetSequenceNumber")
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

/// 假 sink：打开结果 / 排队结果 / 扩展回报都可控；记下每帧的 CMIO 序号。
final class FakeSink: VirtualCameraSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _openError: (any Error)?
    private var _acceptSends = true
    private var _isOpen = false
    private var _sequences: [UInt64] = []
    private var _closes = 0
    private var _report: SinkOutputReport?

    var openError: (any Error)? {
        get { lock.withLock { _openError } }
        set { lock.withLock { _openError = newValue } }
    }
    var acceptSends: Bool {
        get { lock.withLock { _acceptSends } }
        set { lock.withLock { _acceptSends = newValue } }
    }
    var report: SinkOutputReport? {
        get { lock.withLock { _report } }
        set { lock.withLock { _report = newValue } }
    }
    var sequences: [UInt64] { lock.withLock { _sequences } }
    var closes: Int { lock.withLock { _closes } }

    var isOpen: Bool { lock.withLock { _isOpen } }
    func open() throws {
        try lock.withLock {
            if let e = _openError { throw e }
            _isOpen = true
        }
    }
    func send(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard _isOpen, _acceptSends else { return false }
            _sequences.append(CMIOSequenceNumber.get(sampleBuffer))
            return true
        }
    }
    func close() {
        lock.withLock {
            _closes += 1
            _isOpen = false
        }
    }
    var extensionReport: SinkOutputReport? { report }
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
