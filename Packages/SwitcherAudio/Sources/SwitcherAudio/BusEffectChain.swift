// BusEffectChain.swift —— 总线效果链：苹果自带 AudioUnit（NBandEQ、DynamicsProcessor、PeakLimiter）的搭建（非实时）。
//
// 设计方案 §7 / §12 决策 5：效果用苹果 AU，在我们自己的混音线程里 AudioUnitRender；预先 initialize，运行期不改拓扑。
// 这里只做创建 / 配格式 / 装回调 / initialize / 调参；渲染在 sw_mix.c（sw_process_bus）。
// C 混音器每条总线有三个格，按格号 0 → 1 → 2 处理；格本身不认 AU 的种类，装哪种 AU、装在哪一格由集成层按效果链定（W5-C）。
// `BusEffect` 的三个名字是格号的默认布局（W1-D：EQ 0 / 压缩 1 / 限幅 2），`installStandardEffects` 按它装。
// W5-C 起 EQ 格默认是 AUNBandEQ：一个格固定建 16 段（MaxNumberOfBands），契约里连续的 parametricEQ 格映射成它的各段，
// 段数增减只改段的旁路参数、不动拓扑。探针结论见 reports/w5-audio-bus-effects.md §1。
// AudioUnitRender 在自有线程调用的注意事项（写进报告）：
//   1. 输入靠 kAudioUnitProperty_SetRenderCallback（C 函数 sw_effect_input_proc），AU 在 AudioUnitRender 内同步回调，同一线程；
//      W5-C 探针：四种 AU 都可以先 initialize 再装回调——准备好的 AU 等格关掉、实时线程确认之后再挂进去（makeEffectUnit + attachEffectUnit）；
//   2. 输入 / 输出 StreamFormat 都要设成 48 kHz float32 非交错 2 声道，MaximumFramesPerSlice ≥ 一次 render 的帧数；
//   3. AudioTimeStamp 至少带 mSampleTime（kAudioTimeStampSampleTimeValid），每块递增；
//   4. 不能与 AudioUnitUninitialize / 设置属性并发；参数（AudioUnitSetParameter）可以在别的线程改，AU 内部会平滑；
//   5. 前瞻延迟（kAudioUnitProperty_Latency）：NBandEQ 0、DynamicsProcessor 恒 256 帧、PeakLimiter = 起音时间（默认 12 ms = 576 帧），
//      运行中改起音属性立刻变；集成层按它补 A/V 对齐（W5-C）；
//   6. AU 不钳参数：超范围的值照收（限幅器起音 0.05 s → 延迟 2400 帧），送进去之前先钳到 EffectParameterRanges。
import Foundation
import AudioToolbox
import SwitcherContracts
import CSwitcherAudioRT
import CSwitcherAudioHost

/// 一格里装的 AU 种类（W5-C）。
public enum EffectKind: String, Hashable, Sendable, CaseIterable {
    /// AUNBandEQ：一个格 `EffectParameterRanges.nBandEQMaxBands` 段参数式 EQ（W5-C 起 EQ 格的默认）。
    case nBandEQ
    /// AUParametricEQ：单段（W1-D 的 EQ 格；它的 Q 不是经典口径，见报告 §1，只留作对照）。
    case parametricEQ
    case dynamicsProcessor
    case peakLimiter
    /// 自写 C 压缩器（提案 024 (b)，W1-D3）：不是 AudioUnit，格的 kind = `EffectSlotKind.compressor`；与 dynamicsProcessor 二选一占同一格。
    case compressor

    /// 对应的苹果 AU 子类型；压缩器不是 AU → nil。
    var subtype: OSType? {
        switch self {
        case .nBandEQ: kAudioUnitSubType_NBandEQ
        case .parametricEQ: kAudioUnitSubType_ParametricEQ
        case .dynamicsProcessor: kAudioUnitSubType_DynamicsProcessor
        case .peakLimiter: kAudioUnitSubType_PeakLimiter
        case .compressor: nil
        }
    }
}

