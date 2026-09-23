import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import XCTest
import SwitcherContracts
import SwitcherInputsHarness
@testable import SwitcherInputs

/// W2-A2 纯音频设备输入：A1 断裂 / A2 时间戳 / S4 热插拔 / RT 分配 / 权限。
/// 没有输入设备时全部 XCTSkip（内置麦克风算设备）。
final class AudioDeviceInputTests: XCTestCase {
    /// A1 的时长，默认 60 s；迭代时可用 SWITCHER_AUDIO_A1_SECONDS 缩短（报告里的数字是 60 s 的）。
    private var a1Seconds: Double {
        Double(ProcessInfo.processInfo.environment["SWITCHER_AUDIO_A1_SECONDS"] ?? "") ?? 60
    }

    /// 拿一台可用的输入设备（优先系统默认输入；SWITCHER_AUDIO_DEVICE_UID 可指定）。
    private func requireDevice() throws -> AudioInputDeviceInfo {
        let devices = AudioInputDevices.list()
        guard !devices.isEmpty else { throw XCTSkip("BLOCKED-硬件：本机没有音频输入设备") }
        if let wanted = ProcessInfo.processInfo.environment["SWITCHER_AUDIO_DEVICE_UID"] {
            guard let d = devices.first(where: { $0.uid == wanted }) else {
                throw XCTSkip("BLOCKED-硬件：找不到 SWITCHER_AUDIO_DEVICE_UID=\(wanted)")
            }
            return d
        }
        return devices.first(where: \.isDefaultInput) ?? devices[0]
    }

    private func requirePermission() throws {
        let status = CapturePermission.status(for: .audio)
        guard status == .authorized else {
            throw XCTSkip("BLOCKED-权限（TCC）：麦克风权限 \(status)。从 Terminal.app 跑 swift test，或用带用途说明的 .app")
        }
    }

    private func makeInput(_ device: AudioInputDeviceInfo, ring: HarnessAudioRing, traceCapacity: Int = 0,
                           number: Int = 1) -> AudioDeviceInput {
        var options = AudioDeviceInput.Options()
        options.traceCapacity = traceCapacity
        return AudioDeviceInput(number: number, name: device.name, deviceUID: device.uid, audioRing: ring, options: options)
    }

