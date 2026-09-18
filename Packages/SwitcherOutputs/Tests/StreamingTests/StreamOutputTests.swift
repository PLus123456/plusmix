import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// StreamOutput 的状态机 / 队列 / 计数，用可控传输层和可控编码后端证明；真网络在 MediaMTXTests。
final class StreamOutputTests: XCTestCase {
    /// 按拍点实时喂 seconds 秒的视频（+ 同源音频）给所有输出；返回喂了多少帧和每次 consume 的耗时。
    private func feed(outputs: [StreamOutput], seconds: Double, audio: Bool = true, t0: HostTime = HostClock.now() + HostDuration(milliseconds: 200))
        throws -> (frames: Int, pushMs: [Double]) {
        let source = try FrameSource(t0: t0)
        let audioSource = AudioSource(t0: t0)
        let ticks = Int(seconds * 60)
        var pushMs: [Double] = []
        pushMs.reserveCapacity(ticks * outputs.count)
        for tick in 0..<ticks {
            let tickTime = source.clock.time(of: Tick(Int64(tick)))
            mach_wait_until(tickTime.ticks)
            let frame = try source.frame(tick: tick)
            for o in outputs {
                let t = HostClock.now()
                o.consume(frame)
                pushMs.append((HostClock.now() - t).milliseconds)
            }
            if audio { audioSource.feed(upTo: tickTime, to: outputs) }
        }
        return (ticks, pushMs)
    }

    /// E7（逻辑版）：三路同帧，第 2 路的传输层完全停滞（不排空、不断开），第 1、3 路一帧不丢；consume 从不阻塞。
    func testE7_stalledTransportDoesNotAffectSiblings() throws {
        let healthy = FakeTransportFactory(behavior: .init())
        let stalled = FakeTransportFactory(behavior: .init(stalled: true))
        let outputs = try [
            StreamOutput.makeForTest(name: "s1", factory: healthy),
            StreamOutput.makeForTest(name: "s2", factory: stalled, queue: .init(videoFrames: 30, maxInFlightBytes: 400_000, stallSeconds: 0.5,
                                                                                drainSeconds: 0.2, lingerSeconds: 0, pollIntervalMs: 20)),
            StreamOutput.makeForTest(name: "s3", factory: healthy),
        ]
        for o in outputs { try o.start() }
        XCTAssertTrue(waitUntil(timeout: 2) { outputs.allSatisfy { $0.state == .publishing } }, "都该连上：\(outputs.map(\.state))")
        let fed = try feed(outputs: outputs, seconds: 4)
        for o in outputs { o.stop() }
        let c = outputs.map(\.counters)
        XCTAssertEqual(fed.frames, 240)
        for i in [0, 2] {
            XCTAssertEqual(c[i].framesReceived, 240, "第 \(i + 1) 路收到全部帧")
            XCTAssertEqual(c[i].networkDropped, 0, "第 \(i + 1) 路网络丢帧必须为 0（E7 硬性）：\(c[i])")
            XCTAssertEqual(c[i].framesSent, 240)
            XCTAssertEqual(c[i].disconnects, 0)
        }
        // 第 2 路：门关上后队列满 → 丢帧；停滞 0.5 s → 判断线 → 重连（新对象仍停滞）……丢帧数 = 收到 − 送出
        XCTAssertGreaterThan(c[1].networkDropped, 0)
        XCTAssertGreaterThan(c[1].disconnects, 0)
        XCTAssertEqual(c[1].framesReceived, c[1].framesSent + c[1].networkDropped - c[1].lostInTransport, "恒等式：收到 = 交出 + 没交出的：\(c[1])")
        XCTAssertEqual(c[1].lostInTransport, c[1].framesSent, "停滞的传输层：交出去的一帧也没发出去，估算项应等于交出数：\(c[1])")
        XCTAssertGreaterThanOrEqual(stalled.transports.count, 2, "停滞后应当重连过")
        let sorted = fed.pushMs.sorted()
        let p99 = sorted[Int(Double(sorted.count) * 0.99)]
        XCTAssertLessThan(p99, 0.1, "consume p99 \(p99) ms 必须 < 0.1 ms（三路都不阻塞派发线程）")
    }