extension BusEffect {
    /// 格号 0 / 1 / 2（处理顺序）。
    public var slot: Int { Int(rawValue) }
    /// 按格号取（0…2）。
    public init(slot: Int) {
        precondition((0..<BusEffect.allCases.count).contains(slot), "总线只有三格")
        self = BusEffect(rawValue: Int32(slot))!
    }
}

/// 送进 AU 之前的参数范围（W5-C 探针，reports/w5-audio-bus-effects.md §1 的钳位表），键 = 契约 `EffectSlot` 的 id / 参数键（docs/CONTRACTS.md §2.4）。
/// 取 SDK 头文件 AudioUnitParameters.h 写的范围 ∩ macOS 27 上 ParameterInfo 报的范围：最低支持 macOS 15，只用两边都认的那一段
/// （DynamicsProcessor 阈值 27 上报 −100…20、头文件写 −40…20 → 取 −40；PeakLimiter 衰减头文件 0.06、27 上报 0.04 → 取 0.04）。
/// AU 自己不钳，所以集成层一律先钳到这里再设，App 的滑块范围也收在这里面（App/Tests/AudioEffectsTests 钉住）。
public enum EffectParameterRanges {
    /// 一个 AUNBandEQ 格的段数（探针：MaxNumberOfBands = 16）。
    public static let nBandEQMaxBands = 16

    /// 契约 `parametricEQ.q` → AUNBandEQ 的带宽（倍频程）。q 用经典口径：带宽 = 增益为峰值一半（dB）处的上下边频之比，
    /// BW = 2/ln2 · asinh(1/(2q))（q = √2 → 1 oct，q = 4.32 → 1/3 oct）。AUNBandEQ 的带宽参数就是这个定义（探针实测与设定一致、与增益无关）。
    public static func eqBandwidthOctaves(q: Double) -> Double { 2 / log(2) * asinh(1 / (2 * q)) }
    /// 带宽（倍频程）→ q。
    public static func eqQ(bandwidthOctaves bw: Double) -> Double { 1 / (2 * sinh(log(2) / 2 * bw)) }

    public static let table: [String: [String: ClosedRange<Double>]] = [
        "parametricEQ": [
            "centerHz": 20...23_520,                                              // 头文件 20…SR/2，27 上报 10…23520
            "q": eqQ(bandwidthOctaves: 5)...eqQ(bandwidthOctaves: 0.05),          // 带宽 0.05…5 oct → q 0.1826…28.85
            "gainDb": -96...24,
        ],
        "dynamicsProcessor": [
            "thresholdDb": -40...20,                                              // 27 上报 −100…20（−60 实测也生效），头文件 −40…20
            "headroomDb": 0.1...40,
            "expansionRatio": 1...50,
            "attackSeconds": 0.001...0.2,                                         // 头文件 0.0001…0.2，27 上报 0.001…0.3
            "releaseSeconds": 0.01...3,
            "overallGainDb": -40...40,
        ],
        "peakLimiter": [
            "attackSeconds": 0.001...0.03,                                        // 头文件 0.001…0.03，27 上报 0.0005…0.03
            "decaySeconds": 0.001...0.04,                                         // 头文件 0.001…0.06，27 上报 0.001…0.04
            "preGainDb": -40...40,
            "ceilingDb": -20...0,                                                 // 024 顺带 (2)：同一格内限幅之后的输出增益（契约定的范围，不是 AU 参数）
        ],
        // 自写压缩器（提案 024 (b)，契约 docs/CONTRACTS.md §2.4 定的范围；不是 AU，范围就是算法接受的范围）
        "compressor": [
            "thresholdDb": -60...0,
            "ratio": 1...20,
            "kneeDb": 0...24,
            "attackSeconds": 0.0001...0.2,
            "releaseSeconds": 0.01...3,
            "makeupGainDb": 0...24,
        ],
    ]

    /// 某个参数的范围；认不出的 id / 键给 nil。
    public static func range(effect: String, key: String) -> ClosedRange<Double>? { table[effect]?[key] }

