// AudioOutputDevice.swift —— 输出设备（含聚合设备 / 带输入的接口）与输入设备的 IOProc 挂接（设计方案 §3.5，prompt 第 5 条）。
//
// 输出：AudioDeviceCreateIOProcID 挂 sw_device_ioproc（C，实时线程），回调里 sw_mix_block → 散到设备通道。
// 输入：同一个 IOProc 把设备输入通道写进一个环（聚合设备一次回调同时带输入输出）；纯输入设备用 AudioInputDevice。
// 默认设备变更：followsDefault = true 时监听 kAudioHardwarePropertyDefaultOutputDevice，换设备时停旧的、在新设备上重建 IOProc，
// 混音上下文不动（切换不崩）。overload 通知计进 dropouts。
import Foundation
import CoreAudio
import SwitcherContracts
import CSwitcherAudioRT
import CSwitcherAudioHost

/// 逻辑通道（Master L R / A L R / B L R / HP L R）→ 设备通道序号，nil 不输出。
public struct BusChannelMap: Hashable, Sendable {
    public var master: (Int, Int)?
    public var busA: (Int, Int)?
    public var busB: (Int, Int)?
    public var headphones: (Int, Int)?
    public init(master: (Int, Int)? = (0, 1), busA: (Int, Int)? = nil, busB: (Int, Int)? = nil, headphones: (Int, Int)? = nil) {
        self.master = master; self.busA = busA; self.busB = busB; self.headphones = headphones
    }
    /// 默认：Master → 0,1；设备 ≥ 4 声道时 HP → 2,3。
    public static func standard(outputChannels: Int) -> BusChannelMap {
        BusChannelMap(master: outputChannels >= 2 ? (0, 1) : (outputChannels == 1 ? (0, 0) : nil),
                      headphones: outputChannels >= 4 ? (2, 3) : nil)
    }
    var cArray: [Int32] {
        func pair(_ p: (Int, Int)?) -> [Int32] { p.map { [Int32($0.0), Int32($0.1)] } ?? [-1, -1] }
        return pair(master) + pair(busA) + pair(busB) + pair(headphones)
    }
    public static func == (a: BusChannelMap, b: BusChannelMap) -> Bool { a.cArray == b.cArray }
    public func hash(into h: inout Hasher) { h.combine(cArray) }
}

