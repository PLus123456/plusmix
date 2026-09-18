// AudioMixer.swift —— 混音上下文的 Swift 控制面（非实时线程）。
//
// 热路径在 CSwitcherAudioRT 的 sw_mix_block；这里只做：创建 / 销毁上下文、往 SPSC 命令队列里放命令、
// 管理输入环与消费者队列的生命周期、读统计与表的快照。所有 setter 都可以在任意非实时线程调用（内部一把锁串行化，
// 这把锁永远不会被实时线程碰）。
import Foundation
import SwitcherContracts
import CSwitcherAudioRT
import CSwitcherAudioHost

/// 每路输入的重采样方式（对应 C 的 sw_resample_mode）。
public enum ResampleMode: Int32, Sendable {
    /// 异步重采样，比率由速率估计器给（默认）。
    case estimated = 0
    /// 比率锁 1.0，仍经过重采样器（测试用：确定性延迟）。
    case locked = 1
    /// 不重采样直接拷贝：与输出设备同时钟的输入（聚合设备自己的输入）。
    case bypass = 2
}

/// 总线上的三格效果，顺序固定（设计方案 §7）。
public enum BusEffect: Int32, Sendable, CaseIterable {
    case parametricEQ = 0, dynamicsProcessor = 1, peakLimiter = 2
}

/// 消费者队列的来源。
public enum TapSource: Hashable, Sendable {
    /// 某条总线（总线增益之后）。
    case bus(Bus)
    /// 某路输入的推子后信号，含 AFV 门控（= 它送进总线的样子）。
    case input(slot: Int)
    /// 某路输入推子后、AFV 门控前（含增益 / 静音 / 声像 / 延迟线，不含 AFV）—— ISO 音轨用（W1-D2）。
    case inputPreAFV(slot: Int)
    var cValue: Int32 {
        switch self {
        case .bus(let b): Int32(b.rawValue)
        case .input(let s): SW_TAP_INPUT_BASE + Int32(s)
        case .inputPreAFV(let s): SW_TAP_INPUT_PRE_AFV_BASE + Int32(s)
        }
    }
}

/// 耳机总线从每路输入的哪一点取信号（W1-D2；对应 C 的 sw_monitor_point）。
public enum MonitorPoint: Int32, Sendable {
    /// 延迟线之前：不带对齐延迟与延迟补偿的低延迟监听（默认）。
    case preDelayLine = 0
    /// 延迟线之后：与节目总线同刻。
    case postDelayLine = 1
}

/// 速率估计器参数（默认值与理由见 sw_mix.c 顶部和报告）。
public struct RateEstimatorParameters: Hashable, Sendable {
    /// 年龄一阶低通时间常数（s）。
    public var levelTau: Double = 0.25
    /// 前馈速率比一阶低通时间常数（s）。
    public var rateTau: Double = 10
    /// 前馈测量窗（s）。
    public var rateWindow: Double = 1
    /// PI 环自然时间常数 1/ωn（s），临界阻尼。
    public var loopTau: Double = 10
    /// 比率限幅 ±（默认 1e-3 = ±0.1%）。
    public var maxDeviation: Double = 1e-3
    /// 设定点：环里平均保有帧数；0 = 2 × 块。
    public var targetFrames: Int = 0
    public init() {}
    func cValue(blockFrames: Int) -> sw_rate_params {
        var p = sw_rate_params_default(UInt32(blockFrames))
        p.level_tau_s = levelTau; p.rate_tau_s = rateTau; p.rate_window_s = rateWindow
        p.loop_tau_s = loopTau; p.max_deviation = maxDeviation
        if targetFrames > 0 { p.target_frames = UInt32(targetFrames) }
        return p
    }
}