    /// 钳到范围（认不出的原样）。NaN 当越界，给下限。
    public static func clamp(_ value: Double, effect: String, key: String) -> (value: Double, clamped: Bool) {
        guard let r = range(effect: effect, key: key) else { return (value, false) }
        if value.isNaN { return (r.lowerBound, true) }
        let c = min(max(value, r.lowerBound), r.upperBound)
        return (c, c != value)
    }

    fileprivate static func clampF(_ v: Float, _ effect: String, _ key: String) -> Float { Float(clamp(Double(v), effect: effect, key: key).value) }
}

/// 一格效果的 AudioUnit 包装。只在控制线程（或实时线程没在跑时）上调。
public final class EffectUnit: @unchecked Sendable {
    /// 装在哪里（总线某格 / 某路输入某格；`makeEffectUnit` 时定，`attachEffectUnit` 照它装）。W1-D3。
    public let location: EffectLocation
    /// AU 种类。
    public let kind: EffectKind
    public let unit: AudioUnit
    /// NBandEQ 的段数（其他种类 1）。
    public let bandCount: Int
    public private(set) var initialized = false
    /// 上次设过的参数值：同值不重设（推子拖动时一条链整条重发，大部分参数没变）。
    private var lastValues: [AudioUnitParameterID: Float] = [:]

    init(location: EffectLocation, kind: EffectKind, unit: AudioUnit, bandCount: Int) {
        self.location = location; self.kind = kind; self.unit = unit; self.bandCount = bandCount
    }

    /// 总线格的 AU：哪条总线（输入格的 AU 调它是编程错误）。
    public var bus: Bus {
        guard case .bus(let b, _) = location else { preconditionFailure("输入格的 AU 没有总线：\(location)") }
        return b
    }
    /// 总线格的 AU：格号。
    public var effect: BusEffect {
        guard case .bus(_, let e) = location else { preconditionFailure("输入格的 AU 没有总线格号：\(location)") }
        return e
    }

    deinit {
        if initialized { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
    }

    /// 格号 0…2。
    public var slot: Int { effect.slot }

    /// 设参数（全局 scope）。同值不重设。
    @discardableResult
    public func setParameter(_ id: AudioUnitParameterID, _ value: Float) -> OSStatus {
        if lastValues[id] == value { return noErr }
        let st = AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
        if st == noErr { lastValues[id] = value }
        return st
    }
    /// 读参数。
    public func parameter(_ id: AudioUnitParameterID) -> Float? {
        var v: AudioUnitParameterValue = 0
        return AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &v) == noErr ? v : nil
    }
    /// 参数信息（范围、默认值；探针回归用）。
    public func parameterInfo(_ id: AudioUnitParameterID) -> AudioUnitParameterInfo? {
        var info = AudioUnitParameterInfo()
        var size = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
        return AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &size) == noErr ? info : nil
    }
    /// 延迟（秒），来自 kAudioUnitProperty_Latency。
    public var latencySeconds: Double {
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &v, &size) == noErr ? v : 0
    }
    /// 延迟（帧，48 kHz）。
    public var latencyFrames: Int { Int((latencySeconds * Double(AudioFormat.sampleRate)).rounded()) }
    /// 尾巴（秒，kAudioUnitProperty_TailTime）：输入停了之后还会响多久——不是延迟，不进 A/V 对齐（报告 §1）。
    public var tailSeconds: Double {
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioUnitGetProperty(unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &v, &size) == noErr ? v : 0
    }
    /// 清内部状态（滤波器记忆、前瞻缓冲、包络）。只在实时线程不会 render 它的时候调：格关着且关格命令已被确认，或还没挂上。
    public func reset() { AudioUnitReset(unit, kAudioUnitScope_Global, 0) }

    fileprivate func markInitialized() { initialized = true }
}