/// 一台输出设备上的混音输出（可选同时把该设备的输入写进一个环）。
public final class AudioOutputDevice: @unchecked Sendable {
    public let mixer: AudioMixer
    public private(set) var deviceID: AudioDeviceID
    public let requestedBlockFrames: Int
    public let busMap: BusChannelMap
    /// 跟随系统默认输出设备。
    public let followsDefault: Bool
    private let client: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "switcher.audio.device.listener")
    private var overloadListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    /// 输入环（聚合设备 / 带输入的接口）：环声道 c ← 设备输入通道 inputChannelMap[c]。
    public private(set) var inputRing: CAudioRing?
    public private(set) var inputChannelMap: [Int] = []
    /// 设备切换次数（默认设备变更重建 IOProc）。
    public private(set) var rebuilds = 0
    /// 最近一次错误（重建失败等）。
    public private(set) var lastError: Error?
    /// 设备切换回调（非实时线程）。
    public var onDeviceChanged: (@Sendable (AudioDeviceID) -> Void)?

    /// - Parameters:
    ///   - deviceID: nil = 系统默认输出设备
    ///   - blockFrames: 想要的 buffer size（钳到设备范围；实际值看 actualBlockFrames）
    ///   - busMap: 总线 → 设备通道；nil = 按设备声道数取标准映射
    ///   - followsDefault: 跟随默认设备（deviceID 为 nil 时默认 true）
    public init(mixer: AudioMixer, deviceID: AudioDeviceID? = nil, blockFrames: Int = AudioFormat.defaultBlockFrames,
                busMap: BusChannelMap? = nil, followsDefault: Bool? = nil) throws {
        guard let id = deviceID ?? AudioHAL.defaultOutputDevice() else { throw AudioDeviceError.noDevice }
        self.mixer = mixer
        self.deviceID = id
        self.requestedBlockFrames = blockFrames
        self.busMap = busMap ?? .standard(outputChannels: AudioHAL.info(id).outputChannels)
        self.followsDefault = followsDefault ?? (deviceID == nil)
        guard let c = sw_device_client_create(mixer.context, UInt32(mixer.maxBlockFrames)) else { throw AudioDeviceError.noDevice }
        client = c
    }

    deinit {
        stop()
        sw_device_client_destroy(client)
    }

    /// 实际 buffer size（帧）。
    public var actualBlockFrames: Int { AudioHAL.bufferFrameSize(deviceID) }
    /// 输出端设备延迟 + 安全偏移（帧），加 buffer 就是"回调到扬声器"的延迟。
    public var outputLatencyFrames: Int {
        AudioHAL.latency(deviceID, scope: kAudioObjectPropertyScopeOutput) + AudioHAL.safetyOffset(deviceID, scope: kAudioObjectPropertyScopeOutput)
    }
    public var info: AudioDeviceInfo { AudioHAL.info(deviceID) }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// 把设备的输入通道写进 ring（聚合设备 / 带输入的接口）。inputChannels[c] = 环声道 c 对应的设备输入通道。
    /// 环由组装方创建并保持引用；这里只挂指针。可以在运行中换。
    public func setInput(ring: CAudioRing?, channels: [Int]) {
        lock.lock(); defer { lock.unlock() }
        inputRing = ring
        inputChannelMap = channels
        applyInputLocked()
    }

    private func applyInputLocked() {
        var locs = AudioHAL.channelLayout(deviceID, scope: kAudioObjectPropertyScopeInput)
        locs.withUnsafeMutableBufferPointer { sw_device_client_set_input_layout(client, $0.baseAddress, UInt32($0.count)) }
        var map = inputChannelMap.map { Int32($0) }
        map.withUnsafeMutableBufferPointer { sw_device_client_set_input_map(client, $0.baseAddress, UInt32($0.count)) }
        sw_device_client_set_input_ring(client, inputRing?.raw)
    }

    private func applyOutputLocked() {
        var locs = AudioHAL.channelLayout(deviceID, scope: kAudioObjectPropertyScopeOutput)
        locs.withUnsafeMutableBufferPointer { sw_device_client_set_output_layout(client, $0.baseAddress, UInt32($0.count)) }
        var map = busMap.cArray
        map.withUnsafeMutableBufferPointer { sw_device_client_set_output_map(client, $0.baseAddress) }
    }

    /// 启动：设 48 kHz、buffer size，建 IOProc，装监听，AudioDeviceStart。
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { throw AudioDeviceError.alreadyRunning }
        try startLocked()
        installDefaultListenerLocked()
    }

    private func startLocked() throws {
        try AudioHAL.setNominalSampleRate(deviceID, Double(AudioFormat.sampleRate))
        _ = try AudioHAL.setBufferFrameSize(deviceID, requestedBlockFrames)
        applyOutputLocked()
        applyInputLocked()
        mixer.setTimingCheck(true)
        var pid: AudioDeviceIOProcID?
        var st = AudioDeviceCreateIOProcID(deviceID, sw_device_ioproc, UnsafeMutableRawPointer(client), &pid)
        guard st == noErr, let p = pid else { throw AudioDeviceError.osStatus("AudioDeviceCreateIOProcID", st) }
        procID = p
        installDeviceListenersLocked()
        st = AudioDeviceStart(deviceID, p)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, p); procID = nil
            throw AudioDeviceError.osStatus("AudioDeviceStart", st)
        }
        running = true
    }

    /// 停止（幂等）。
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
        removeDefaultListenerLocked()
    }

    private func stopLocked() {
        guard running, let p = procID else { return }
        AudioDeviceStop(deviceID, p)
        AudioDeviceDestroyIOProcID(deviceID, p)
        removeDeviceListenersLocked()
        procID = nil
        running = false
    }

    // MARK: 监听

    private func installDeviceListenersLocked() {
        var over = AudioHAL.address(kAudioDeviceProcessorOverload)
        let ctx = mixer.context
        let block: AudioObjectPropertyListenerBlock = { _, _ in sw_mix_ctx_note_overload(ctx) }
        AudioObjectAddPropertyListenerBlock(deviceID, &over, listenerQueue, block)
        overloadListener = block
        var alive = AudioHAL.address(kAudioDevicePropertyDeviceIsAlive)
        let dev = deviceID
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !AudioHAL.isAlive(dev) else { return }
            self.deviceWentAway()
        }
        AudioObjectAddPropertyListenerBlock(deviceID, &alive, listenerQueue, aliveBlock)
        aliveListener = aliveBlock
    }

    private func removeDeviceListenersLocked() {
        if let b = overloadListener {
            var over = AudioHAL.address(kAudioDeviceProcessorOverload)
            AudioObjectRemovePropertyListenerBlock(deviceID, &over, listenerQueue, b)
            overloadListener = nil
        }
        if let b = aliveListener {
            var alive = AudioHAL.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(deviceID, &alive, listenerQueue, b)
            aliveListener = nil
        }
    }

    private func installDefaultListenerLocked() {
        guard followsDefault, defaultListener == nil else { return }
        var addr = AudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultDeviceChanged() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block)
        defaultListener = block
    }

    private func removeDefaultListenerLocked() {
        guard let b = defaultListener else { return }
        var addr = AudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, b)
        defaultListener = nil
    }

    private func defaultDeviceChanged() {
        guard let newID = AudioHAL.defaultOutputDevice() else { return }
        rebuild(on: newID)
    }

    private func deviceWentAway() {
        // 设备拔掉：跟随默认的换到新默认；否则停下（上下文与环都还在，之后可以再 start）
        if followsDefault, let newID = AudioHAL.defaultOutputDevice(), newID != deviceID { rebuild(on: newID) }
        else { lock.lock(); stopLocked(); lock.unlock() }
    }

    /// 换到另一台设备：停旧的、在新设备上重建 IOProc。混音上下文和输入环不动。
    public func rebuild(on newID: AudioDeviceID) {
        lock.lock(); defer { lock.unlock() }
        guard newID != deviceID || !running else { return }
        let wasRunning = running
        stopLocked()
        deviceID = newID
        rebuilds += 1
        if wasRunning {
            do { try startLocked() } catch { lastError = error }
        }
        onDeviceChanged?(newID)
    }

    /// 回调统计。
    public var callbackStats: DeviceCallbackStats {
        var s = sw_device_client_stats()
        sw_device_client_copy_stats(client, &s)
        return DeviceCallbackStats(s)
    }
    public func resetCallbackStats() { sw_device_client_reset_stats(client) }
}