/// 混音器创建参数。
public struct AudioMixerConfiguration: Sendable {
    /// 名义块大小（= 设备 buffer size，默认 256）。
    public var blockFrames: Int = AudioFormat.defaultBlockFrames
    /// 一次能处理的最大块（设备 buffer size 上限），默认 4096。
    public var maxBlockFrames: Int = 4096
    /// 输入槽位数（≤ 32）。
    public var maxInputs: Int = 32
    /// libsamplerate 转换器（SRC_SINC_*），默认 MEDIUM（97 dB SNR、90% 带宽；sinc 半长 46 帧）。
    public var resamplerConverter: Int32 = Int32(SRC_SINC_MEDIUM_QUALITY)
    /// 重采样器每次向环要的帧数（越小环占用越准），默认 32。
    public var resamplerChunkFrames: Int = 32
    /// 速率估计器参数。
    public var rate = RateEstimatorParameters()
    /// 响度读数更新间隔（ms），默认 100。
    public var meterIntervalMs: Int = 100
    /// host 时基（测试可伪造）。
    public var timebase: MachTimebase = HostClock.timebase
    public init() {}
}

/// 一路输入的统计（sw_input_stats 的 Swift 形态）。
public struct InputSlotStats: Hashable, Sendable {
    public var attached: Bool
    public var primed: Bool
    public var ratio: Double
    public var ratioFeedforward: Double
    public var ageFrames: Double
    public var ageSetpoint: Double
    public var occupancyFiltered: Double
    public var occupancyFrames: UInt64
    public var producerBlock: Int
    public var underrunBlocks: UInt64
    public var reprimes: UInt64
    public var framesConsumed: UInt64
    public var framesOutput: UInt64
    init(_ c: sw_input_stats) {
        attached = c.attached != 0; primed = c.primed != 0
        ratio = c.ratio; ratioFeedforward = c.ratio_feedforward
        ageFrames = c.age_frames; ageSetpoint = c.age_setpoint
        occupancyFiltered = c.occupancy_filtered; occupancyFrames = c.occupancy_frames
        producerBlock = Int(c.producer_block)
        underrunBlocks = c.underrun_blocks; reprimes = c.reprimes
        framesConsumed = c.frames_consumed; framesOutput = c.frames_output
    }
}

/// 混音器统计（sw_mix_stats 的 Swift 形态）。`audio` 就是 Stats.audio 那一节（铁律 4：只有这一份）。
public struct MixerStats: Hashable, Sendable {
    public var blocksRendered: UInt64
    public var framesRendered: UInt64
    /// 回调超时 + 设备 overload 通知。
    public var dropouts: UInt64
    /// 已就绪输入的环欠载块数之和。
    public var underruns: UInt64
    /// 实时守卫记到的违规。
    public var rtViolations: UInt64
    public var commandsApplied: UInt64
    public var commandsDropped: UInt64
    public var tapDrops: UInt64
    public var maxBlockTicks: UInt64
    public var lastBlockTicks: UInt64
    public var lastHostTime: HostTime
    public var lastBlockFrames: Int
    public var inputs: [InputSlotStats]
    /// 测试标准 §7 的 audio{dropouts, underruns}。
    public var audio: Stats.AudioCounters { Stats.AudioCounters(dropouts: dropouts, underruns: underruns) }
    init(_ c: sw_mix_stats) {
        blocksRendered = c.blocks_rendered; framesRendered = c.frames_rendered
        dropouts = c.dropouts; underruns = c.underruns; rtViolations = c.rt_violations
        commandsApplied = c.commands_applied; commandsDropped = c.commands_dropped; tapDrops = c.tap_drops
        maxBlockTicks = c.max_block_ticks; lastBlockTicks = c.last_block_ticks
        lastHostTime = HostTime(ticks: c.last_host_time); lastBlockFrames = Int(c.last_block_frames)
        var arr = [InputSlotStats]()
        let n = Int(c.input_count)
        withUnsafeBytes(of: c.input) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: sw_input_stats.self)
            for i in 0..<n { arr.append(InputSlotStats(p[i])) }
        }
        inputs = arr
    }
}