    /// E8（逻辑版）：发 60 帧后传输层断开 → 退避 0.1 s 重连失败 → 退避 0.2 s 重连成功；重连后第一帧是关键帧、重连计数 1、断线期间的帧记为网络丢帧。
    func testE8_reconnectWithBackoffAndKeyframeFirst() throws {
        let factory = FakeTransportFactory { attempt in
            switch attempt {
            case 1: return .init(disconnectAfterVideoFrames: 60)
            case 2: return .init(connectFails: true)
            default: return .init()
            }
        }
        let o = try StreamOutput.makeForTest(name: "e8", factory: factory)
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 2) { o.state == .publishing })
        let fed = try feed(outputs: [o], seconds: 3)
        XCTAssertEqual(fed.frames, 180)
        o.stop()
        let c = o.counters
        let ts = factory.transports
        XCTAssertEqual(ts.count, 3, "三次连接：成功、失败、成功")
        XCTAssertEqual(c.connectAttempts, 3)
        XCTAssertEqual(c.reconnects, 1)
        XCTAssertEqual(c.disconnects, 1)
        XCTAssertEqual(ts[0].sentVideo.count, 60)
        XCTAssertTrue(ts[2].sentVideo.first?.isKeyframe ?? false, "重连后第一帧必须是关键帧")
        XCTAssertGreaterThan(ts[2].sentVideo.count, 60)
        XCTAssertEqual(c.framesReceived, c.framesSent + c.networkDropped - c.lostInTransport, "\(c)")
        XCTAssertGreaterThan(c.droppedDisconnected + c.droppedWaitingKeyframe, 0, "断线到重连之间的帧记为网络丢帧")
        // 退避：0.1 + 失败 + 0.2 ≈ 0.3 s 之后重连成功，且 ≤ 1 s
        XCTAssertGreaterThan(c.lastReconnectSeconds, 0.25, "\(c.lastReconnectSeconds)")
        XCTAssertLessThan(c.lastReconnectSeconds, 1.0)
        XCTAssertTrue(ts.allSatisfy(\.isClosed), "每个传输层对象都被关掉")
        XCTAssertEqual(o.state, .stopped)
    }

    /// 超过最大尝试次数 → failed。
    func testReconnectGivesUpAfterMaxAttempts() throws {
        let factory = FakeTransportFactory(behavior: .init(connectFails: true))
        let o = try StreamOutput.makeForTest(name: "giveup", factory: factory,
                                             reconnect: ReconnectPolicy(initialSeconds: 0.05, multiplier: 2, maxSeconds: 0.1, maxAttempts: 3))
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 3) { if case .failed = o.state { return true } else { return false } }, "\(o.state)")
        XCTAssertEqual(o.counters.connectAttempts, 3)
        o.stop()
    }

    /// E9（逻辑版）：传输层只排空 70% 的码率，5 秒；网络丢帧 = 收到 − 送出（精确），送出的帧序列每个缺口之后都从关键帧起。
    func testE9_throttledTransport_dropAccountingExact() throws {
        let backend = FakeVideoBackend(frameBytes: 12_500, keyframeInterval: 30)   // 6 Mbps @ 60 fps；关键帧 0.5 s 一个
        let rate = Int(Double(12_500 * 60) * 0.7)
        let factory = FakeTransportFactory(behavior: .init(drainBytesPerSecond: rate))
        let o = try StreamOutput.makeForTest(name: "e9", factory: factory, audio: false,
                                             queue: .init(videoFrames: 15, maxInFlightBytes: 200_000, stallSeconds: 5, drainSeconds: 3, lingerSeconds: 0, pollIntervalMs: 20),
                                             backend: backend)
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 2) { o.state == .publishing })
        let fed = try feed(outputs: [o], seconds: 5, audio: false)
        o.stop()
        let c = o.counters
        let t = factory.transports[0]
        let sent = t.sentVideo
        XCTAssertEqual(c.framesReceived, UInt64(fed.frames))
        XCTAssertEqual(c.framesSent, UInt64(sent.count))
        XCTAssertEqual(c.framesReceived, c.framesSent + c.networkDropped, "收到 = 送出 + 网络丢帧：\(c)")
        XCTAssertEqual(c.lostInTransport, 0, "没断线就没有估算项")
        XCTAssertGreaterThan(c.networkDropped, 30, "70% 带宽 5 秒至少丢几十帧：\(c)")
        XCTAssertLessThan(Double(c.framesSent) / Double(fed.frames), 0.9, "送出比例应明显低于 1：\(c)")
        // 可解码性：送出序列里任何 tick 缺口之后的第一帧必须是关键帧
        for i in 1..<sent.count where sent[i].tick - sent[i - 1].tick > 1 {
            XCTAssertTrue(sent[i].isKeyframe, "tick \(sent[i - 1].tick) → \(sent[i].tick) 有缺口，后一帧必须是关键帧")
        }
        XCTAssertEqual(c.disconnects, 0, "慢但在走的连接不能被当成停滞：\(o.lastExitReasonDescription)")
    }

    /// 起步对齐（RTMP 的 dtsOffset 模式）：视频关键帧的 dtsOffset = 关键帧时刻 − 音频原点包时刻（≥ 0，< 一个包）；原点之前的包不送。
    func testStartAlignment_dtsOffset() throws {
        let factory = FakeTransportFactory(behavior: .init(alignment: .dtsOffset))
        let o = try StreamOutput.makeForTest(name: "align", factory: factory)
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 2) { o.state == .publishing })
        // 先喂 0.5 s 音频（原点之前有一堆包），再从 t0 + 0.5 s 起喂视频
        let t0 = HostClock.now() + HostDuration(milliseconds: 100)
        let audio = AudioSource(t0: t0)
        let videoStart = t0 + HostDuration(milliseconds: 500)
        mach_wait_until(videoStart.ticks)
        audio.feed(upTo: videoStart, to: [o])
        let source = try FrameSource(t0: videoStart)
        for tick in 0..<30 {
            let tt = source.clock.time(of: Tick(Int64(tick)))
            mach_wait_until(tt.ticks)
            o.consume(try source.frame(tick: tick))
            audio.feed(upTo: tt + HostDuration(milliseconds: 50), to: [o])
        }
        XCTAssertTrue(waitUntil(timeout: 2) { factory.transports.first?.sentVideo.count ?? 0 >= 30 })
        o.stop()
        let t = factory.transports[0]
        let v = t.sentVideo
        let a = t.sentAudioTimes
        XCTAssertEqual(v.first?.tick, Tick(0))
        XCTAssertTrue(v.first?.isKeyframe ?? false)
        let packetDuration = HostDuration(nanoseconds: 1024 * 1_000_000_000 / 48000)
        let offset = v[0].dtsOffset
        XCTAssertGreaterThanOrEqual(offset.ticks, 0)
        XCTAssertLessThan(offset.ticks, packetDuration.ticks, "偏移不到一个包：\(offset.milliseconds) ms")
        XCTAssertTrue(v.allSatisfy { $0.dtsOffset == offset }, "整段会话偏移不变")
        // 音频原点 = 关键帧时刻 − 偏移；之前的包都没送
        XCTAssertEqual(a.first, v[0].tickTime - offset)
        XCTAssertGreaterThan(o.counters.audioDropped, 0, "原点之前的包被丢")
        for i in 1..<a.count { XCTAssertEqual((a[i] - a[i - 1]).ticks, packetDuration.ticks, accuracy: 2, "包间隔连续") }
    }

    /// 起步对齐（TS 的 nearest 模式）：送 1 个 preroll 包，原点是离关键帧最近的包，dtsOffset 恒为 0。
    func testStartAlignment_nearestPacketWithPreroll() throws {
        let factory = FakeTransportFactory(behavior: .init(alignment: .nearestPacket(prerollPackets: 1)))
        let o = try StreamOutput.makeForTest(name: "align-ts", factory: factory)
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 2) { o.state == .publishing })
        let t0 = HostClock.now() + HostDuration(milliseconds: 100)
        let audio = AudioSource(t0: t0)
        let videoStart = t0 + HostDuration(milliseconds: 500)
        mach_wait_until(videoStart.ticks)
        audio.feed(upTo: videoStart, to: [o])
        let source = try FrameSource(t0: videoStart)
        for tick in 0..<30 {
            let tt = source.clock.time(of: Tick(Int64(tick)))
            mach_wait_until(tt.ticks)
            o.consume(try source.frame(tick: tick))
            audio.feed(upTo: tt + HostDuration(milliseconds: 50), to: [o])
        }
        XCTAssertTrue(waitUntil(timeout: 2) { factory.transports.first?.sentVideo.count ?? 0 >= 30 })
        o.stop()
        let t = factory.transports[0]
        let v = t.sentVideo
        let a = t.sentAudioTimes
        XCTAssertTrue(v.allSatisfy { $0.dtsOffset == .zero })
        let half = HostDuration(nanoseconds: 1024 * 1_000_000_000 / 48000 / 2)
        XCTAssertGreaterThanOrEqual(a.count, 2)
        // a[0] 是 preroll，a[1] 是原点：离关键帧时刻不超过半个包
        let d = (a[1] - v[0].tickTime).magnitude
        XCTAssertLessThanOrEqual(d.ticks, half.ticks + 1000, "原点离关键帧 \(d.milliseconds) ms")
    }

    /// 停止时排空：停之前喂的帧全部送出（传输层无限快）。
    func testStopDrainsQueue() throws {
        let factory = FakeTransportFactory(behavior: .init())
        let o = try StreamOutput.makeForTest(name: "drain", factory: factory, audio: false)
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 2) { o.state == .publishing })
        let source = try FrameSource(t0: HostClock.now())
        for tick in 0..<20 { o.consume(try source.frame(tick: tick)) }   // 不等拍点，编码器队列深 3 会丢一些（E1），但收到的都要送出
        o.stop()
        let c = o.counters
        XCTAssertEqual(c.framesSent, c.framesReceived, "\(c)")
        XCTAssertEqual(c.networkDropped, 0)
        XCTAssertEqual(o.state, .stopped)
        XCTAssertEqual(factory.transports.count, 1)
        XCTAssertTrue(factory.transports[0].isClosed)
    }

    /// start / stop 幂等；stop 后 consume 不计数。
    func testLifecycle() throws {
        let factory = FakeTransportFactory(behavior: .init())
        let o = try StreamOutput.makeForTest(name: "life", factory: factory, audio: false)
        XCTAssertEqual(o.state, .idle)
        try o.start()
        XCTAssertThrowsError(try o.start())
        o.stop()
        o.stop()
        let source = try FrameSource(t0: HostClock.now())
        o.consume(try source.frame(tick: 0))
        XCTAssertEqual(o.counters.framesReceived, 0)
        XCTAssertEqual(o.state, .stopped)
    }
}
