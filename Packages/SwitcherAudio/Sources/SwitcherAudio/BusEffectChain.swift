// BusEffectChain.swift —— 总线效果链：苹果自带 AudioUnit（ParametricEQ、DynamicsProcessor、PeakLimiter）的搭建（非实时）。
//
// 设计方案 §7 / §12 决策 5：效果用苹果 AU，在我们自己的混音线程里 AudioUnitRender；预先 initialize，运行期不改拓扑。
// 这里只做创建 / 配格式 / 装回调 / initialize / 调参；渲染在 sw_mix.c（sw_process_bus）。
// AudioUnitRender 在自有线程调用的注意事项（写进报告）：
//   1. 输入靠 kAudioUnitProperty_SetRenderCallback（C 函数 sw_effect_input_proc），AU 在 AudioUnitRender 内同步回调，同一线程；
//   2. 输入 / 输出 StreamFormat 都要设成 48 kHz float32 非交错 2 声道，MaximumFramesPerSlice ≥ 一次 render 的帧数；
//   3. AudioTimeStamp 至少带 mSampleTime（kAudioTimeStampSampleTimeValid），每块递增；
//   4. 不能与 AudioUnitUninitialize / 设置属性并发；参数（AudioUnitSetParameter）可以在别的线程改，AU 内部会平滑；
//   5. DynamicsProcessor / PeakLimiter 有前瞻延迟（kAudioUnitProperty_Latency），读出来给延迟核算。
import Foundation
import AudioToolbox
import SwitcherContracts

/// 一格效果的 AudioUnit 包装。
public final class EffectUnit: @unchecked Sendable {
    public let bus: Bus
    public let effect: BusEffect
    public let unit: AudioUnit
    public private(set) var initialized = false

    init(bus: Bus, effect: BusEffect, unit: AudioUnit) { self.bus = bus; self.effect = effect; self.unit = unit }

    deinit {
        if initialized { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
    }

    /// 设参数（全局 scope）。
    @discardableResult
    public func setParameter(_ id: AudioUnitParameterID, _ value: Float) -> OSStatus {
        AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
    }
    /// 读参数。
    public func parameter(_ id: AudioUnitParameterID) -> Float? {
        var v: AudioUnitParameterValue = 0
        return AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &v) == noErr ? v : nil
    }
    /// 延迟（秒），来自 kAudioUnitProperty_Latency。
    public var latencySeconds: Double {
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &v, &size) == noErr ? v : 0
    }
    /// 延迟（帧，48 kHz）。
    public var latencyFrames: Int { Int((latencySeconds * Double(AudioFormat.sampleRate)).rounded()) }

    fileprivate func markInitialized() { initialized = true }
}

/// 效果链搭建错误。
public enum EffectChainError: Error, CustomStringConvertible {
    case componentNotFound(BusEffect)
    case osStatus(String, OSStatus)
    public var description: String {
        switch self {
        case .componentNotFound(let e): "找不到 AudioUnit：\(e)"
        case .osStatus(let what, let st): "\(what) 失败：OSStatus \(st)"
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

    static func subtype(of effect: BusEffect) -> OSType {
        switch effect {
        case .parametricEQ: kAudioUnitSubType_ParametricEQ
        case .dynamicsProcessor: kAudioUnitSubType_DynamicsProcessor
        case .peakLimiter: kAudioUnitSubType_PeakLimiter
        }
    }

    /// 为一条总线的一格创建并 initialize 效果 AU，装到混音上下文。已装过的先卸下重建。
    /// 只能在实时线程未跑、或该格处于关闭状态时调（运行期不改拓扑）。
    @discardableResult
    public func installEffect(_ bus: Bus, _ effect: BusEffect) throws -> EffectUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: AudioMixer.subtype(of: effect),
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EffectChainError.componentNotFound(effect) }
        var instance: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &instance)
        guard st == noErr, let unit = instance else { throw EffectChainError.osStatus("AudioComponentInstanceNew", st) }
        let eu = EffectUnit(bus: bus, effect: effect, unit: unit)
        var fmt = AudioMixer.busStreamFormat
        let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fmtSize)
        guard st == noErr else { throw EffectChainError.osStatus("StreamFormat(input)", st) }
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, fmtSize)
        guard st == noErr else { throw EffectChainError.osStatus("StreamFormat(output)", st) }
        var maxFrames = UInt32(maxBlockFrames)
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        guard st == noErr else { throw EffectChainError.osStatus("MaximumFramesPerSlice", st) }
        // 输入回调 + 挂进上下文（此时格是关闭的，实时线程不会 render 它）
        removeEffectUnit(bus, effect)
        st = installEffect(bus, effect, unit: unit)
        guard st == noErr else { throw EffectChainError.osStatus("SetRenderCallback", st) }
        st = AudioUnitInitialize(unit)
        guard st == noErr else { removeEffect(bus, effect); throw EffectChainError.osStatus("AudioUnitInitialize", st) }
        eu.markInitialized()
        storeEffectUnit(eu)
        return eu
    }

    /// 四条总线 × 三格全部建好（都处于关闭 / 旁路状态，开关用 setEffectEnabled）。
    public func installStandardEffects() throws {
        for bus in Bus.allCases { for e in BusEffect.allCases { try installEffect(bus, e) } }
    }

    /// 某格的 AU 包装。
    public func effectUnit(_ bus: Bus, _ effect: BusEffect) -> EffectUnit? { effectUnitsStorage[bus.rawValue * 3 + Int(effect.rawValue)] }

    /// 卸下并销毁某格（先在上下文里摘掉，实时线程不再 render 它）。
    public func removeEffectUnit(_ bus: Bus, _ effect: BusEffect) {
        removeEffect(bus, effect)
        effectUnitsStorage[bus.rawValue * 3 + Int(effect.rawValue)] = nil
    }

    private func storeEffectUnit(_ eu: EffectUnit) { effectUnitsStorage[eu.bus.rawValue * 3 + Int(eu.effect.rawValue)] = eu }
}

// MARK: - 常用参数的类型化入口

extension EffectUnit {
    /// ParametricEQ：中心频率（Hz）、Q、增益（dB）。
    public func setParametricEQ(centerHz: Float, q: Float, gainDb: Float) {
        setParameter(kParametricEQParam_CenterFreq, centerHz)
        setParameter(kParametricEQParam_Q, q)
        setParameter(kParametricEQParam_Gain, gainDb)
    }
    /// DynamicsProcessor：阈值（dB）、headroom（dB）、扩展比、起音 / 释放（s）、输出增益（dB）。
    public func setDynamics(thresholdDb: Float, headroomDb: Float = 5, expansionRatio: Float = 2, attack: Float = 0.001,
                            release: Float = 0.05, overallGainDb: Float = 0) {
        setParameter(kDynamicsProcessorParam_Threshold, thresholdDb)
        setParameter(kDynamicsProcessorParam_HeadRoom, headroomDb)
        setParameter(kDynamicsProcessorParam_ExpansionRatio, expansionRatio)
        setParameter(kDynamicsProcessorParam_AttackTime, attack)
        setParameter(kDynamicsProcessorParam_ReleaseTime, release)
        setParameter(kDynamicsProcessorParam_OverallGain, overallGainDb)
    }
    /// PeakLimiter：起音 / 衰减（s）、预增益（dB）。
    public func setLimiter(attack: Float = 0.012, decay: Float = 0.024, preGainDb: Float = 0) {
        setParameter(kLimiterParam_AttackTime, attack)
        setParameter(kLimiterParam_DecayTime, decay)
        setParameter(kLimiterParam_PreGain, preGainDb)
    }
}