/// 一条总线的表读数。
public struct BusMeter: Hashable, Sendable {
    /// 本块采样峰值（线性）。
    public var peak: [Float]
    /// 本块真峰值（线性）。
    public var truePeak: [Float]
    public var peakMax: [Float]
    public var truePeakMax: [Float]
    public var momentaryLUFS: Double
    public var shortTermLUFS: Double
    public var integratedLUFS: Double
    public var loudnessRangeLU: Double
    /// dBTP。
    public var truePeakDb: [Double] { truePeak.map { 20 * log10(Double(max($0, 1e-12))) } }
    /// dBFS。
    public var peakDb: [Double] { peak.map { 20 * log10(Double(max($0, 1e-12))) } }
    init(_ c: sw_bus_meter) {
        peak = [c.peak.0, c.peak.1]; truePeak = [c.true_peak.0, c.true_peak.1]
        peakMax = [c.peak_max.0, c.peak_max.1]; truePeakMax = [c.true_peak_max.0, c.true_peak_max.1]
        momentaryLUFS = c.momentary_lufs; shortTermLUFS = c.short_term_lufs
        integratedLUFS = c.integrated_lufs; loudnessRangeLU = c.loudness_range_lu
    }
}

/// 一路输入的表读数（推子后采样峰值）。
public struct InputMeter: Hashable, Sendable {
    public var peak: [Float]
    public var peakMax: [Float]
    init(_ c: sw_input_meter) { peak = [c.peak.0, c.peak.1]; peakMax = [c.peak_max.0, c.peak_max.1] }
}

/// 表读数快照（UI 读这个）。
public struct MixerMeters: Hashable, Sendable {
    public var blockSequence: UInt64
    /// 顺序 = Bus.allCases。
    public var buses: [BusMeter]
    public var inputs: [InputMeter]
    public subscript(bus: Bus) -> BusMeter { buses[bus.rawValue] }
}

/// 消费者队列（编码 / 录制 / 表线程 / 测试从这里拿块）。生命周期由 AudioMixer 管理，remove 之后不要再用。
public final class AudioBlockTap: @unchecked Sendable {
    let queue: OpaquePointer
    public let source: TapSource
    public let channels: Int
    public let maxFrames: Int
    let index: Int
    init(queue: OpaquePointer, source: TapSource, channels: Int, maxFrames: Int, index: Int) {
        self.queue = queue; self.source = source; self.channels = channels; self.maxFrames = maxFrames; self.index = index
    }
    /// 等待中的块数。
    public var count: Int { Int(sw_block_queue_count(queue)) }
    /// 累计被丢的块数（消费者慢）。
    public var dropped: UInt64 { sw_block_queue_dropped(queue) }
    /// 弹一块（拷进 planes，每个平面至少 maxFrames 个 float）；空返回 nil。
    public func pop(into planes: UnsafePointer<UnsafeMutablePointer<Float>?>) -> (frames: Int, hostTime: HostTime, sequence: UInt64)? {
        var n: UInt32 = 0, t: UInt64 = 0, s: UInt64 = 0
        guard sw_block_queue_pop(queue, planes, &n, &t, &s) else { return nil }
        return (Int(n), HostTime(ticks: t), s)
    }
    /// 弹一块成数组。
    public func pop() -> (planes: [[Float]], hostTime: HostTime, sequence: UInt64)? {
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * channels)
        defer { storage.deallocate() }
        var ptrs: [UnsafeMutablePointer<Float>?] = (0..<channels).map { storage + $0 * maxFrames }
        guard let r = ptrs.withUnsafeMutableBufferPointer({ pop(into: UnsafePointer($0.baseAddress!)) }) else { return nil }
        let planes = (0..<channels).map { Array(UnsafeBufferPointer(start: storage + $0 * maxFrames, count: r.frames)) }
        return (planes, r.hostTime, r.sequence)
    }
}

/// 混音器：一个 sw_mix_ctx 的拥有者与控制面。
public final class AudioMixer: @unchecked Sendable {
    /// C 上下文（驱动层把它交给 IOProc）。
    public let context: OpaquePointer
    public let configuration: AudioMixerConfiguration
    /// 每帧 host tick。
    public let hostTicksPerFrame: Double
    private let lock = NSLock()
    private var rings: [Int: any AudioRing] = [:]
    private var pendingRelease: [(sequence: UInt64, ring: any AudioRing)] = []
    private var taps: [Int: AudioBlockTap] = [:]
    private var pendingTapRelease: [(sequence: UInt64, tap: AudioBlockTap)] = []
    /// 12 格效果的 AU 包装（下标 = 总线 × 3 + 格）。
    var effectUnitsStorage: [Int: EffectUnit] = [:]
    /// 命令入队失败（队列满）的次数。
    public private(set) var commandsDropped: UInt64 = 0

