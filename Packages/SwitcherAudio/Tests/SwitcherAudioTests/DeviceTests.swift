import XCTest
import CoreAudio
import SwitcherContracts
@testable import SwitcherAudio

/// 设备层：真设备（内置扬声器）A1 / A7、空输出设备、聚合设备、默认设备切换、输入设备。
/// 时长：默认短跑（真设备 10 s）；SW_AUDIO_FULL=1 时按 prompt（A1 10 分钟、A7 真设备 1 分钟）；报告里的数字是 FULL 跑出来的。
final class DeviceTests: XCTestCase {

    /// 实时喂源：一个线程按 host time 把合成信号写进环（模拟输入设备的交付节奏）。
    final class Feeder {
        let sources: [OfflineAudioSource]
        private var thread: Thread?
        private let stop = NSLock()
        private var stopping = false
        init(sources: [OfflineAudioSource]) { self.sources = sources }
        func start() {
            let t = Thread { [self] in
                while true {
                    stop.lock(); let s = stopping; stop.unlock()
                    if s { break }
                    let now = HostClock.now()
                    for src in sources { src.deliver(upTo: now) }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            t.qualityOfService = .userInteractive
            thread = t
            t.start()
        }
        func end() { stop.lock(); stopping = true; stop.unlock(); Thread.sleep(forTimeInterval: 0.01) }
    }

    func requireOutputDevice() throws -> AudioDeviceID {
        guard let id = AudioHAL.defaultOutputDevice() else { throw XCTSkip("BLOCKED-硬件：没有默认输出设备") }
        return id
    }

    /// 标准搭台：混音器 + 两路实时合成输入（一路 +100 ppm、一路 −100 ppm）+ 全效果，Master 静音（不出声）。
    func makeRealtimeRig(inputs: Int = 2) throws -> (AudioMixer, Feeder) {
        let mixer = AudioMixer()
        try mixer.installStandardEffects()
        for e in BusEffect.allCases { mixer.setEffectEnabled(.master, e, true) }
        let t0 = HostClock.now()
        var sources = [OfflineAudioSource]()
        for i in 0..<inputs {
            let src = OfflineAudioSource(channels: 2, t0: t0, driftPpm: i % 2 == 0 ? 100 : -100)
            sources.append(src)
            mixer.attach(ring: src.ring, toSlot: i)
            mixer.setGain(slot: i, dB: -12)
        }
        mixer.setBusMuted(.master, true)      // 测试不出声（表和计数都在静音之前）
        let feeder = Feeder(sources: sources)
        feeder.start()
        return (mixer, feeder)
    }

    func testDevice_enumerateAndDefault() throws {
        let all = AudioHAL.devices()
        XCTAssertFalse(all.isEmpty, "至少有一台设备")
        for d in all { print("[dev] \(d.id) \(d.name) in=\(d.inputChannels) out=\(d.outputChannels) aggregate=\(d.isAggregate) builtIn=\(d.isBuiltIn) rate=\(AudioHAL.nominalSampleRate(d.id)) buffer=\(AudioHAL.bufferFrameSize(d.id)) range=\(AudioHAL.bufferFrameSizeRange(d.id))") }
        let out = try requireOutputDevice()
        XCTAssertGreaterThan(AudioHAL.info(out).outputChannels, 0)
    }

    /// A1：真设备 dropouts = underruns = 0（默认 10 s；SW_AUDIO_FULL=1 → 600 s）。
    func testA1_builtInOutput_dropoutsAndUnderrunsZero() throws {
        let dev = try requireOutputDevice()
        let seconds = T.seconds("SW_AUDIO_A1_SECONDS", default: T.fullRuns ? 600 : 10)
        let (mixer, feeder) = try makeRealtimeRig()
        defer { feeder.end() }
        let out = try AudioOutputDevice(mixer: mixer, deviceID: dev, blockFrames: 256)
        try out.start()
        Thread.sleep(forTimeInterval: 1.0)     // 就绪
        mixer.resetStats()
        out.resetCallbackStats()
        Thread.sleep(forTimeInterval: seconds)
        let st = mixer.stats
        let cb = out.callbackStats
        out.stop()
        XCTAssertEqual(st.dropouts, 0, "A1 dropouts")
        XCTAssertEqual(st.underruns, 0, "A1 underruns")
        XCTAssertEqual(st.rtViolations, 0)
        XCTAssertGreaterThan(cb.callbacks, UInt64(seconds * 48_000 / 256 * 0.9))
        for i in 0..<2 { XCTAssertTrue(st.inputs[i].primed) }
        let info = AudioHAL.info(dev)
        print(String(format: "[A1] %@ %.0f s：buffer 请求 256 实际 %d，回调 %llu，dropouts %llu underruns %llu 违规 %llu，回调抖动 max %.3f ms p99 %.1f ms，提前量 min %.2f max %.2f ms，最长块 %.0f µs，输入比率 %.7f / %.7f，输出延迟(latency+safety) %d 帧",
                     info.name, seconds, cb.lastFrames, cb.callbacks, st.dropouts, st.underruns, st.rtViolations, cb.maxJitterMs, cb.p99JitterMs,
                     HostDuration(ticks: Int64(cb.minLeadTicks)).milliseconds, HostDuration(ticks: Int64(cb.maxLeadTicks)).milliseconds,
                     Double(st.maxBlockTicks) * HostClock.timebase.numerDouble / 1000, st.inputs[0].ratio, st.inputs[1].ratio, out.outputLatencyFrames))
        print("[A1] 抖动直方图（100 µs/桶）：\(cb.jitterHistogram.prefix(12))")
    }

    /// A7 真设备：1 分钟（FULL）/ 10 s，守卫 + malloc 钩子，违规 0。
    func testA7_realDevice_zeroViolations() throws {
        let dev = try requireOutputDevice()
        let seconds = T.seconds("SW_AUDIO_A7_DEVICE_SECONDS", default: T.fullRuns ? 60 : 10)
        RealtimeGuard.installMallocProbe()
        defer { RealtimeGuard.removeMallocProbe() }
        let (mixer, feeder) = try makeRealtimeRig(inputs: 4)
        defer { feeder.end() }
        let tap = mixer.addTap(source: .bus(.master))!
        let out = try AudioOutputDevice(mixer: mixer, deviceID: dev, blockFrames: 256)
        try out.start()
        Thread.sleep(forTimeInterval: 0.5)
        RealtimeGuard.reset()
        mixer.resetStats()
        let deadline = Date().addingTimeInterval(seconds)
        var n = 0
        while Date() < deadline {
            while tap.pop() != nil {}
            if n % 50 == 0 { mixer.setGain(slot: n % 4, dB: Double(-12 + n % 5)); mixer.crossfade(from: n % 4, to: (n + 1) % 4, durationBlocks: 20, startHostTime: HostClock.now()) }
            n += 1
            Thread.sleep(forTimeInterval: 0.02)
        }
        let st = mixer.stats
        out.stop()
        XCTAssertEqual(st.rtViolations, 0, "A7 真设备违规")
        XCTAssertEqual(RealtimeGuard.allocationsInRealtime, 0, "实时区分配")
        XCTAssertEqual(st.dropouts, 0)
        XCTAssertEqual(st.underruns, 0)
        print(String(format: "[A7] 真设备 %.0f s：违规 %llu，实时区分配 %llu，dropouts %llu，underruns %llu，块 %llu", seconds, st.rtViolations, RealtimeGuard.allocationsInRealtime, st.dropouts, st.underruns, st.blocksRendered))
    }

    /// 空输出设备：timer 驱动，块数 = 时间 × 48000 / 256，无跳块，dropouts 0。
    func testDevice_nullOutputDeviceRunsOnTimer() throws {
        let (mixer, feeder) = try makeRealtimeRig()
        defer { feeder.end() }
        let null = NullOutputDevice(mixer: mixer, blockFrames: 256)
        try null.start()
        Thread.sleep(forTimeInterval: 1.0)
        mixer.resetStats()
        Thread.sleep(forTimeInterval: 5.0)
        let st = mixer.stats
        let ds = null.stats
        null.stop()
        XCTAssertEqual(ds.skippedBlocks, 0)
        XCTAssertEqual(st.dropouts, 0)
        XCTAssertEqual(st.underruns, 0)
        XCTAssertEqual(st.rtViolations, 0)
        XCTAssertEqual(Double(ds.blocks), 6.0 * 48_000 / 256, accuracy: 6.0 * 48_000 / 256 * 0.02)
        XCTAssertTrue(st.inputs[0].primed && st.inputs[1].primed)
        print(String(format: "[null] 6 s：块 %llu 跳块 %llu 醒来最晚 %.3f ms，输入比率 %.7f / %.7f", ds.blocks, ds.skippedBlocks, ds.maxWakeLateMs, st.inputs[0].ratio, st.inputs[1].ratio))
        XCTAssertFalse(null.isRunning)
    }

    /// 聚合设备：私有聚合（默认输出设备一个子设备）上跑 IOProc，回调正常，销毁不崩。
    func testDevice_aggregateDeviceOutput() throws {
        let dev = try requireOutputDevice()
        let uid = AudioHAL.info(dev).uid
        let agg = try AudioHAL.createPrivateAggregateDevice(name: "Switcher 测试聚合", subDeviceUIDs: [uid], masterUID: uid)
        defer { AudioHAL.destroyAggregateDevice(agg) }
        Thread.sleep(forTimeInterval: 0.3)
        let info = AudioHAL.info(agg)
        XCTAssertTrue(info.isAggregate)
        XCTAssertGreaterThan(info.outputChannels, 0)
        let (mixer, feeder) = try makeRealtimeRig()
        defer { feeder.end() }
        let out = try AudioOutputDevice(mixer: mixer, deviceID: agg, blockFrames: 256, followsDefault: false)
        try out.start()
        Thread.sleep(forTimeInterval: 2.0)
        let cb = out.callbackStats
        let st = mixer.stats
        out.stop()
        XCTAssertGreaterThan(cb.callbacks, 300)
        XCTAssertEqual(st.dropouts, 0)
        print("[agg] 聚合设备 \(info.name) out=\(info.outputChannels) in=\(info.inputChannels)：回调 \(cb.callbacks)，buffer \(cb.lastFrames)，抖动 max \(cb.maxJitterMs) ms")
    }

    /// 设备切换：运行中 rebuild 到另一台设备（聚合）再回来，混音上下文不动、不崩、计数继续。
    func testDevice_rebuildOnAnotherDeviceWhileRunning() throws {
        let dev = try requireOutputDevice()
        let uid = AudioHAL.info(dev).uid
        let agg = try AudioHAL.createPrivateAggregateDevice(name: "Switcher 测试聚合 2", subDeviceUIDs: [uid], masterUID: uid)
        defer { AudioHAL.destroyAggregateDevice(agg) }
        Thread.sleep(forTimeInterval: 0.3)
        let (mixer, feeder) = try makeRealtimeRig()
        defer { feeder.end() }
        let out = try AudioOutputDevice(mixer: mixer, deviceID: dev, blockFrames: 256, followsDefault: false)
        try out.start()
        Thread.sleep(forTimeInterval: 1.0)
        let before = mixer.stats.blocksRendered
        out.rebuild(on: agg)
        XCTAssertTrue(out.isRunning)
        XCTAssertEqual(out.deviceID, agg)
        XCTAssertNil(out.lastError)
        Thread.sleep(forTimeInterval: 1.0)
        out.rebuild(on: dev)
        Thread.sleep(forTimeInterval: 1.0)
        let after = mixer.stats.blocksRendered
        out.stop()
        XCTAssertEqual(out.rebuilds, 2)
        XCTAssertGreaterThan(after - before, 300, "切换后混音继续")
        XCTAssertEqual(mixer.stats.rtViolations, 0)
        // 切换那一下的欠载 / dropout 允许存在（设备时间线重新起步），但不能崩；这里只打印
        print("[rebuild] 两次切换：块 \(after - before)，dropouts \(mixer.stats.dropouts)，underruns \(mixer.stats.underruns)")
    }

    /// 默认设备变更（真的改系统默认输出，几秒后改回）：只在 SW_AUDIO_FULL=1 下跑，验证监听 → 重建。
    func testDevice_defaultOutputChangeRebuildsViaListener() throws {
        guard T.fullRuns else { throw XCTSkip("会改系统默认输出设备几秒；SW_AUDIO_FULL=1 时才跑") }
        let dev = try requireOutputDevice()
        let uid = AudioHAL.info(dev).uid
        let agg = try AudioHAL.createPrivateAggregateDevice(name: "Switcher 测试聚合 3", subDeviceUIDs: [uid], masterUID: uid)
        defer { AudioHAL.destroyAggregateDevice(agg) }
        Thread.sleep(forTimeInterval: 0.3)
        let (mixer, feeder) = try makeRealtimeRig()
        defer { feeder.end() }
        let out = try AudioOutputDevice(mixer: mixer, deviceID: nil, blockFrames: 256)   // 跟随默认
        let changed = expectation(description: "device changed")
        changed.expectedFulfillmentCount = 2
        out.onDeviceChanged = { _ in changed.fulfill() }
        try out.start()
        Thread.sleep(forTimeInterval: 0.5)
        try AudioHAL.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, value: agg)
        Thread.sleep(forTimeInterval: 1.5)
        try AudioHAL.set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, value: dev)
        wait(for: [changed], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(out.deviceID, dev)
        XCTAssertTrue(out.isRunning)
        XCTAssertEqual(out.rebuilds, 2)
        XCTAssertNil(out.lastError)
        out.stop()
        print("[default] 默认设备切到聚合再切回：重建 \(out.rebuilds) 次，dropouts \(mixer.stats.dropouts)")
    }

