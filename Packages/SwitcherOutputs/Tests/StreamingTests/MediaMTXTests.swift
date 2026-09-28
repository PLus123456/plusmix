import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// 真编码器 + HaishinKit + 本地 MediaMTX（scripts/mediamtx.yml）。落盘文件交 ffprobe / frameprobe。
/// netem 的 sudo 部分见 Netem（SWITCHER_NETEM=sudo | broker），没设就 XCTSkip。
/// 端口：测试自己起实例，用 21935+ / 28890+ / 29997+，不碰用户手动起的 1935。
final class MediaMTXTests: XCTestCase {
    private var instances: [MediaMTXInstance] = []
    private var outputs: [StreamOutput] = []
    private var impairments: [Impairment] = []
    private var proxies: [ThrottleProxy] = []

    override func setUpWithError() throws {
        try MediaMTXInstance.requireAvailable()
        try FFprobe.requireAvailable()
    }

    override func tearDown() {
        for o in outputs where o.isRunning { o.stop() }
        outputs = []
        for i in impairments { i.stop() }
        impairments = []
        for p in proxies { p.stop() }
        proxies = []
        for i in instances { i.stop() }
        instances = []
    }

    private func startInstances(_ n: Int, test: String) throws -> [MediaMTXInstance] {
        let dir = StreamTestPaths.root.appendingPathComponent(test)
        try? FileManager.default.removeItem(at: dir)
        var list: [MediaMTXInstance] = []
        for i in 0..<n {
            list.append(try MediaMTXInstance(rtmpPort: 21935 + i, srtPort: 28890 + i, apiPort: 29997 + i, recordDir: dir.appendingPathComponent("mtx\(i + 1)")))
        }
        instances = list
        print("MediaMTX ×\(n)，录制目录 \(dir.path)")
        return list
    }

    /// 并行停（像引擎那样各路独立）；串行停会让后停的那路空闲超过 MediaMTX 的 10 s 读超时而被它踢掉。
    private func stopAll(_ outputs: [StreamOutput]) {
        let group = DispatchGroup()
        for o in outputs {
            group.enter()
            Thread { o.stop(); group.leave() }.start()
        }
        group.wait()
    }

    private func waitPublishing(_ o: StreamOutput, timeout: Double = 10) -> Bool {
        waitUntil(timeout: timeout) { o.state == .publishing }
    }

    // MARK: 端到端