    public init(configuration: AudioMixerConfiguration = AudioMixerConfiguration()) {
        let tb = configuration.timebase
        let tpf = Double(tb.denom) * 1e9 / (Double(tb.numer) * Double(AudioFormat.sampleRate))
        var c = sw_mix_ctx_config_default(tpf)
        c.max_block_frames = UInt32(configuration.maxBlockFrames)
        c.max_inputs = UInt32(configuration.maxInputs)
        c.default_block_frames = UInt32(configuration.blockFrames)
        c.resampler_converter = configuration.resamplerConverter
        c.resampler_chunk_frames = UInt32(configuration.resamplerChunkFrames)
        c.rate = configuration.rate.cValue(blockFrames: configuration.blockFrames)
        c.meter_interval_ms = UInt32(configuration.meterIntervalMs)
        guard let ctx = sw_mix_ctx_create(&c) else { fatalError("sw_mix_ctx_create 失败（内存不足）") }
        context = ctx
        self.configuration = configuration
        hostTicksPerFrame = tpf
    }

    deinit {
        // 先摘效果（AU 在上下文之后销毁也行，但顺序清楚些），再销毁上下文
        for (_, eu) in effectUnitsStorage { sw_mix_ctx_remove_effect(context, UInt32(eu.bus.rawValue), UInt32(eu.effect.rawValue)) }
        effectUnitsStorage.removeAll()
        sw_mix_ctx_destroy(context)
        for (_, tap) in taps { sw_block_queue_destroy(tap.queue) }
        for p in pendingTapRelease { sw_block_queue_destroy(p.tap.queue) }
    }

    /// 输入槽位数。
    public var inputCapacity: Int { Int(sw_mix_ctx_input_capacity(context)) }
    /// 最大块。
    public var maxBlockFrames: Int { Int(sw_mix_ctx_max_block_frames(context)) }
    /// 重采样器需要预先看到的帧数（sinc 半长）。
    public var resamplerLookaheadFrames: Int { Int(sw_mix_ctx_resampler_latency_frames(context)) }

    // MARK: 命令

    @discardableResult
    private func push(_ cmd: sw_cmd) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        reapLocked()
        var c = cmd
        // 队列满（实时线程慢或没在跑）：等最多 200 ms
        var attempts = 0
        while !sw_mix_ctx_push_command(context, &c) {
            attempts += 1
            if attempts > 200 { commandsDropped += 1; return sw_mix_ctx_commands_pushed(context) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return sw_mix_ctx_commands_pushed(context)
    }

    private func cmd(_ type: sw_cmd_type, index: Int = 0, i0: Int32 = 0, i1: Int32 = 0, i2: Int32 = 0, f0: Float = 0,
                     u0: UInt64 = 0, ptr: UnsafeMutableRawPointer? = nil) -> sw_cmd {
        var c = sw_cmd()
        c.type = UInt32(type.rawValue); c.index = Int32(index); c.i0 = i0; c.i1 = i1; c.i2 = i2; c.f0 = f0; c.u0 = u0; c.ptr = ptr
        return c
    }

    /// 已入队 / 已应用的命令数。
    public var commandsPushed: UInt64 { lock.lock(); defer { lock.unlock() }; return sw_mix_ctx_commands_pushed(context) }
    public var commandsApplied: UInt64 { sw_mix_ctx_commands_applied(context) }

    /// 等实时线程把已入队的命令全部应用（超时返回 false；上下文没人驱动时必然超时）。
    @discardableResult
    public func waitForCommands(timeout: TimeInterval = 1.0) -> Bool {
        let target = commandsPushed
        let deadline = Date().addingTimeInterval(timeout)
        while commandsApplied < target {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.0005)
        }
        lock.lock(); reapLocked(); lock.unlock()
        return true
    }

    private func reapLocked() {
        let applied = sw_mix_ctx_commands_applied(context)
        pendingRelease.removeAll { $0.sequence <= applied }
        let done = pendingTapRelease.filter { $0.sequence <= applied }
        for p in done { sw_block_queue_destroy(p.tap.queue) }
        pendingTapRelease.removeAll { $0.sequence <= applied }
    }