    /// 按 48 kHz 的节奏把环读空的消费者（模拟混音器）：预充 `prefillFrames` 帧后开始，每次读 256 帧。
    /// 只读已经有的量不会误报 underrun；真的断流才会。
    private final class RingDrain: @unchecked Sendable {
        private final class Flag: @unchecked Sendable { var stopped = false }
        private let thread: Thread
        private let flag = Flag()
        init(ring: HarnessAudioRing, prefillFrames: Int) {
            let flag = self.flag
            thread = Thread {
                let channels = ring.channelCount
                let block = 256
                let planes = (0..<channels).map { _ -> UnsafeMutablePointer<Float> in
                    let p = UnsafeMutablePointer<Float>.allocate(capacity: block)
                    p.initialize(repeating: 0, count: block)
                    return p
                }
                let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
                for c in 0..<channels { table[c] = planes[c] }
                defer {
                    table.deallocate()
                    for p in planes { p.deallocate() }
                }
                while !flag.stopped, ring.availableFrames < prefillFrames { usleep(2000) }
                let step = HostDuration(seconds: Double(block) / Double(AudioFormat.sampleRate))
                var next = HostClock.now() + step
                while !flag.stopped {
                    InputThread.wait(until: next)
                    _ = ring.read(into: UnsafePointer(table), frameCount: block)
                    next = next + step
                    if next < HostClock.now() { next = HostClock.now() + step }
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        func stop() { flag.stopped = true }
    }

    // MARK: 设备清单

    func testAudioDevices_listHasUIDsAndDefaultInput() throws {
        let devices = AudioInputDevices.list()
        guard !devices.isEmpty else { throw XCTSkip("BLOCKED-硬件：本机没有音频输入设备") }
        for d in devices {
            print("设备 \(d.name)：uid=\(d.uid) 声道 \(d.inputChannels) 采样率 \(d.sampleRate) 可选 \(d.availableSampleRates)"
                  + " 48k=\(d.supports48k) IO 块 \(d.bufferFrameSize) 传输 \(d.transportType) 默认输入=\(d.isDefaultInput)")
            XCTAssertFalse(d.uid.isEmpty)
            XCTAssertGreaterThan(d.inputChannels, 0)
            XCTAssertGreaterThan(d.sampleRate, 0)
            XCTAssertEqual(AudioInputDevices.deviceID(uid: d.uid), AudioInputDevices.deviceID(uid: d.uid))
            XCTAssertNotEqual(AudioInputDevices.deviceID(uid: d.uid), 0, "uid 应该能找回设备：\(d.uid)")
        }
        XCTAssertEqual(devices.filter(\.isDefaultInput).count, AudioInputDevices.defaultInputUID() == nil ? 0 : 1)
        // 订阅能建能摘，不崩
        let subscription = AudioInputDevices.observeChanges(queue: .global()) {}
        subscription.stop()
        subscription.stop()
    }

    // MARK: harness 的 audio-device 子命令（探针）

    func testAudioDeviceProbe_listsDevicesAndRunsOne() throws {
        for line in AudioDeviceProbe.deviceLines() { print(line) }
        try requirePermission()
        let device = try requireDevice()
        let run = try AudioDeviceProbe.run(uid: device.uid, seconds: 3) { print("  [probe] \($0)") }
        for line in AudioDeviceProbe.report(run) { print(line) }
        XCTAssertEqual(run.state, .live, run.lastError ?? "")
        XCTAssertEqual(run.breaks, 0)
        XCTAssertEqual(run.nonMonotonic, 0)
        XCTAssertGreaterThan(run.blocks.count, 30)
        XCTAssertEqual(run.ringStats.overruns, 0)
        XCTAssertFalse(run.intervalsMs.isEmpty)
    }

    // MARK: A1 —— 60 s 环里块连续、hostTime 单调、块间隔 = 块长 ± 1 ms、underrun 0

    func testA1_audioDeviceInputNoDiscontinuityFor60s() throws {
        try requirePermission()
        let device = try requireDevice()
        let seconds = a1Seconds
        let expectedBlocks = Int(seconds * 400) + 2000
        let ring = HarnessAudioRing(channelCount: 2, capacityFrames: 1 << 17, logCapacity: expectedBlocks)
        let input = makeInput(device, ring: ring)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 8000) { input.state == .live },
                      "8 s 内没进 live：\(input.state) \(input.lastError ?? "")")
        let drain = RingDrain(ring: ring, prefillFrames: 9600)
        defer { drain.stop() }
        let deadline = HostClock.now() + HostDuration(seconds: seconds)
        while HostClock.now() < deadline { usleep(200_000) }
        let stats = input.blockStats
        let ringStats = ring.stats
        let fifo = input.fifoCounters
        let blocks = ring.blocks
        print("A1（\(seconds) s，设备「\(device.name)」\(Int(input.deviceSampleRate.rounded())) Hz"
              + "\(input.isConverting ? "，泵线程转 48 kHz" : "")）：")
        print("  块 \(stats.blocks) / 帧 \(stats.frames)（期望 ≈ \(Int(seconds * 48000))），末块 \(stats.blockFrames) 帧 = \(stats.blockMs) ms")
        print("  环：written \(ringStats.framesWritten) read \(ringStats.framesRead) overruns \(ringStats.overruns) underruns \(ringStats.underruns)")
        print("  交接区：回调 \(fifo.callbacks) 产出 \(fifo.blocksProduced) 取走 \(fifo.blocksConsumed) 丢 \(fifo.blocksDropped) 块 / \(fifo.framesDropped) 帧，"
              + "超大 \(fifo.oversizeBlocks)，空回调 \(fifo.emptyCallbacks)，hostTime 退回 \(fifo.hostTimeFallbacks)")
        print("  块间隔：min \(stats.minIntervalMs) max \(stats.maxIntervalMs) ms，与块长最大偏差 \(stats.maxIntervalErrorMs) ms；"
              + "非单调 \(stats.nonMonotonicBlocks)；设备过载 \(stats.overloads)")

        XCTAssertEqual(input.state, .live, "跑完还应该是 live：\(input.lastError ?? "")")
        XCTAssertGreaterThan(blocks.count, Int(seconds * 10), "块太少：\(blocks.count)")
        // 1. 块连续：累计帧序号首尾相接
        var breaks = 0
        for i in 1..<blocks.count where blocks[i].frameIndex != blocks[i - 1].frameIndex + UInt64(blocks[i - 1].frameCount) { breaks += 1 }
        XCTAssertEqual(breaks, 0, "环里的块不连续 \(breaks) 处")
        XCTAssertEqual(fifo.blocksDropped, 0, "交接区丢块（泵线程没跟上）")
        XCTAssertEqual(fifo.framesDropped, 0)
        XCTAssertEqual(fifo.oversizeBlocks, 0)
        XCTAssertEqual(input.counters.audioFramesRejected, 0, "环满被拒")
        XCTAssertEqual(ringStats.overruns, 0)
        // 2. underrun 0
        XCTAssertEqual(ringStats.underruns, 0, "消费者欠载（有断流）")
        // 3. hostTime 单调
        var nonMonotonic = 0
        for i in 1..<blocks.count where blocks[i].hostTime.ticks <= blocks[i - 1].hostTime.ticks { nonMonotonic += 1 }
        XCTAssertEqual(nonMonotonic, 0, "hostTime 非严格递增 \(nonMonotonic) 处")
        XCTAssertEqual(stats.nonMonotonicBlocks, 0)
        // 4. 块间隔 = 块长 ± 1 ms
        var maxError = 0.0
        for i in 1..<blocks.count {
            let expected = Double(blocks[i - 1].frameCount) / Double(AudioFormat.sampleRate) * 1000
            maxError = max(maxError, abs((blocks[i].hostTime - blocks[i - 1].hostTime).milliseconds - expected))
        }
        print("  独立核算的最大块间隔偏差：\(maxError) ms")
        XCTAssertLessThanOrEqual(maxError, 1.0, "块间隔偏离块长超过 1 ms")
        // 5. 总帧数对得上时长（设备时钟与 host 时钟的差 < 0.5%）
        let expectedFrames = seconds * Double(AudioFormat.sampleRate)
        XCTAssertLessThan(abs(Double(stats.frames) - expectedFrames) / expectedFrames, 0.005,
                          "\(seconds) s 只写了 \(stats.frames) 帧（期望 ≈ \(Int(expectedFrames))）")
    }