/// 一台纯输入设备：IOProc 把选定的输入通道写进一个环（每块带 inInputTime 的 host time）。
public final class AudioInputDevice: @unchecked Sendable {
    public let deviceID: AudioDeviceID
    public let ring: CAudioRing
    public let channels: [Int]
    private let client: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let lock = NSLock()

    /// channels[c] = 环声道 c 对应的设备输入通道序号。
    public init(deviceID: AudioDeviceID, ring: CAudioRing, channels: [Int], maxBlockFrames: Int = 4096) throws {
        self.deviceID = deviceID
        self.ring = ring
        self.channels = channels
        guard let c = sw_device_client_create(nil, UInt32(maxBlockFrames)) else { throw AudioDeviceError.noDevice }
        client = c
        var locs = AudioHAL.channelLayout(deviceID, scope: kAudioObjectPropertyScopeInput)
        locs.withUnsafeMutableBufferPointer { sw_device_client_set_input_layout(client, $0.baseAddress, UInt32($0.count)) }
        var map = channels.map { Int32($0) }
        map.withUnsafeMutableBufferPointer { sw_device_client_set_input_map(client, $0.baseAddress, UInt32($0.count)) }
        sw_device_client_set_input_ring(client, ring.raw)
    }

    deinit { stop(); sw_device_client_destroy(client) }