    // MARK: 输入

    /// 把一路输入的环挂到槽位。槽位空闲时才能挂（同一槽位先 detach）。
    /// - Parameters:
    ///   - targetFrames: 估计器设定点（环里平均保有帧数；0 = 2 块）。
    ///   - targetAgeFrames: 就绪目标年龄（帧；W1-D2）：就绪时从"块首 host time − 目标年龄"那一刻采到的帧起消费，
    ///     `InputSlotStats.ageSetpoint` 就等于它（± 半帧），与生产者相位无关；0 = 旧规则（年龄 = back + 相位 [0, P)）。
    ///     任何相位都能命中的最小值见 `deterministicAgeFrames`；更小的目标在相位不利时按安全下限就绪（年龄 > 目标）。
    public func attach(ring: any AudioRing, toSlot slot: Int, resampling: ResampleMode = .estimated, targetFrames: Int = 0, targetAgeFrames: Int = 0) {
        precondition((0..<inputCapacity).contains(slot), "槽位越界")
        lock.lock()
        precondition(rings[slot] == nil, "槽位 \(slot) 已有输入，先 detach")
        rings[slot] = ring
        sw_mix_ctx_prepare_slot(context, UInt32(slot))
        lock.unlock()
        push(cmd(SW_CMD_ATTACH_INPUT, index: slot, i0: resampling.rawValue, i1: Int32(targetFrames), i2: Int32(max(0, targetAgeFrames)),
                 ptr: UnsafeMutableRawPointer(ring.raw)))
    }

    /// 指定目标年龄时任何生产者相位都能精确命中的最小年龄（帧）= back（target + P/2 + hf + chunk/2）+ 生产者块 P；
    /// 默认参数（target 2 块、P 256、重采样）= 959 帧 ≈ 20 ms。bypass（与输出同时钟）的输入没有 hf + chunk/2。
    public func deterministicAgeFrames(targetFrames: Int, producerBlockFrames: Int, resampled: Bool = true) -> Int {
        Int(sw_mix_ctx_deterministic_age_frames(context, UInt32(max(0, targetFrames)), UInt32(max(0, producerBlockFrames)), resampled))
    }

    /// 摘掉槽位上的输入。环对象在实时线程确认之后才释放（这里只入队）。
    public func detach(slot: Int) {
        lock.lock()
        let ring = rings.removeValue(forKey: slot)
        lock.unlock()
        let seq = push(cmd(SW_CMD_DETACH_INPUT, index: slot))
        if let ring {
            lock.lock(); pendingRelease.append((seq, ring)); lock.unlock()
        }
    }

    /// 槽位上的环。
    public func ring(atSlot slot: Int) -> (any AudioRing)? { lock.lock(); defer { lock.unlock() }; return rings[slot] }

    public func setGain(slot: Int, linear: Float) { push(cmd(SW_CMD_INPUT_GAIN, index: slot, f0: linear)) }
    public func setGain(slot: Int, dB: Double) { setGain(slot: slot, linear: Float(pow(10, dB / 20))) }
    public func setMuted(slot: Int, _ muted: Bool) { push(cmd(SW_CMD_INPUT_MUTE, index: slot, i0: muted ? 1 : 0)) }
    public func setSolo(slot: Int, _ solo: Bool) { push(cmd(SW_CMD_INPUT_SOLO, index: slot, i0: solo ? 1 : 0)) }
    public func setPan(slot: Int, _ pan: Double) { push(cmd(SW_CMD_INPUT_PAN, index: slot, f0: Float(pan))) }
    public func setRouting(slot: Int, _ routing: BusRouting) {
        var bits: Int32 = 0
        if routing.master { bits |= Int32(SW_ROUTE_MASTER.rawValue) }
        if routing.busA { bits |= Int32(SW_ROUTE_A.rawValue) }
        if routing.busB { bits |= Int32(SW_ROUTE_B.rawValue) }
        if routing.headphones { bits |= Int32(SW_ROUTE_HEADPHONES.rawValue) }
        push(cmd(SW_CMD_INPUT_ROUTING, index: slot, i0: bits))
    }
    /// 延迟补偿（帧）。
    public func setDelay(slot: Int, frames: Int) { push(cmd(SW_CMD_INPUT_DELAY, index: slot, i0: Int32(max(0, frames)))) }
    /// 延迟补偿（ms，0–500）。
    public func setDelay(slot: Int, milliseconds: Double) {
        setDelay(slot: slot, frames: Int((milliseconds * Double(AudioFormat.sampleRate) / 1000).rounded()))
    }
    /// 直接设 AFV 增益（0…1，平滑到位；取消该槽位进行中的淡变）。
    public func setAFVGain(slot: Int, _ gain: Float) { push(cmd(SW_CMD_INPUT_AFV_GAIN, index: slot, f0: gain)) }
    public func setResampleMode(slot: Int, _ mode: ResampleMode) { push(cmd(SW_CMD_INPUT_RESAMPLE, index: slot, i0: mode.rawValue)) }