/// 效果链搭建错误。
public enum EffectChainError: Error, CustomStringConvertible {
    case componentNotFound(EffectKind)
    case osStatus(String, OSStatus)
    /// 这种效果不是 AudioUnit（自写压缩器走 `setEffectKind(.compressor)`，不建 AU）。
    case notAnAudioUnit(EffectKind)
    public var description: String {
        switch self {
        case .componentNotFound(let e): "找不到 AudioUnit：\(e)"
        case .osStatus(let what, let st): "\(what) 失败：OSStatus \(st)"
        case .notAnAudioUnit(let e): "\(e) 不是 AudioUnit，不能建实例"
        }
    }
}

extension AudioMixer {
    /// 48 kHz float32 非交错 2 声道。
    static var busStreamFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: Float64(AudioFormat.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    /// 格号的默认 AU 种类（W1-D 的布局，W5-C 起 EQ 格是 NBandEQ）。
    public static func defaultEffectKind(for slot: BusEffect) -> EffectKind {
        switch slot {
        case .parametricEQ: .nBandEQ
        case .dynamicsProcessor: .dynamicsProcessor
        case .peakLimiter: .peakLimiter
        }
    }

    /// 建一个 AU 并 initialize，但不挂进混音器（W5-C：准备好再换格，换格那一格旁路的时间里不做实例化）。
    /// NBandEQ 固定建 16 段、全部旁路、类型参数式（0）；其他种类用 AU 默认参数，调用方随后设参数。
    public func makeEffectUnit(_ kind: EffectKind, bus: Bus, slot: BusEffect) throws -> EffectUnit {
        try makeEffectUnit(kind, at: .bus(bus, slot))
    }

    /// 同上，位置可以是输入格（W1-D3）。自写压缩器不是 AU（`EffectChainError.notAnAudioUnit`）。
    public func makeEffectUnit(_ kind: EffectKind, at location: EffectLocation) throws -> EffectUnit {
        guard let subtype = kind.subtype else { throw EffectChainError.notAnAudioUnit(kind) }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EffectChainError.componentNotFound(kind) }
        var instance: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &instance)
        guard st == noErr, let unit = instance else { throw EffectChainError.osStatus("AudioComponentInstanceNew", st) }
        let bands = kind == .nBandEQ ? EffectParameterRanges.nBandEQMaxBands : 1
        let eu = EffectUnit(location: location, kind: kind, unit: unit, bandCount: bands)
        var fmt = AudioMixer.busStreamFormat
        let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fmtSize)
        guard st == noErr else { throw EffectChainError.osStatus("StreamFormat(input)", st) }
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, fmtSize)
        guard st == noErr else { throw EffectChainError.osStatus("StreamFormat(output)", st) }
        var maxFrames = UInt32(maxBlockFrames)
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        guard st == noErr else { throw EffectChainError.osStatus("MaximumFramesPerSlice", st) }
        if kind == .nBandEQ {
            // 段数只能在未初始化时设（头文件；27 上初始化后设也返回 0，不依赖）
            var n = UInt32(bands)
            st = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &n, UInt32(MemoryLayout<UInt32>.size))
            guard st == noErr else { throw EffectChainError.osStatus("NBandEQ NumberOfBands", st) }
        }
        st = AudioUnitInitialize(unit)
        guard st == noErr else { throw EffectChainError.osStatus("AudioUnitInitialize", st) }
        eu.markInitialized()
        if kind == .nBandEQ {
            for b in 0..<bands {
                // 类型 0 = Parametric（kAUNBandEQFilterType_* 这组常量在头文件里标了弃用，参数本身没有，这里写字面量）
                eu.setParameter(kAUNBandEQParam_FilterType + AudioUnitParameterID(b), 0)
            }
            eu.bypassEQBands(from: 0)
        }
        return eu
    }

    /// 把 `makeEffectUnit` 建好的 AU 挂进它的格（装输入回调 + 换指针），原来那格的 AU 卸下销毁。
    /// 前提（调用方保证）：这一格是关着的，并且关格命令已被实时线程应用（`commandsApplied` ≥ 关格时的 `commandsPushed`），
    /// 或者实时线程没在跑——否则实时线程可能正 render 旧 AU。
    public func attachEffectUnit(_ eu: EffectUnit) throws {
        let st = installEffect(at: eu.location, unit: eu.unit)
        guard st == noErr else { throw EffectChainError.osStatus("SetRenderCallback", st) }
        storeEffectUnit(eu)
    }

    /// 装一个已配置的 AudioUnit 到某格（总线或输入；W1-D3）；本函数装上输入回调。前提同 `attachEffectUnit`。
    public func installEffect(at location: EffectLocation, unit: AudioUnit) -> OSStatus {
        OSStatus(sw_mix_ctx_install_effect_at(context, UInt32(location.cTarget), UInt32(location.cIndex), UInt32(location.cSlot), UnsafeMutableRawPointer(unit)))
    }

    /// 为某格（总线或输入）建并 initialize 指定种类的 AU，装到混音上下文；已装过的先卸下重建。只能在实时线程未跑、或该格关闭且已确认时调。
    @discardableResult
    public func installEffect(at location: EffectLocation, kind: EffectKind) throws -> EffectUnit {
        let eu = try makeEffectUnit(kind, at: location)
        removeEffectUnit(at: location)
        try attachEffectUnit(eu)
        return eu
    }

    /// 为一条总线的一格创建并 initialize 该格默认种类的 AU（EQ 格 = NBandEQ），装到混音上下文。已装过的先卸下重建。
    /// 只能在实时线程未跑、或该格处于关闭状态时调（运行期不改拓扑）。
    @discardableResult
    public func installEffect(_ bus: Bus, _ effect: BusEffect) throws -> EffectUnit {
        try installEffect(bus, effect, kind: AudioMixer.defaultEffectKind(for: effect))
    }

    /// 同上，指定 AU 种类。
    @discardableResult
    public func installEffect(_ bus: Bus, _ effect: BusEffect, kind: EffectKind) throws -> EffectUnit {
        try installEffect(at: .bus(bus, effect), kind: kind)
    }

    /// 四条总线 × 三格全部建好（默认布局；都处于关闭 / 旁路状态，开关用 setEffectEnabled）。
    public func installStandardEffects() throws {
        for bus in Bus.allCases { for e in BusEffect.allCases { try installEffect(bus, e) } }
    }

    /// 某总线格的 AU 包装。
    public func effectUnit(_ bus: Bus, _ effect: BusEffect) -> EffectUnit? { effectUnit(.bus(bus, effect)) }
    /// 某格（总线 / 输入）的 AU 包装。
    public func effectUnit(_ location: EffectLocation) -> EffectUnit? { effectUnitsStorage[location] }

    /// 卸下并销毁某总线格（先在上下文里摘掉，实时线程不再 render 它）。前提同 attachEffectUnit。
    public func removeEffectUnit(_ bus: Bus, _ effect: BusEffect) { removeEffectUnit(at: .bus(bus, effect)) }
    /// 卸下并销毁某格（总线 / 输入）。前提同 attachEffectUnit。
    public func removeEffectUnit(at location: EffectLocation) {
        sw_mix_ctx_remove_effect_at(context, UInt32(location.cTarget), UInt32(location.cIndex), UInt32(location.cSlot))
        effectUnitsStorage[location] = nil
    }

    private func storeEffectUnit(_ eu: EffectUnit) { effectUnitsStorage[eu.location] = eu }
}