    /// 输入设备：默认输入（麦克风）IOProc 把块写进环，stamps 按 48 kHz 推进。
    /// 需要给测试进程（xctest）麦克风权限：没有权限时 AudioDeviceStart 会等 TCC 弹窗（本会话实测卡 140 s 后返回 0x10000003）。
    /// 所以只在 SW_AUDIO_INPUT_DEVICE=1 时跑；IOProc 的输入路径另有不依赖权限的 IOProcTests。
    func testDevice_inputDeviceWritesRingWithStamps() throws {
        guard ProcessInfo.processInfo.environment["SW_AUDIO_INPUT_DEVICE"] == "1" else {
            throw XCTSkip("BLOCKED-权限：需要麦克风 TCC 权限；SW_AUDIO_INPUT_DEVICE=1 且已授权时才跑")
        }
        guard let dev = AudioHAL.defaultInputDevice() else { throw XCTSkip("BLOCKED-硬件：没有默认输入设备") }
        let info = AudioHAL.info(dev)
        guard info.inputChannels > 0 else { throw XCTSkip("BLOCKED-硬件：默认输入设备没有输入通道") }
        let ring = CAudioRing(channelCount: 1, capacityFrames: 65_536, stampCapacity: 1024)
        let input = try AudioInputDevice(deviceID: dev, ring: ring, channels: [0])
        try input.start(blockFrames: 256)
        Thread.sleep(forTimeInterval: 0.5)
        guard let s0 = ring.latestStamp else { input.stop(); throw XCTSkip("BLOCKED-权限：输入设备 0.5 s 内没有交付（麦克风 TCC？）") }
        Thread.sleep(forTimeInterval: 2.0)
        let s1 = ring.latestStamp!
        let cb = input.callbackStats
        input.stop()
        XCTAssertGreaterThan(cb.callbacks, 300)
        XCTAssertEqual(cb.timestampFallbacks, 0, "输入时间戳应带 HostTimeValid")
        let frames = Double(s1.frameIndex - s0.frameIndex)
        let secs = (s1.hostTime - s0.hostTime).seconds
        let rate = frames / secs
        XCTAssertEqual(rate, 48_000, accuracy: 48_000 * 500e-6, "stamps 推出的输入速率 \(rate) 应在 48 kHz ± 500 ppm")
        print(String(format: "[input] %@：回调 %llu 块 %d 帧，环写入 %llu 帧，stamps 速率 %.2f Hz（偏 %.1f ppm），输入延迟 %d 帧",
                     info.name, cb.callbacks, cb.lastFrames, ring.stats.framesWritten, rate, (rate / 48_000 - 1) * 1e6, input.inputLatencyFrames))
    }
}