    /// 一次性应用契约里的每路音频参数（增益 / 静音 / 独听 / 声像 / 路由 / 延迟）。
    public func apply(_ s: InputAudioSettings, toSlot slot: Int) {
        setGain(slot: slot, dB: s.gainDb)
        setMuted(slot: slot, s.muted)
        setSolo(slot: slot, s.solo)
        setPan(slot: slot, s.pan)
        setRouting(slot: slot, s.routing)
        setDelay(slot: slot, milliseconds: Double(s.delayMs))
    }

    // MARK: 总线

    public func setBusGain(_ bus: Bus, linear: Float) { push(cmd(SW_CMD_BUS_GAIN, index: bus.rawValue, f0: linear)) }
    public func setBusGain(_ bus: Bus, dB: Double) { setBusGain(bus, linear: Float(pow(10, dB / 20))) }
    public func setBusMuted(_ bus: Bus, _ muted: Bool) { push(cmd(SW_CMD_BUS_MUTE, index: bus.rawValue, i0: muted ? 1 : 0)) }
    public func setEffectEnabled(_ bus: Bus, _ effect: BusEffect, _ on: Bool) {
        push(cmd(SW_CMD_EFFECT_ENABLE, index: bus.rawValue, i0: effect.rawValue, i1: on ? 1 : 0))
    }
    public func setMonitorMode(_ mode: MonitorMode) { push(cmd(SW_CMD_MONITOR_MODE, i0: mode == .pfl ? 1 : 0)) }
    /// 耳机总线取每路输入延迟线前（默认，低延迟监听）还是延迟线后（与节目同刻）的信号。W1-D2。
    public func setMonitorPoint(_ point: MonitorPoint) { push(cmd(SW_CMD_MONITOR_POINT, i0: point.rawValue)) }

    // MARK: AFV

    /// 等幅交叉淡变（设计方案 §7 AFV；W2-E 接到转场）：`from` 的 AFV 增益 1 → 0、`to` 的 0 → 1，
    /// 曲线 cos / sin（中点各 −3 dB），起点 = 首样本 host time ≥ startHostTime 的那一块里按样本定位，
    /// 长度 durationFrames 帧（样本精确，不按块取整；W1-D2 前只收块数），走满那一刻起 from 严格 0、to 严格 1。
    /// 迟到时跳到该在的位置，终点仍与视频对齐。任一方可为 nil。
    public func crossfade(from: Int?, to: Int?, durationFrames: Int, startHostTime: HostTime) {
        push(cmd(SW_CMD_CROSSFADE, i0: from.map(Int32.init) ?? -1, i1: to.map(Int32.init) ?? -1,
                 i2: Int32(max(1, durationFrames)), u0: startHostTime.ticks))
    }
    /// 便利写法：durationBlocks × 名义块（`configuration.blockFrames`）。
    public func crossfade(from: Int?, to: Int?, durationBlocks: Int, startHostTime: HostTime) {
        crossfade(from: from, to: to, durationFrames: max(1, durationBlocks) * configuration.blockFrames, startHostTime: startHostTime)
    }

    // MARK: 消费者队列