// MARK: - 常用参数的类型化入口（值先钳到 EffectParameterRanges）

extension EffectUnit {
    /// NBandEQ 的第 band 段（0 起）：中心频率（Hz）、q（契约口径，换成带宽倍频程）、增益（dB）、开关（关 = 这一段旁路）。
    /// ParametricEQ 只有一段（band 0）：直接设它自己的 Q（AU 自己的口径），关 = 增益 0。
    public func setEQBand(_ band: Int, centerHz: Float, q: Float, gainDb: Float, enabled: Bool = true) {
        let f = EffectParameterRanges.clampF(centerHz, "parametricEQ", "centerHz")
        let qq = EffectParameterRanges.clampF(q, "parametricEQ", "q")
        let g = EffectParameterRanges.clampF(gainDb, "parametricEQ", "gainDb")
        switch kind {
        case .nBandEQ:
            guard band >= 0, band < bandCount else { return }
            let b = AudioUnitParameterID(band)
            let bw = Float(min(max(EffectParameterRanges.eqBandwidthOctaves(q: Double(qq)), 0.05), 5))
            setParameter(kAUNBandEQParam_Frequency + b, f)
            setParameter(kAUNBandEQParam_Bandwidth + b, bw)
            setParameter(kAUNBandEQParam_Gain + b, g)
            setParameter(kAUNBandEQParam_BypassBand + b, enabled ? 0 : 1)
        case .parametricEQ:
            guard band == 0 else { return }
            setParameter(kParametricEQParam_CenterFreq, f)
            setParameter(kParametricEQParam_Q, min(max(q, 0.1), 20))
            setParameter(kParametricEQParam_Gain, enabled ? min(max(gainDb, -20), 20) : 0)
        case .dynamicsProcessor, .peakLimiter, .compressor:
            return
        }
    }