    // MARK: A2 —— 块上打的是设备给的 mHostTime，与回调到达时刻的差稳定

    func testA2_audioDeviceBlockHostTimeIsDeviceTimestamp() throws {
        try requirePermission()
        let device = try requireDevice()
        let seconds = 10.0
        let ring = HarnessAudioRing(channelCount: 2, capacityFrames: 1 << 17, logCapacity: 1 << 14)
        let input = makeInput(device, ring: ring, traceCapacity: 1 << 14)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 8000) { input.state == .live },
                      "8 s 内没进 live：\(input.state) \(input.lastError ?? "")")
        let drain = RingDrain(ring: ring, prefillFrames: 9600)
        defer { drain.stop() }
        let deadline = HostClock.now() + HostDuration(seconds: seconds)
        while HostClock.now() < deadline { usleep(200_000) }
        let trace = input.blockTrace
        XCTAssertGreaterThan(trace.count, 100, "留痕太少")
        // 丢掉前 10 块（起流热身）
        let entries = Array(trace.dropFirst(10))
        let delays = entries.map { ($0.arrival - $0.hostTime).milliseconds }
        let mean = delays.reduce(0, +) / Double(delays.count)
        let sd = (delays.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(delays.count)).squareRoot()
        // hostTime 的步进 vs 到达时刻的步进：前者是设备时间轴（规整），后者带调度抖动
        var hostDeltas: [Double] = [], arrivalDeltas: [Double] = []
        for i in 1..<entries.count {
            hostDeltas.append((entries[i].hostTime - entries[i - 1].hostTime).milliseconds)
            arrivalDeltas.append((entries[i].arrival - entries[i - 1].arrival).milliseconds)
        }
        func spread(_ xs: [Double]) -> Double {
            let m = xs.reduce(0, +) / Double(xs.count)
            return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)).squareRoot()
        }
        let hostSd = spread(hostDeltas), arrivalSd = spread(arrivalDeltas)
        print("A2（\(Int(seconds)) s，设备「\(device.name)」，\(entries.count) 块）：")
        print("  d = 到达 − hostTime：平均 \(mean) ms，标准差 \(sd)，min \(delays.min()!)，max \(delays.max()!)")
        print("  ΔhostTime 标准差 \(hostSd) ms（设备时间轴）vs Δ到达 标准差 \(arrivalSd) ms（调度抖动）")
        print("  输入自己算的：\(input.blockStats)")
        XCTAssertEqual(input.fifoCounters.hostTimeFallbacks, 0, "设备没给 hostTime，退回了到达时刻")
        XCTAssertGreaterThan(mean, 0, "块首 hostTime 应早于回调到达时刻")
        XCTAssertLessThan(sd, 1.0, "d 的标准差应 < 1 ms（打的是设备时刻而不是到达时刻）")
        XCTAssertLessThan(hostSd, arrivalSd, "hostTime 的步进应比到达时刻规整")
        XCTAssertLessThan(abs(input.blockStats.sdDelayMs - sd), 0.05, "输入自己算的标准差应与这里核算的一致")
    }

    // MARK: S4 —— 拔掉设备进 noSignal，插回自动恢复（BLOCKED-硬件）

    func testS4_audioDeviceUnplugGoesNoSignalThenRecovers() throws {
        guard let uid = ProcessInfo.processInfo.environment["SWITCHER_AUDIO_HOTPLUG_UID"] else {
            throw XCTSkip("""
                BLOCKED-硬件：要一台能拔的 USB 声卡 / 音频接口（内置麦克风拔不掉）。人工步骤：
                ① `swift test --package-path Packages/SwitcherInputs --filter testS4` 之前先设
                   SWITCHER_AUDIO_HOTPLUG_UID=<uid>（uid 从 AudioDeviceProbe.deviceLines() 或 devices 清单里抄）；
                ② 提示"请拔掉设备"时把声卡拔掉 → 期望 state 进 noSignal，lastError 是"音频输入设备「…」已断开，等待重新连接"；
                ③ 提示"请插回"时插回去 → 期望 ≤ 3 s 回 live，输入编号不变、不用重建输入对象；
                ④ 默认 20 次，SWITCHER_AUDIO_HOTPLUG_CYCLES 可改。
                """)
        }
        try requirePermission()
        let cycles = Int(ProcessInfo.processInfo.environment["SWITCHER_AUDIO_HOTPLUG_CYCLES"] ?? "20") ?? 20
        let ring = HarnessAudioRing()
        let input = AudioDeviceInput(number: 5, name: "hotplug", deviceUID: uid, audioRing: ring)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 10000) { input.state == .live },
                      "设备起不来：\(input.state) \(input.lastError ?? "")")
        let result = HotplugTimer.run(input: input, cycles: cycles, cycleTimeoutSeconds: 120) { print($0) }
        print(result.summary)
        XCTAssertEqual(result.completedCycles, cycles)
        XCTAssertEqual(input.number, 5)
        XCTAssertLessThanOrEqual(result.maxRecoverySeconds, 3, "恢复 ≤ 3 s：\(result.summary)")
    }

    // MARK: RT —— IOProc 回调线程 10 s 零分配

    func testRT_audioDeviceCallbackAllocatesNothing() throws {
        try requirePermission()
        let device = try requireDevice()
        let ring = HarnessAudioRing(channelCount: 2, capacityFrames: 1 << 17, logCapacity: 1 << 14)
        let input = makeInput(device, ring: ring)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 8000) { input.state == .live },
                      "8 s 内没进 live：\(input.state) \(input.lastError ?? "")")
        let drain = RingDrain(ring: ring, prefillFrames: 9600)
        defer { drain.stop() }
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { input.callbackThreadPort != 0 }, "拿不到 IOProc 回调线程")
        let port = input.callbackThreadPort
        let before = input.fifoCounters.callbacks
        guard AllocationProbe.start(watching: port) else { throw XCTSkip("本系统没有 malloc_logger 钩子") }
        let deadline = HostClock.now() + HostDuration(seconds: 10)
        while HostClock.now() < deadline { usleep(200_000) }
        let result = AllocationProbe.stop()
        let after = input.fifoCounters.callbacks
        print("RT：10 s 内 IOProc 回调 \(after - before) 次，回调线程 malloc \(result.allocations) 次 / free \(result.deallocations) 次")
        XCTAssertGreaterThan(after - before, 500, "10 s 应该有几百次回调")
        XCTAssertEqual(result.allocations, 0, "音频回调线程不许分配（设计方案 §3.5、铁律 3）")
        XCTAssertEqual(result.deallocations, 0, "音频回调线程不许释放")
    }

    // MARK: 权限被拒 = error（不会自己好）

    func testPermission_microphoneDeniedIsError() throws {
        let status = CapturePermission.status(for: .audio)
        if status == .authorized {
            throw XCTSkip("本进程已有麦克风权限；拒绝路径要在 系统设置 › 隐私与安全性 › 麦克风 里撤销后再跑")
        }
        let ring = HarnessAudioRing()
        let input = AudioDeviceInput(number: 1, name: "mic", deviceUID: "", audioRing: ring)
        defer { input.stop() }
        XCTAssertNoThrow(try input.start())
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
        print("权限文案：\(message)")
        XCTAssertTrue(message.contains("麦克风权限"), message)
        XCTAssertTrue(message.contains("系统设置") || message.contains("用途说明"), "文案要告诉用户去哪里改：\(message)")
        XCTAssertTrue(message.contains("自动恢复"), "文案要说明授权后自动恢复：\(message)")
        XCTAssertEqual(ring.stats.framesWritten, 0, "没权限不该有音频")
        input.stop()
        XCTAssertEqual(input.state, .noSignal)
        XCTAssertGreaterThanOrEqual(input.counters.errorTransitions, 1)
    }

    // MARK: 采样率：先把设备固定到 48 kHz，停的时候还原

    func testAudioDevice_forcesDeviceToFortyEightKHzAndRestoresOnStop() throws {
        try requirePermission()
        let devices = AudioInputDevices.list()
        guard let device = devices.first(where: { abs($0.sampleRate - 48000) >= 0.5 && $0.supports48k }) else {
            throw XCTSkip("BLOCKED-硬件：没有「当前不是 48 kHz 但支持 48 kHz」的输入设备可试")
        }
        let original = device.sampleRate
        let ring = HarnessAudioRing()
        let input = AudioDeviceInput(number: 3, name: device.name, deviceUID: device.uid, audioRing: ring)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 8000) { input.state == .live },
                      "8 s 内没进 live：\(input.state) \(input.lastError ?? "")")
        print("固定采样率：设备「\(device.name)」\(original) Hz → \(input.deviceSampleRate) Hz，转换器 \(input.isConverting ? "开" : "关")")
        XCTAssertEqual(input.deviceSampleRate, 48000, accuracy: 0.5, "应当把设备固定到 48 kHz")
        XCTAssertFalse(input.isConverting, "设备能固定到 48 kHz 就不该走转换器")
        input.stop()
        let restored = AudioInputDevices.nominalSampleRate(AudioInputDevices.deviceID(uid: device.uid))
        print("  停之后还原成 \(restored) Hz（原值 \(original)）")
        XCTAssertEqual(restored, original, accuracy: 0.5, "停的时候要把设备采样率还原（别的程序还在用它）")
    }

    // MARK: 采样率：设备固定不到 48 kHz 时走泵线程上的转换器

    func testAudioDevice_converterPathProducesFortyEightKilohertz() throws {
        try requirePermission()
        let devices = AudioInputDevices.list()
        guard let device = devices.first(where: { abs($0.sampleRate - 48000) >= 0.5 }) else {
            throw XCTSkip("BLOCKED-硬件：没有非 48 kHz 的输入设备，转换器那条路只有单元测试覆盖")
        }
        var options = AudioDeviceInput.Options()
        options.forceSampleRate48k = false           // 不改设备，逼它走转换器（也就不会动别的程序在用的设备）
        let seconds = 5.0
        let ring = HarnessAudioRing(channelCount: 2, capacityFrames: 1 << 17, logCapacity: 1 << 13)
        let input = AudioDeviceInput(number: 4, name: device.name, deviceUID: device.uid, audioRing: ring, options: options)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 8000) { input.state == .live },
                      "8 s 内没进 live：\(input.state) \(input.lastError ?? "")")
        let drain = RingDrain(ring: ring, prefillFrames: 9600)
        defer { drain.stop() }
        let started = HostClock.now()
        let deadline = started + HostDuration(seconds: seconds)
        while HostClock.now() < deadline { usleep(200_000) }
        let elapsed = (HostClock.now() - started).seconds
        let stats = input.blockStats
        print("转换器路（设备「\(device.name)」\(Int(input.deviceSampleRate.rounded())) Hz → 48 kHz，\(elapsed) s）：")
        print("  块 \(stats.blocks) / 帧 \(stats.frames)（期望 ≈ \(Int(elapsed * 48000))），转换报错 \(stats.conversionErrors)")
        print("  交接区：\(input.fifoCounters)")
        XCTAssertTrue(input.isConverting, "应当走转换器")
        XCTAssertEqual(stats.conversionErrors, 0)
        XCTAssertEqual(input.fifoCounters.blocksDropped, 0)
        XCTAssertEqual(ring.stats.overruns, 0)
        let expected = elapsed * Double(AudioFormat.sampleRate)
        XCTAssertLessThan(abs(Double(stats.frames) - expected) / expected, 0.02,
                          "转换后每秒应当是 48000 帧：\(stats.frames) 帧 / \(elapsed) s")
    }

    // MARK: 设备不在 = noSignal + 文案（会自己好，G4 §8 第 4 条的口径）

    func testAudioDevice_missingDeviceIsNoSignalWithMessage() throws {
        try requirePermission()
        let ring = HarnessAudioRing()
        let input = AudioDeviceInput(number: 2, name: "没插的声卡", deviceUID: "switcher-no-such-audio-device", audioRing: ring)
        defer { input.stop() }
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 3000) { input.lastError != nil }, "没给出文案：\(input.state)")
        print("设备不在的文案：\(input.lastError ?? "")")
        XCTAssertEqual(input.state, .noSignal, "设备不在是会自己好的，应当是 noSignal 而不是 error")
        XCTAssertTrue((input.lastError ?? "").contains("找不到音频输入设备"), input.lastError ?? "")
        XCTAssertEqual(ring.stats.framesWritten, 0)
        input.stop()
        XCTAssertEqual(input.state, .noSignal)
    }
}
