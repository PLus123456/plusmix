// 虚拟摄像头（W3-C 交付 2）的主程序侧：帧 → CMSampleBuffer 不拷像素、PTS = 拍点；没有设备时消费者不阻塞、计数、每秒重试；
// 系统扩展安装器的状态映射与在未签名宿主里的失败路径。设备本身要签名的扩展才有（BLOCKED-签名）：QuickTime / FaceTime 里选到摄像头、
// L1 到虚拟摄像头出口的测量都在 App 级测试里 XCTSkip，解锁条件 = Team ID 签名 + /Applications。
import CoreMedia
import CoreMediaIO
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
        print("无设备：收 \(c.framesIn) 丢（无设备）\(c.droppedNoDevice) 丢（队列）\(c.droppedQueueFull) 送 \(c.framesSent) 找设备 \(c.connectAttempts) 次，push p99 \(String(format: "%.4f", p99)) ms，最近失败：\(c.lastFailure.map { "\($0)" } ?? "无")")
        XCTAssertEqual(c.framesIn, 60)
        XCTAssertEqual(c.framesSent, 0)
        XCTAssertEqual(c.droppedNoDevice + c.droppedQueueFull, 60, "没有设备全部丢掉并计数")
        XCTAssertGreaterThanOrEqual(c.connectAttempts, 3, "1 s 里按 200 ms 间隔重试了好几次")
        XCTAssertLessThanOrEqual(c.connectAttempts, 8, "重试有间隔，不是每帧都找")
        XCTAssertEqual(c.lastFailure, .open(.deviceNotFound), "W3-C3：失败原因是枚举（文字由组装方查表），不是包拼好的文案")
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
        XCTAssertEqual(output.countersSnapshot.lastFailure, .open(.startFailed(-1)))
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
    /// W3-C3：sink 排队之前先记下这一帧的序号（`noteSent`，CMIOSinkStreamClient.send 里做）；回报的序号不是本连接排过的
    /// （kCMIOInvalidSequenceNumber、比排过的都大、旧连接迟到的）只记 unmatched，不算输出也不算丢——桥没把我们的序号带过去时 Stats 不出乱数。
    func testVirtualCamera_scheduledOutputNotificationsCountExtensionDrops() throws {
        let tracker = ScheduledOutputTracker()
        let proc = ScheduledOutputTracker.notificationProc
        let refCon = Unmanaged.passUnretained(tracker).toOpaque()
        tracker.beginConnection()
        for seq: UInt64 in 0...6 { tracker.noteSent(sequence: seq) }
        for seq: UInt64 in [0, 1, 2, 5, 6] { proc(seq, 0, refCon) }
        XCTAssertEqual(tracker.report, SinkOutputReport(output: 5, dropped: 2), "3、4 没输出 = 扩展丢了")
        proc(6, 0, refCon)   // 重复 / 乱序：不算新的丢
        XCTAssertEqual(tracker.report.dropped, 2)
        // 新连接：序号从 0 重来，不和上一个连接比
        tracker.beginConnection()
        for seq: UInt64 in 0...3 { tracker.noteSent(sequence: seq) }
        proc(0, 0, refCon)
        proc(3, 0, refCon)
        XCTAssertEqual(tracker.report, SinkOutputReport(output: 8, dropped: 4))
        // 第一条通知之前的序号也算（扩展起流时扔掉的开头几帧）
        tracker.beginConnection()
        for seq: UInt64 in 0...2 { tracker.noteSent(sequence: seq) }
        proc(2, 0, refCon)
        XCTAssertEqual(tracker.report.dropped, 6)
        proc(0, 0, nil)   // 没有 refCon 的通知不崩
        // 不是本连接排过的序号：只记 unmatched
        proc(CMIOSequenceNumber.invalid, 0, refCon)   // kCMIOInvalidSequenceNumber（桥没带序号）
        proc(3, 0, refCon)                             // 本连接只排到 2
        XCTAssertEqual(tracker.report, SinkOutputReport(output: 9, dropped: 6, unmatched: 2))
        tracker.beginConnection()
        proc(1, 0, refCon)                             // 新连接还没排过帧：旧连接迟到的回报
        XCTAssertEqual(tracker.report, SinkOutputReport(output: 9, dropped: 6, unmatched: 3))
        tracker.noteSent(sequence: CMIOSequenceNumber.invalid)   // 没挂上序号的帧不抬高"排过的最大序号"
        proc(0, 0, refCon)
        XCTAssertEqual(tracker.report.unmatched, 4)
    }

    /// W3-C3 交付 2：扩展侧回报"已输出"的整条记账——`VirtualCameraOutput` 给每帧挂 CMIO 序号 → 假扩展（`FakeExtensionSink`，
    /// 与 CameraExtension 的 consumeNext 同一套：读样本上的序号、发出去之后回报、自己丢的帧不回报）经注册在 sink 上的
    /// 'sonp' C 回调（`ScheduledOutputTracker.notificationProc`，CMIO 把 notifyScheduledOutputChanged 转给主程序的那条路）回报
    /// → 序号跳号记成扩展丢的帧 → `countersSnapshot` 与 `Stats.display[]` 的 dropped。真扩展 BLOCKED-签名（Team ID + /Applications）。
    func testVirtualCamera_extensionReportsViaSonp_sequenceGapsBecomeDropped() throws {
        // 扩展每 10 帧丢 1 帧（序号 9、19、29……）
        let sink = FakeExtensionSink { ($0 + 1) % 10 == 0 }
        let output = VirtualCameraOutput(format: .hd1080p60, sink: sink)
        output.retryInterval = HostDuration(milliseconds: 20)
        output.start()
        defer { output.stop() }
        let frame = nv12Frame(pts: .now())
        var sent: UInt64 = 0
        func feed(_ n: Int) {
            for _ in 0..<n {
                let t = HostTime.now()
                output.consume(RenderedFrame(tick: Tick(Int64(sent)), tickTime: t, program: frame, submitTime: t, gpuStart: t, gpuEnd: t))
                sent += 1
                usleep(3_000)
            }
            XCTAssertTrue(waitUntil(2) {
                let c = output.countersSnapshot
                return c.framesSent + c.droppedNoDevice + c.droppedQueueFull + c.droppedSink == sent
            }, "\(output.countersSnapshot)")
        }

        // 1. 同步回报（在 send 里就回，记账当场可比）：61 帧 = 序号 0…60，扩展丢 9 / 19 / 29 / 39 / 49 / 59；59 的缺口由 60 的回报揭出来
        feed(61)
        var c = output.countersSnapshot
        XCTAssertEqual(c.framesSent, 61)
        XCTAssertEqual(sink.received, Array(0...60), "扩展按排进去的顺序收到每一帧的序号")
        XCTAssertTrue(c.extensionReports, "'sonp' 注册上了")
        XCTAssertEqual(c.framesOutput, 55)
        XCTAssertEqual(c.droppedExtension, 6)
        XCTAssertEqual(c.extensionUnmatched, 0)
        var e = output.statsEntry(output: 3)
        XCTAssertEqual(e.state, "publishing")
        XCTAssertEqual(e.frames, 61, "frames = 排进 sink 的帧（= 扩展收到的）")
        XCTAssertEqual(e.dropped, 6, "dropped = 扩展丢的（本端队列 / sink 都没丢）")
        XCTAssertEqual(e.undelivered, 0)

        // 2. 异步回报（扩展自己的队列上回，和真的一样）：再 40 帧（61…100，丢 69 / 79 / 89 / 99）；回报追上之后，下一次送帧时同步进计数
        sink.asynchronous = true
        feed(40)
        sink.drain()
        XCTAssertEqual(sink.extensionReport, SinkOutputReport(output: 91, dropped: 10), "101 帧里扩展丢了 10 帧")
        feed(1)   // 序号 101：送帧时读回报（它自己的回报可能还在路上）
        c = output.countersSnapshot
        XCTAssertEqual(c.droppedExtension, 10)
        XCTAssertTrue((91...92).contains(c.framesOutput), "\(c.framesOutput)：差的那一帧是最后一帧的回报还在路上")
        XCTAssertEqual(output.statsEntry(output: 3).dropped, 10)

        // 3. 断开重连：新连接序号从 0 重来、不和旧连接比；旧连接迟到的回报与没带序号的回报只记 unmatched，不进 dropped
        sink.drain()
        sink.asynchronous = false
        sink.dropSequences = { _ in false }
        sink.close()   // 流没了（真机上是扩展停了 / 被卸载，VirtualCameraOutput 连续排不进后自己关；这里直接关掉看重连）
        let receivedBefore = sink.received.count
        feed(1)        // 发现没连着 → 重连，这一帧是新连接的 0 号
        XCTAssertTrue(waitUntil(2) { output.state == .connected })
        XCTAssertEqual(sink.received.dropFirst(receivedBefore).first, 0, "新连接从 0 编号")
        sink.lateNotification(sequence: 100)   // 旧连接迟到的回报（新连接只排到 0）
        feed(10)
        sink.lateNotification(sequence: CMIOSequenceNumber.invalid)
        feed(1)
        c = output.countersSnapshot
        XCTAssertEqual(c.droppedExtension, 10, "新连接没丢；跨连接的序号不比；迟到 / 无效的回报不算丢")
        XCTAssertEqual(c.extensionUnmatched, 2)
        e = output.statsEntry(output: 3)
        XCTAssertEqual(e.dropped, c.droppedQueueFull &+ c.droppedSink &+ c.droppedExtension, "Stats 的 dropped 与 countersSnapshot 同源（铁律 4）")
        XCTAssertEqual(e.dropped, 10)
        print("扩展回报（假扩展）：送 \(c.framesSent) 输出 \(c.framesOutput) 扩展丢 \(c.droppedExtension) 对不上 \(c.extensionUnmatched)，Stats dropped \(e.dropped) undelivered \(e.undelivered)")
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

    /// 请求结果 / 错误 → 状态。W3-C3：失败只给枚举原因（按 OSSystemExtensionError 的码归类）+ 系统给的诊断（域 / 码 / 系统本地化的描述），
    /// 文字由组装方按原因查表（App 的 OutputStatusText）；包里不再拼中文文案，`describe` / `developerModeHint` 删了（没人调，提示挪进注释与 README）。
    func testInstaller_statusMapping() throws {
        XCTAssertEqual(SystemExtensionInstaller.status(for: .completed, version: "0.1.0"), .installed(version: "0.1.0"))
        XCTAssertEqual(SystemExtensionInstaller.status(for: .willCompleteAfterReboot, version: "0.1.0"), .needsReboot)
        func failure(_ code: OSSystemExtensionError.Code, description: String? = nil) -> SystemExtensionInstaller.Failure? {
            let error = NSError(domain: OSSystemExtensionErrorDomain, code: code.rawValue,
                                userInfo: description.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
            guard case .failed(let f) = SystemExtensionInstaller.status(for: error) else { return nil }
            return f
        }
        let notFound = try XCTUnwrap(failure(.extensionNotFound, description: "Extension not found"))
        XCTAssertEqual(notFound, SystemExtensionInstaller.Failure(reason: .extensionNotFound, domain: OSSystemExtensionErrorDomain,
                                                                  code: OSSystemExtensionError.Code.extensionNotFound.rawValue, detail: "Extension not found"))
        XCTAssertTrue(notFound.isSigningBlocked, "App 里没有扩展 = 没带 Team ID 签名嵌进去：BLOCKED-签名")
        // 签名 / 权限 / 位置 / 系统策略：一类（探针 2：未签名的命令行宿主回的是 missingEntitlement）
        for code: OSSystemExtensionError.Code in [.codeSignatureInvalid, .validationFailed, .missingEntitlement, .unsupportedParentBundleLocation, .forbiddenBySystemPolicy] {
            let f = try XCTUnwrap(failure(code), "\(code.rawValue)")
            XCTAssertEqual(f.reason, .requirementsNotMet, "\(code.rawValue)")
            XCTAssertTrue(f.isSigningBlocked)
            XCTAssertEqual(f.code, code.rawValue)
        }
        XCTAssertEqual(failure(.requestCanceled)?.reason, .canceled)
        XCTAssertEqual(failure(.requestSuperseded)?.reason, .superseded)
        XCTAssertEqual(failure(.requestCanceled)?.isSigningBlocked, false)
        XCTAssertEqual(SystemExtensionInstaller.status(for: NSError(domain: OSSystemExtensionErrorDomain, code: OSSystemExtensionError.Code.authorizationRequired.rawValue, userInfo: [:])),
                       .needsUserApproval)
        // 扩展包本身有问题（缺标识 / 重复 / 类别不认识）与未知码：other，带着码给日志
        for code: OSSystemExtensionError.Code in [.unknown, .extensionMissingIdentifier, .duplicateExtensionIdentifer, .unknownExtensionCategory] {
            XCTAssertEqual(failure(code)?.reason, .other, "\(code.rawValue)")
        }
        // 别的域：other，域 / 码 / 系统描述原样带着
        let foreign = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统给的描述"])
        XCTAssertEqual(SystemExtensionInstaller.status(for: foreign), .failed(.init(reason: .other, domain: "x", code: 1, detail: "系统给的描述")))
        XCTAssertEqual(Set(SystemExtensionInstaller.Failure.Reason.allCases), [.extensionNotFound, .requirementsNotMet, .canceled, .superseded, .other],
                       "组装方的查表要覆盖全部原因")
    }

    /// 在没有扩展 / 未签名的宿主里发激活请求：不崩，几秒内回到 failed，原因是签名那一类（BLOCKED-签名）。真正的激活 BLOCKED-签名。
    @MainActor
    func testInstaller_activateInUnsignedHost_failsWithSigningReason() throws {
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
        print("未签名宿主里的激活请求：\(statuses)")
        switch installer.status {
        case .failed(let failure):
            XCTAssertTrue(failure.isSigningBlocked, "未签名宿主应是签名那一类：\(failure)")
            XCTAssertEqual(failure.domain, OSSystemExtensionErrorDomain)
            XCTAssertFalse(failure.detail.isEmpty, "系统给的描述带着（给日志 / 附在查表文案后面）")
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

/// 假扩展（W3-C3）：像 CameraExtension 的 consumeNext 那样处理 sink 收到的每一帧——读样本上的 CMIO 序号，发出去之后回报"已输出"，
/// 自己丢的帧不回报；回报走注册在 sink 上的 'sonp' C 回调（refCon = 记账对象），就是 CMIO 把扩展的 notifyScheduledOutputChanged
/// 转给主程序的那条路。注册 / 注销 / 排队前记序号（noteSent）与 CMIOSinkStreamClient 同一套步骤。
/// 回报默认同步（在 send 里就回，测试好比数）；`asynchronous` = 在自己的串行队列上回，和真扩展一样。
final class FakeExtensionSink: VirtualCameraSink, @unchecked Sendable {
    /// 注册在 sink stream 上的 'sonp'（C 回调 + refCon），与 CMIOStreamScheduledOutputNotificationProcAndRefCon 对应。
    private struct Registration: @unchecked Sendable {
        let proc: CMIOStreamScheduledOutputNotificationProc
        let refCon: UnsafeMutableRawPointer
    }
    private let lock = NSLock()
    private let tracker = ScheduledOutputTracker()
    private let extensionQueue = DispatchQueue(label: "fake.camera-extension")
    private var registration: Registration?
    private var _dropSequences: @Sendable (UInt64) -> Bool
    private var _asynchronous = false
    private var _received: [UInt64] = []

    init(dropSequences: @escaping @Sendable (UInt64) -> Bool) {
        _dropSequences = dropSequences
    }

    /// 扩展要丢哪些帧（按序号；丢 = 收了不发出去、不回报）。
    var dropSequences: @Sendable (UInt64) -> Bool {
        get { lock.withLock { _dropSequences } }
        set { lock.withLock { _dropSequences = newValue } }
    }
    var asynchronous: Bool {
        get { lock.withLock { _asynchronous } }
        set { lock.withLock { _asynchronous = newValue } }
    }
    /// 扩展收到的序号（按收到的顺序）。
    var received: [UInt64] { lock.withLock { _received } }

    var isOpen: Bool { lock.withLock { registration != nil } }

    func open() throws {
        lock.withLock {
            tracker.beginConnection()
            registration = Registration(proc: ScheduledOutputTracker.notificationProc, refCon: Unmanaged.passUnretained(tracker).toOpaque())
        }
    }

    func send(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let sequence = CMIOSequenceNumber.get(sampleBuffer)
        guard let snapshot = lock.withLock({ registration.map { ($0, _dropSequences, _asynchronous) } }) else { return false }
        let (registration, drop, deliverLater) = snapshot
        tracker.noteSent(sequence: sequence)   // 排队之前（扩展可能在排队返回之前就回报）
        let consume: @Sendable () -> Void = { [self] in
            lock.withLock { _received.append(sequence) }
            guard !drop(sequence) else { return }
            registration.proc(sequence, mach_absolute_time(), registration.refCon)   // = notifyScheduledOutputChanged 经 CMIO 到这里
        }
        if deliverLater { extensionQueue.async(execute: consume) } else { consume() }
        return true
    }

    func close() {
        lock.withLock { registration = nil }
    }

    var extensionReport: SinkOutputReport? { tracker.report }

    /// 等扩展队列上的回报都回完。
    func drain() { extensionQueue.sync {} }

    /// 注销之后 / 新连接开始之后才到的回报（CMIO 线程上在路上的那一条）：直接调同一个 C 回调。
    func lateNotification(sequence: UInt64) {
        ScheduledOutputTracker.notificationProc(sequence, mach_absolute_time(), Unmanaged.passUnretained(tracker).toOpaque())
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