    /// NBandEQ：第 band 段起全部旁路（没用到的段）。
    public func bypassEQBands(from band: Int) {
        guard kind == .nBandEQ else { return }
        for b in max(0, band)..<bandCount { setParameter(kAUNBandEQParam_BypassBand + AudioUnitParameterID(b), 1) }
    }

    /// 单段 EQ：中心频率（Hz）、Q、增益（dB）。NBandEQ 设第 0 段（W1-D 的接口，W5-C 换单元后语义不变）。
    public func setParametricEQ(centerHz: Float, q: Float, gainDb: Float) {
        setEQBand(0, centerHz: centerHz, q: q, gainDb: gainDb, enabled: true)
    }
    /// DynamicsProcessor：阈值（dB）、headroom（dB）、扩展比、起音 / 释放（s）、输出增益（dB）。
    /// 注意它没有固定压缩比：输出渐近于"阈值 + headroom"（探针曲线见报告 §1），扩展阈值契约里没有键、用 AU 默认（27 上 −100 dB）。
    public func setDynamics(thresholdDb: Float, headroomDb: Float = 5, expansionRatio: Float = 2, attack: Float = 0.001,
                            release: Float = 0.05, overallGainDb: Float = 0) {
        let e = "dynamicsProcessor"
        setParameter(kDynamicsProcessorParam_Threshold, EffectParameterRanges.clampF(thresholdDb, e, "thresholdDb"))
        setParameter(kDynamicsProcessorParam_HeadRoom, EffectParameterRanges.clampF(headroomDb, e, "headroomDb"))
        setParameter(kDynamicsProcessorParam_ExpansionRatio, EffectParameterRanges.clampF(expansionRatio, e, "expansionRatio"))
        setParameter(kDynamicsProcessorParam_AttackTime, EffectParameterRanges.clampF(attack, e, "attackSeconds"))
        setParameter(kDynamicsProcessorParam_ReleaseTime, EffectParameterRanges.clampF(release, e, "releaseSeconds"))
        setParameter(kDynamicsProcessorParam_OverallGain, EffectParameterRanges.clampF(overallGainDb, e, "overallGainDb"))
    }
    /// PeakLimiter：起音 / 衰减（s）、预增益（dB）。天花板固定 0 dBFS（AU 没有天花板参数）；起音 = 前瞻 = 延迟。
    public func setLimiter(attack: Float = 0.012, decay: Float = 0.024, preGainDb: Float = 0) {
        let e = "peakLimiter"
        setParameter(kLimiterParam_AttackTime, EffectParameterRanges.clampF(attack, e, "attackSeconds"))
        setParameter(kLimiterParam_DecayTime, EffectParameterRanges.clampF(decay, e, "decaySeconds"))
        setParameter(kLimiterParam_PreGain, EffectParameterRanges.clampF(preGainDb, e, "preGainDb"))
    }
}