    /// 加一个消费者队列。capacityBlocks 块（默认 64 ≈ 340 ms @ 256），满了实时线程丢块并计 tapDrops。
    public func addTap(source: TapSource, capacityBlocks: Int = 64) -> AudioBlockTap? {
        lock.lock()
        guard let index = (0..<Int(SW_MIX_MAX_TAPS)).first(where: { i in taps[i] == nil && !pendingTapRelease.contains { p in p.tap.index == i } }) else {
            lock.unlock(); return nil
        }
        guard let q = sw_block_queue_create(UInt32(capacityBlocks), UInt32(SW_MIX_BUS_CHANNELS), UInt32(maxBlockFrames)) else {
            lock.unlock(); return nil
        }
        let tap = AudioBlockTap(queue: q, source: source, channels: Int(SW_MIX_BUS_CHANNELS), maxFrames: maxBlockFrames, index: index)
        taps[index] = tap
        lock.unlock()
        push(cmd(SW_CMD_TAP_ATTACH, index: index, i0: source.cValue, ptr: UnsafeMutableRawPointer(q)))
        return tap
    }

    /// 移除消费者队列（实时线程确认之后才释放内存）。
    public func removeTap(_ tap: AudioBlockTap) {
        lock.lock()
        guard taps[tap.index] === tap else { lock.unlock(); return }
        taps.removeValue(forKey: tap.index)
        lock.unlock()
        let seq = push(cmd(SW_CMD_TAP_DETACH, index: tap.index))
        lock.lock(); pendingTapRelease.append((seq, tap)); lock.unlock()
    }

    // MARK: 效果

    /// 装一个已配置（格式、MaximumFramesPerSlice）但尚未 initialize 的 AudioUnit 到总线某格；本函数装上输入回调。
    /// 调用方随后 AudioUnitInitialize。运行期不改拓扑：只在实时线程未跑或该格关闭时装。
    public func installEffect(_ bus: Bus, _ effect: BusEffect, unit: AudioUnit) -> OSStatus {
        OSStatus(sw_mix_ctx_install_effect(context, UInt32(bus.rawValue), UInt32(effect.rawValue), UnsafeMutableRawPointer(unit)))
    }
    public func removeEffect(_ bus: Bus, _ effect: BusEffect) { sw_mix_ctx_remove_effect(context, UInt32(bus.rawValue), UInt32(effect.rawValue)) }

    // MARK: 统计与表

    /// 统计快照。
    public var stats: MixerStats {
        var s = sw_mix_stats()
        sw_mix_ctx_copy_stats(context, &s)
        return MixerStats(s)
    }
    /// 测试标准 §7 的 audio{dropouts, underruns}。
    public var audioCounters: Stats.AudioCounters { stats.audio }
    /// 表读数快照。
    public var meters: MixerMeters {
        var m = sw_mix_meters()
        sw_mix_ctx_copy_meters(context, &m)
        var buses = [BusMeter]()
        withUnsafeBytes(of: m.bus) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: sw_bus_meter.self)
            for b in 0..<Int(SW_MIX_BUS_COUNT) { buses.append(BusMeter(p[b])) }
        }
        var inputs = [InputMeter]()
        let n = inputCapacity
        withUnsafeBytes(of: m.input) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: sw_input_meter.self)
            for i in 0..<n { inputs.append(InputMeter(p[i])) }
        }
        return MixerMeters(blockSequence: m.block_sequence, buses: buses, inputs: inputs)
    }
    /// 清峰值保持。
    public func resetMeters() { push(cmd(SW_CMD_RESET_METERS)) }
    /// 清计数（dropouts / underruns / 违规 / tapDrops）。
    public func resetStats() { push(cmd(SW_CMD_RESET_STATS)) }
    /// 是否用真实时钟检查块超时（实时驱动开，离线关）。
    public func setTimingCheck(_ on: Bool) { sw_mix_ctx_set_timing_check(context, on) }

    // MARK: 渲染入口（给 Swift 驱动用；C 驱动直接调 sw_mix_block）

    /// 混一块。`out` 是 8 个平面：[Master L, R, A L, R, B L, R, HP L, R]，nil 的不写。只能由驱动线程调用。
    public func render(into out: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int, hostTime: HostTime) {
        sw_mix_block(context, out, UInt32(frames), hostTime.ticks)
    }
}