    /// RTMP：10 s，落盘 599 帧（MediaMTX 录制器丢最后一帧，见报告）、帧号 0…598 连续、无重复；
    /// A/V（ffmpeg 口径，见 AVOffsetFFmpeg）偏移 ≤ 2 ms（A2 目标档 5 ms）。frameprobe av 的数字只打印：它不补音轨起始偏移、
    /// 且 AVFoundation 解码时按 2112 样本裁 priming，对没有 priming 信息的 MediaMTX fMP4 会多报 44 ms + 起始偏移（报告 §1.4，给 W1-A 的单子）。
    func testRTMP_endToEnd_10s_framesContinuousAndAVAligned() throws {
        let mtx = try startInstances(1, test: "rtmp-e2e")[0]
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "rtmp-e2e", url: mtx.rtmpURL("s1"))
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitPublishing(o), "\(o.state)")
        let report = try scene.feed(outputs: [o], ticks: 0..<600)
        o.stop()
        let c = o.counters
        print("RTMP e2e：\(c)")
        XCTAssertEqual(report.framesFed, 600)
        XCTAssertEqual(c.framesReceived, 600)
        XCTAssertEqual(c.networkDropped, 0)
        XCTAssertEqual(c.framesSent, 600)
        XCTAssertEqual(o.videoEncoder.counters.skipped, 0)
        let files = mtx.recordings("s1")
        XCTAssertEqual(files.count, 1, "\(files)")
        guard let file = files.first else { return }
        let st = try Frameprobe.stats(file)
        print("frameprobe stats：\(st)")
        XCTAssertGreaterThanOrEqual(st.totalFrames, 599, "落盘帧数（MediaMTX 丢最后一帧）")
        XCTAssertEqual(st.dropGaps, 0)
        XCTAssertEqual(st.duplicateFrames, 0)
        XCTAssertEqual(st.undecodable, 0)
        let av = try AVOffsetFFmpeg.measure(file)
        print("A/V（ffmpeg 口径）：mean \(av.meanMs) ms，max |\(av.maxAbsMs)| ms，\(av.pairs.count) 对")
        if let fp = try? Frameprobe.av(file) { print("frameprobe av（AVFoundation 口径，含 priming 偏置）：\(fp)") }
        XCTAssertGreaterThanOrEqual(av.pairs.count, 8)
        XCTAssertLessThanOrEqual(av.maxAbsMs, 2.0, "A/V 偏移 ≤ 2 ms（A2 目标档 5 ms）")
        // 落盘的视频 PTS 连续（MediaMTX 自己重算 DTS = PTS，CTS 被吸收进 PTS）
        let pk = try FFprobe.packets(file)
        XCTAssertGreaterThanOrEqual(pk.count, 599)
        XCTAssertTrue(pk.allSatisfy { $0.dtsTime == nil || abs($0.ptsTime - $0.dtsTime!) < 0.001 })
    }

    /// SRT：同上（帧号连续）；A/V 用最近包对齐（≤ 10.7 ms）。MediaMTX 的 SRT 要绑 IPv4（MediaMTXInstance 已处理）；连不上时打印防火墙状态后 XCTSkip。
    func testSRT_endToEnd_10s_framesContinuous() throws {
        let mtx = try startInstances(1, test: "srt-e2e")[0]
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "srt-e2e", url: mtx.srtURL("srt1"), connectTimeout: 4)
        outputs = [o]
        try o.start()
        guard waitPublishing(o, timeout: 6) else {
            o.stop()
            let fw = (try? Proc.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).stdout).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if fw.contains("enabled") {
                throw XCTSkip("BLOCKED-防火墙：SRT 连不上（\(o.state)）且应用防火墙开着；先确认 mediamtx 在放行名单里（socketfilterfw --listapps），再看 mediamtx 日志里 SRT 有没有 conn opened")
            }
            XCTFail("SRT 没连上：\(o.state)")
            return
        }
        let report = try scene.feed(outputs: [o], ticks: 0..<600)
        o.stop()
        let c = o.counters
        print("SRT e2e：\(c)")
        XCTAssertEqual(report.framesFed, 600)
        XCTAssertEqual(c.networkDropped, 0)
        let files = mtx.recordings("srt1")
        XCTAssertEqual(files.count, 1, "\(files)")
        guard let file = files.first else { return }
        let st = try Frameprobe.stats(file)
        print("frameprobe stats：\(st)")
        XCTAssertGreaterThanOrEqual(st.totalFrames, 599)
        XCTAssertEqual(st.dropGaps, 0)
        XCTAssertEqual(st.undecodable, 0)
        let av = try AVOffsetFFmpeg.measure(file)
        print("A/V（ffmpeg 口径）：mean \(av.meanMs) ms，max |\(av.maxAbsMs)| ms")
        XCTAssertLessThanOrEqual(av.maxAbsMs, 10.7 + 2, "最近包对齐：≤ 半个 AAC 包 10.7 ms")
    }

    // MARK: W2-D2 推流开始：握手期间 / 第一帧之前的音频

    /// W2-D2（RTMP，App 的顺序：引擎在跑、用户此刻按下"开始"）：start() 之后立刻按拍喂音视频、不等 publishing；上行限速让 RTMP 握手在
    /// 约 0.5 s（tick ≈ 30）才完成。要求：握手期间到的音视频排队、连上后从第 0 拍（关键帧）起送——网络丢帧 0、音频丢包 0、落盘从帧号 0 起、
    /// 两轨起点相差不到一个 AAC 包、第 0 拍的闪光就有 click 配对（A/V ≤ 2 ms）。修前：握手期间的帧 / 包直接丢（droppedDisconnected / audioDropped）。
    func testW2D2_streamStart_noAudioDroppedBeforeFirstVideo() throws {
        let mtx = try startInstances(1, test: "w2d2-rtmp")[0]
        let proxy = try ThrottleProxy(listenPort: 31960, targetPort: mtx.rtmpPort)
        proxies = [proxy]
        // 上行 3 KB/s：C0+C1（1537 B）在代理里要等 ≈ 0.5 s 才放过去；之后（tick 24 解除限速）握手其余往返和连上后的突发不受限
        proxy.rateBytesPerSecond = 3000
        let scene = try StreamScene(leadMs: 60)
        let o = try scene.makeOutput(name: "w2d2-rtmp", url: "rtmp://127.0.0.1:\(proxy.listenPort)/s1")
        outputs = [o]
        let startedAt = HostClock.now()
        try o.start()
        var publishingAtTick: Int?
        let report = try scene.feed(outputs: [o], ticks: 0..<600) { tick, _ in
            if tick == 24 { proxy.rateBytesPerSecond = nil }
            if publishingAtTick == nil, o.state == .publishing { publishingAtTick = tick }
        }
        o.stop()
        let c = o.counters
        print("W2-D2 RTMP：t0 距 start() \(String(format: "%.0f", (scene.clock.time(of: Tick(0)) - startedAt).milliseconds)) ms，连上时 tick \(publishingAtTick.map(String.init) ?? "没连上")；\(c)")
        XCTAssertEqual(report.framesFed, 600)
        guard let publishingAtTick else { return XCTFail("10 s 内没连上：\(o.state)") }
        XCTAssertTrue((6...58).contains(publishingAtTick), "握手应在喂帧开始之后、缓冲（1 s）满之前完成：tick \(publishingAtTick)")
        XCTAssertEqual(c.framesReceived, 600)
        XCTAssertEqual(c.framesSent, 600, "握手期间的帧也要送出：\(c)")
        XCTAssertEqual(c.networkDropped, 0, "握手期间到的帧不算网络丢帧：\(c)")
        XCTAssertEqual(c.audioDropped, 0, "握手期间到的音频包不算丢：\(c)")
        XCTAssertEqual(c.audioPacketsSent, c.audioPacketsReceived, "握手期间的音频包也要送出：\(c)")
        XCTAssertEqual(o.videoEncoder.counters.skipped, 0)
        let files = mtx.recordings("s1")
        XCTAssertEqual(files.count, 1, "\(files)")
        guard let file = files.first else { return }
        let st = try Frameprobe.stats(file)
        print("frameprobe stats：\(st)")
        XCTAssertGreaterThanOrEqual(st.totalFrames, 599, "落盘帧数（MediaMTX 丢最后一帧）")
        XCTAssertEqual(st.dropGaps, 0)
        XCTAssertEqual(st.duplicateFrames, 0)
        XCTAssertEqual(st.undecodable, 0)
        let frames = try Frameprobe.frames(file, limit: 5)
        XCTAssertEqual(frames.first?.frameNumber, 0, "落盘从按下开始那一拍（帧号 0）起：\(frames)")
        let starts = try FFprobe.streamStartTimes(file)
        print("落盘两轨起点：视频 \(starts.video) s，音频 \(starts.audio) s")
        XCTAssertLessThanOrEqual(abs(starts.video - starts.audio), 1024.0 / 48000 + 0.001, "两轨从同一时刻起（差不到一个 AAC 包）")
        let av = try AVOffsetFFmpeg.measure(file)
        print("A/V（ffmpeg 口径）：mean \(av.meanMs) ms，max |\(av.maxAbsMs)| ms，\(av.pairs.count) 对；第一对 \(av.pairs.first.map { "闪光 \($0.flash) s click \($0.click) s" } ?? "无")")
        // 第一秒有音频：[0.1, 1.0) s 的 RMS 是那个 −20 dBFS 的正弦（≈ 0.071）；第 0 拍的 click 落在 AAC 解码器前 44 ms 的热身里（原点包之前的两个包不送），
        // 第一个能配对的闪光是第 60 拍（1.0 s）——文件从第 0 拍起，它就在 1.0 s；修前文件从第 29 拍起，它在 0.516 s
        print("第一秒音频 RMS \(String(format: "%.3f", av.rmsFirstSecond))")
        XCTAssertGreaterThan(av.rmsFirstSecond, 0.05, "落盘文件第一秒要有音频（正弦 RMS ≈ 0.071）")
        XCTAssertGreaterThanOrEqual(av.pairs.count, 9)
        guard let first = av.pairs.first else { return }
        XCTAssertEqual(first.flash, 1.0, accuracy: 0.02, "文件从第 0 拍起：第一个能配对的闪光（第 60 拍）在 1.0 s")
        XCTAssertLessThanOrEqual(abs(first.flash - first.click) * 1000, 2.0, "第一秒末的 click 与画面对齐")
        XCTAssertLessThanOrEqual(av.maxAbsMs, 2.0, "A/V 偏移 ≤ 2 ms（A2 目标档 5 ms）")
    }

    /// W2-D2（SRT，headless 的顺序：音频引擎先起、视频到 t0 才来）：start() 之后音频先喂约 1 s（t0 之前的 188 块），视频从 t0 起。
    /// t0 之前的音频没有画面可配、不能送，但不能算"丢"：audioDropped 必须为 0（修前 = 47，8 小时长稳里的那个数字）；
    /// 两轨从第一个关键帧的同一原点起送：落盘从帧号 0 起、两轨起点相差 ≤ 半个 AAC 包 + 一个包、第 0 拍闪光有 click 配对。
    func testW2D2_srtStart_noAudioDroppedBeforeFirstVideo() throws {
        let mtx = try startInstances(1, test: "w2d2-srt")[0]
        let scene = try StreamScene(leadMs: 1500)
        let o = try scene.makeOutput(name: "w2d2-srt", url: mtx.srtURL("srt1"), connectTimeout: 4)
        outputs = [o]
        let startedAt = HostClock.now()
        try o.start()
        let t0 = scene.clock.time(of: Tick(0))
        let early = SignalFeeder(signal: scene.signal, startSample: -48128)   // 188 块 × 256 = 1.0027 s，正好喂到样本 0
        var connectedAt: HostTime?
        while HostClock.now() < t0 - HostDuration(milliseconds: 8) {
            early.feed(upTo: HostClock.now(), to: [o])
            if connectedAt == nil, o.state == .publishing { connectedAt = HostClock.now() }
            Thread.sleep(forTimeInterval: 0.005)
        }
        early.flush(upToSample: 0, to: [o])
        guard let connectedAt else {
            o.stop()
            let fw = (try? Proc.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).stdout).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if fw.contains("enabled") {
                throw XCTSkip("BLOCKED-防火墙：SRT 在 t0 前没连上（\(o.state)）且应用防火墙开着；先确认 mediamtx 在放行名单里")
            }
            XCTFail("SRT 在 t0（1.5 s）前没连上：\(o.state)")
            return
        }
        let report = try scene.feed(outputs: [o], ticks: 0..<600)
        o.stop()
        let c = o.counters
        print("W2-D2 SRT：连上用了 \(String(format: "%.2f", (connectedAt - startedAt).seconds)) s（t0 前 \(String(format: "%.2f", (t0 - connectedAt).seconds)) s）；t0 之前喂了 48128 样本；\(c)")
        XCTAssertEqual(report.framesFed, 600)
        XCTAssertEqual(c.framesSent, 600)
        XCTAssertEqual(c.networkDropped, 0)
        XCTAssertEqual(c.audioDropped, 0, "t0 之前的音频没有画面可配，裁掉不算丢：\(c)")
        XCTAssertEqual(o.videoEncoder.counters.skipped, 0)
        let files = mtx.recordings("srt1")
        XCTAssertEqual(files.count, 1, "\(files)")
        guard let file = files.first else { return }
        let st = try Frameprobe.stats(file)
        print("frameprobe stats：\(st)")
        XCTAssertGreaterThanOrEqual(st.totalFrames, 599)
        XCTAssertEqual(st.dropGaps, 0)
        XCTAssertEqual(st.undecodable, 0)
        let frames = try Frameprobe.frames(file, limit: 5)
        XCTAssertEqual(frames.first?.frameNumber, 0, "落盘从第 0 拍起：\(frames)")
        let starts = try FFprobe.streamStartTimes(file)
        print("落盘两轨起点：视频 \(starts.video) s，音频 \(starts.audio) s")
        XCTAssertLessThanOrEqual(abs(starts.video - starts.audio), 1024.0 / 48000 * 1.5 + 0.001, "两轨从同一时刻起（最近包对齐：≤ 半个包 + 一个包）")
        let av = try AVOffsetFFmpeg.measure(file)
        print("A/V（ffmpeg 口径）：mean \(av.meanMs) ms，max |\(av.maxAbsMs)| ms，\(av.pairs.count) 对；第一对 \(av.pairs.first.map { "闪光 \($0.flash) s click \($0.click) s" } ?? "无")")
        print("第一秒音频 RMS \(String(format: "%.3f", av.rmsFirstSecond))")
        XCTAssertGreaterThan(av.rmsFirstSecond, 0.05, "落盘文件第一秒要有音频（正弦 RMS ≈ 0.071）")
        XCTAssertGreaterThanOrEqual(av.pairs.count, 9)
        guard let first = av.pairs.first else { return }
        XCTAssertEqual(first.flash, 1.0, accuracy: 0.02, "文件从第 0 拍起：第一个能配对的闪光（第 60 拍，第 0 拍的 click 在 AAC 热身里）在 1.0 s")
        XCTAssertLessThanOrEqual(abs(first.flash - first.click) * 1000, 10.7 + 2, "第一秒末的 click 与画面对齐（最近包 ≤ 10.7 ms）")
        XCTAssertLessThanOrEqual(av.maxAbsMs, 10.7 + 2)
    }

    // MARK: E2 / E3 在落盘文件上复跑

    /// 6 Mbps H.264 1080p60 推 60 s：10 s 滑窗平均误差 ≤ 10%（目标 5%）、1 s 峰值 ≤ 1.5×（目标 1.2×）、关键帧间隔恰好 120。
    func testE2E3_rtmp_60s_bitrateAndKeyframeIntervalOnRecording() throws {
        let mtx = try startInstances(1, test: "e2e3")[0]
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "e2e3", url: mtx.rtmpURL("s1"))
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitPublishing(o), "\(o.state)")
        try scene.feed(outputs: [o], ticks: 0..<3600)
        o.stop()
        let c = o.counters
        print("E2/E3 推流：\(c)")
        XCTAssertEqual(c.networkDropped, 0)
        guard let file = mtx.recordings("s1").first else { return XCTFail("没有录制文件") }
        let pk = try FFprobe.packets(file)
        XCTAssertGreaterThanOrEqual(pk.count, 3599, "落盘帧数（MediaMTX 丢最后一帧）")
        // 每秒桶
        let seconds = Int((pk.last?.ptsTime ?? 0).rounded(.up))
        var bins = [Int](repeating: 0, count: max(seconds, 1))
        for p in pk { let b = min(bins.count - 1, max(0, Int(p.ptsTime))); bins[b] += p.size }
        let target = 6_000_000.0
        let stable = Array(bins.dropFirst(1).dropLast(1))   // 掐头去尾各 1 s
        var worstWindowError = 0.0
        if stable.count >= 10 {
            for i in 0...(stable.count - 10) {
                let avg = Double(stable[i..<(i + 10)].reduce(0, +)) * 8 / 10
                worstWindowError = max(worstWindowError, abs(avg - target) / target)
            }
        }
        let peak = Double(stable.max() ?? 0) * 8 / target
        let overall = Double(pk.reduce(0) { $0 + $1.size }) * 8 / (pk.last!.ptsTime - pk.first!.ptsTime + 1.0 / 60) / target
        print("E2：总平均 \(String(format: "%.3f", overall))×，10 s 窗最大误差 \(String(format: "%.2f", worstWindowError * 100))%，1 s 峰值 \(String(format: "%.3f", peak))×")
        XCTAssertLessThanOrEqual(worstWindowError, 0.10, "E2 平均误差（必须 ≤ 10%）")
        XCTAssertLessThanOrEqual(peak, 1.5, "E2 峰值（必须 ≤ 1.5×）")
        let keyIdx = pk.enumerated().filter { $0.element.isKeyframe }.map(\.offset)
        let intervals = zip(keyIdx.dropFirst(), keyIdx).map { $0 - $1 }
        print("E3：关键帧位置 \(keyIdx.prefix(5))…，间隔 \(Set(intervals))")
        XCTAssertEqual(keyIdx.first, 0)
        XCTAssertTrue(intervals.allSatisfy { abs($0 - 120) <= 1 }, "E3 间隔 ≤ ±1 帧：\(Set(intervals))")
    }

    // MARK: E7 / E8 / E9（需要 netem）

    /// E7：三路推三个实例，第 10 s 封第 2 路 30 s；第 1、3 路网络丢帧 = 0 且落盘无缺口（硬性）；第 2 路放开后 ≤ 15 s 重连。
    /// 损伤来源：SWITCHER_NETEM 设了就是 dummynet（sudo），否则用户态代理（Impairment）。
    func testE7_threeStreams_blockSecondFor30s_othersDropZero() throws {
        let mtx = try startInstances(3, test: "e7")
        let routes = try (0..<3).map { try Impairment(mtx: mtx[$0], path: "s\($0 + 1)", proxyPort: 31935 + $0) }
        impairments = routes
        print("损伤：\(routes[1].description)")
        let scene = try StreamScene()
        outputs = try (0..<3).map { try scene.makeOutput(name: "e7-s\($0 + 1)", url: routes[$0].url) }
        for o in outputs { try o.start() }
        for o in outputs { XCTAssertTrue(waitPublishing(o), "\(o.consumerName) \(o.state)") }
        var blockedAt: HostTime?
        var unblockAt: HostTime?
        var reconnectedAt: HostTime?
        var sawDisconnect = false
        let second = outputs[1]
        try scene.feed(outputs: outputs, ticks: 0..<3600) { tick, now in
            if tick == 600 {
                try? routes[1].block(seconds: 30)
                blockedAt = HostClock.now()
                unblockAt = blockedAt! + HostDuration(seconds: 30)
                print("t=10 s 封第 2 路 30 s")
            }
            if blockedAt != nil, !sawDisconnect, second.state != .publishing { sawDisconnect = true; print("t=\(tick / 60) s 第 2 路判断线：\(second.state)") }
            if let u = unblockAt, reconnectedAt == nil, sawDisconnect, HostClock.now() > u, second.state == .publishing {
                reconnectedAt = HostClock.now()
                print("t=\(tick / 60) s 第 2 路重连成功，放开后 \(String(format: "%.2f", (reconnectedAt! - u).seconds)) s")
            }
        }
        stopAll(outputs)
        let c = outputs.map(\.counters)
        for i in [0, 2] {
            let skipped = outputs[i].videoEncoder.counters.skipped
            print("第 \(i + 1) 路：\(c[i])，编码器 skipped \(skipped)")
            XCTAssertEqual(c[i].networkDropped, 0, "E7 硬性：第 \(i + 1) 路网络丢帧必须为 0")
            XCTAssertEqual(c[i].disconnects, 0)
            XCTAssertEqual(skipped, 0, "E1：第 \(i + 1) 路编码器不该跳帧（跳了说明喂帧线程被卡过，不是网络问题）")
            XCTAssertEqual(c[i].framesSent, c[i].framesReceived, "编码出的帧全部交出")
            let totals = try frameprobeTotals(mtx[i].recordings("s\(i + 1)"))
            print("第 \(i + 1) 路落盘：\(totals)")
            // 落盘 = 交出 − 1（MediaMTX 丢每个文件最后一帧）；帧号缺口只有编码器跳帧才会有
            XCTAssertGreaterThanOrEqual(totals.frames, Int(c[i].framesSent) - 1, "第 \(i + 1) 路落盘帧数")
            if skipped == 0 { XCTAssertEqual(totals.gaps, 0, "第 \(i + 1) 路帧号连续") }
        }
        print("第 2 路：\(c[1])")
        for o in outputs { print("\(o.consumerName) 退出原因：\(o.lastExitReasonDescription)") }
        XCTAssertTrue(sawDisconnect, "第 2 路应当被判断线")
        XCTAssertGreaterThanOrEqual(c[1].reconnects, 1, "第 2 路应当重连")
        XCTAssertNotNil(reconnectedAt, "第 2 路放开后 20 s 内没重连上")
        if let r = reconnectedAt, let u = unblockAt {
            XCTAssertLessThanOrEqual((r - u).seconds, 15, "E8 必须 ≤ 15 s（目标 5）")
        }
        XCTAssertGreaterThan(c[1].networkDropped, 0, "封住的 30 s 里的帧记为网络丢帧")
    }

    /// E8：封 / 放 10 次（每次封 10 s），每次放开后自动重连成功且 ≤ 15 s（目标 5）；最后一次重连后再推 30 s，落盘最后一段帧号连续。
    func testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect() throws {
        let mtx = try startInstances(1, test: "e8")[0]
        let route = try Impairment(mtx: mtx, path: "s2", proxyPort: 31940)
        impairments = [route]
        print("损伤：\(route.description)")
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "e8", url: route.url)
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitPublishing(o), "\(o.state)")
        let cycles = 10
        let blockSeconds = 10.0
        var results: [Double] = []
        var detect: [Double] = []
        var phase = 0            // 0 = 稳定推 3 s；1 = 已封等断线；2 = 等重连
        var phaseStart = HostClock.now()
        var unblockAt = HostClock.now()
        var tick = 0
        let maxTicks = 60 * 60 * 9
        while results.count < cycles && tick < maxTicks {
            try scene.feed(outputs: [o], ticks: tick..<(tick + 30)) { t, _ in
                let now = HostClock.now()
                switch phase {
                case 0:
                    if (now - phaseStart).seconds >= 3 {
                        try? route.block(seconds: blockSeconds)
                        unblockAt = HostClock.now() + HostDuration(seconds: blockSeconds)
                        phase = 1
                        phaseStart = now
                        print("第 \(results.count + 1) 次封（tick \(t)）")
                    }
                case 1:
                    if o.state != .publishing {
                        phase = 2
                        detect.append((now - phaseStart).seconds)
                        print("  断线判定用了 \(String(format: "%.1f", (now - phaseStart).seconds)) s：\(o.state)")
                    } else if (now - phaseStart).seconds > blockSeconds + 20 {
                        XCTFail("封住 \(blockSeconds + 20) s 还没判断线")
                        phase = 2
                    }
                case 2:
                    if o.state == .publishing && now > unblockAt {
                        let secs = (now - unblockAt).seconds
                        results.append(secs)
                        print("  第 \(results.count) 次重连成功：放开后 \(String(format: "%.2f", secs)) s")
                        phase = 0
                        phaseStart = now
                    } else if now > unblockAt + HostDuration(seconds: 40) {
                        XCTFail("放开后 40 s 没重连上：\(o.state)")
                        results.append(.infinity)
                        phase = 0
                        phaseStart = now
                    }
                default: break
                }
            }
            tick += 30
        }
        // 最后一次重连后再推 30 s
        try scene.feed(outputs: [o], ticks: tick..<(tick + 1800))
        o.stop()
        let c = o.counters
        print("E8 重连耗时：\(results.map { String(format: "%.2f", $0) })；断线判定：\(detect.map { String(format: "%.1f", $0) })；\(c)")
        XCTAssertEqual(results.count, cycles)
        XCTAssertEqual(results.filter { $0 <= 15 }.count, cycles, "10 / 10 在 15 s 内：\(results)")
        XCTAssertEqual(c.reconnects, UInt64(cycles))
        // 最后一段录制：帧号连续、从关键帧起
        guard let last = mtx.recordings("s2").last else { return XCTFail("没有录制文件") }
        let st = try Frameprobe.stats(last)
        print("最后一段 \(last.lastPathComponent)：\(st)")
        XCTAssertEqual(st.dropGaps, 0, "重连后帧号连续")
        XCTAssertEqual(st.undecodable, 0)
        XCTAssertGreaterThanOrEqual(st.totalFrames, 1800 - 1)
    }

    /// E9：带宽限到码率的 70% 跑 5 分钟；软件报告的网络丢帧与落盘缺帧数误差 ≤ 5%（目标 1%）。
    func testE9_bandwidth70pct_5min_dropCountWithin5pct() throws {
        let mtx = try startInstances(1, test: "e9")[0]
        let route = try Impairment(mtx: mtx, path: "s1", proxyPort: 31950)
        impairments = [route]
        print("损伤：\(route.description)")
        let scene = try StreamScene()
        let bitrate = 6_000_000
        let o = try scene.makeOutput(name: "e9", url: route.url, bitrate: bitrate,
                                     queue: StreamOutput.QueuePolicy(stallSeconds: 8, drainSeconds: 5, lingerSeconds: 3))
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitPublishing(o), "\(o.state)")
        let kbit = Int(Double(bitrate + 160_000) * 0.7 / 1000)
        try route.limit(kbit: kbit, seconds: 330)
        print("限速 \(kbit) kbit/s（码率 70%）5 分钟")
        let seconds = 300
        try scene.feed(outputs: [o], ticks: 0..<(seconds * 60)) { t, _ in
            if t % 1800 == 0 && t > 0 {
                let c = o.counters
                print("t=\(t / 60) s：送出 \(c.framesSent) 丢 \(c.networkDropped)（满 \(c.droppedQueueFull) 等关键帧 \(c.droppedWaitingKeyframe) 断线 \(c.droppedDisconnected)）在途 \(c.inFlightBytes / 1024) KB 状态 \(c.state)")
            }
        }
        o.stop()
        route.clear()
        let c = o.counters
        print("E9：\(c)")
        let files = mtx.recordings("s1")
        var recorded = 0
        for f in files { recorded += try FFprobe.countFrames(f) }
        let missing = Int(c.framesReceived) - recorded - files.count   // MediaMTX 每个文件丢最后一帧
        let reported = Int(c.networkDropped)
        let error = abs(Double(reported - missing)) / Double(max(missing, 1))
        print("E9：收到 \(c.framesReceived)，落盘 \(recorded)（\(files.count) 个文件），缺 \(missing)，软件报告 \(reported)，误差 \(String(format: "%.2f", error * 100))%")
        XCTAssertGreaterThan(missing, 0, "70% 带宽应当有缺帧")
        XCTAssertLessThanOrEqual(error, 0.05, "E9 必须 ≤ 5%")
        XCTAssertEqual(c.disconnects, 0, "限速不该被判成断线（\(o.lastExitReasonDescription)）")
    }
}