    public func start(blockFrames: Int = AudioFormat.defaultBlockFrames) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { throw AudioDeviceError.alreadyRunning }
        try AudioHAL.setNominalSampleRate(deviceID, Double(AudioFormat.sampleRate))
        _ = try AudioHAL.setBufferFrameSize(deviceID, blockFrames)
        var pid: AudioDeviceIOProcID?
        var st = AudioDeviceCreateIOProcID(deviceID, sw_device_ioproc, UnsafeMutableRawPointer(client), &pid)
        guard st == noErr, let p = pid else { throw AudioDeviceError.osStatus("AudioDeviceCreateIOProcID", st) }
        st = AudioDeviceStart(deviceID, p)
        guard st == noErr else { AudioDeviceDestroyIOProcID(deviceID, p); throw AudioDeviceError.osStatus("AudioDeviceStart", st) }
        procID = p
        running = true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running, let p = procID else { return }
        AudioDeviceStop(deviceID, p)
        AudioDeviceDestroyIOProcID(deviceID, p)
        procID = nil
        running = false
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var callbackStats: DeviceCallbackStats {
        var s = sw_device_client_stats()
        sw_device_client_copy_stats(client, &s)
        return DeviceCallbackStats(s)
    }
    /// 输入端安全偏移 + 设备延迟（帧）。
    public var inputLatencyFrames: Int {
        AudioHAL.latency(deviceID, scope: kAudioObjectPropertyScopeInput) + AudioHAL.safetyOffset(deviceID, scope: kAudioObjectPropertyScopeInput)
    }
}

/// 空输出设备：timer 驱动的假设备时钟（time-constraint 线程 + mach_wait_until），CI 无声卡也能跑同一个 sw_mix_block。
public final class NullOutputDevice: @unchecked Sendable {
    public let mixer: AudioMixer
    public let blockFrames: Int
    private let driver: OpaquePointer
    private var running = false
    private let lock = NSLock()

    public init(mixer: AudioMixer, blockFrames: Int = AudioFormat.defaultBlockFrames) {
        self.mixer = mixer
        self.blockFrames = blockFrames
        guard let d = sw_null_driver_create(mixer.context, UInt32(blockFrames)) else { fatalError("sw_null_driver_create 失败") }
        driver = d
    }
    deinit { stop(); sw_null_driver_destroy(driver) }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { throw AudioDeviceError.alreadyRunning }
        let rc = sw_null_driver_start(driver)
        guard rc == 0 else { throw AudioDeviceError.osStatus("sw_null_driver_start", OSStatus(rc)) }
        running = true
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        sw_null_driver_stop(driver)
        running = false
    }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// 名义块周期（host tick）。
    public var periodTicks: UInt64 { sw_null_driver_period_ticks(driver) }
    public struct Stats: Hashable, Sendable {
        public var blocks: UInt64
        public var skippedBlocks: UInt64
        public var maxWakeLateTicks: UInt64
        public var wakeHistogram: [UInt64]
        public var maxWakeLateMs: Double { HostDuration(ticks: Int64(maxWakeLateTicks)).milliseconds }
    }
    public var stats: Stats {
        var s = sw_null_driver_stats()
        sw_null_driver_copy_stats(driver, &s)
        return Stats(blocks: s.blocks, skippedBlocks: s.skipped_blocks, maxWakeLateTicks: s.max_wake_late_ticks,
                     wakeHistogram: withUnsafeBytes(of: s.wake_hist) { Array($0.bindMemory(to: UInt64.self)) })
    }
}
