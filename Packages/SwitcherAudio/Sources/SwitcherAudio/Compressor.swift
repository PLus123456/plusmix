// Compressor.swift —— 每路效果格的位置、自写压缩器（提案 024 (b)）的参数与控制面命令、监听来源 / 借 Master 声道（W1-D3，prompt 102）。
//
// 热路径在 CSwitcherAudioRT（sw_compressor_process / sw_fx_slot_process / 出口选路）；这里只有：参数钳位与系数换算（expf 在控制线程算）、
// 往命令队列放命令、每路两格 AU 的预建、延迟探针（Host 的 sw_compressor_probe_latency，用独立的压缩器实例跑冲激，不碰在跑的格）。
import Foundation
import AudioToolbox
import SwitcherContracts
import CSwitcherAudioRT
import CSwitcherAudioHost

/// 每路输入的两格（W1-D3）：顺序固定 EQ → 动态（设计方案 §7 的每输入 EQ / 压缩；01a 第 4 节第 10 行）。对应 C 的 sw_input_effect。
public enum InputEffect: Int32, Sendable, CaseIterable {
    /// AUNBandEQ（≤ 16 段）。
    case parametricEQ = 0
    /// 苹果 DynamicsProcessor 或自写压缩器（二选一，`EffectSlotKind`）。
    case dynamics = 1
    public var slot: Int { Int(rawValue) }
}

/// 效果格的位置：总线三格之一，或某路输入的两格之一。
public enum EffectLocation: Hashable, Sendable {
    case bus(Bus, BusEffect)
    case input(slot: Int, InputEffect)

    var cTarget: Int32 {
        switch self {
        case .bus: Int32(SW_FX_TARGET_BUS.rawValue)
        case .input: Int32(SW_FX_TARGET_INPUT.rawValue)
        }
    }
    var cIndex: Int {
        switch self {
        case .bus(let b, _): b.rawValue
        case .input(let s, _): s
        }
    }
    var cSlot: Int32 {
        switch self {
        case .bus(_, let e): e.rawValue
        case .input(_, let e): e.rawValue
        }
    }
    /// 日志 / 状态用的名字。
    public var description: String {
        switch self {
        case .bus(let b, let e): "\(b.name) 第 \(e.slot) 格"
        case .input(let s, let e): "槽位 \(s) 第 \(e.slot) 格"
        }
    }
}

/// 一格里跑什么（C 的 sw_fx_kind）：装着的 AudioUnit，或自写压缩器。运行期切换只改指向，不动拓扑。
public enum EffectSlotKind: Int32, Sendable {
    case audioUnit = 0
    case compressor = 1
}

/// 自写压缩器的参数（契约 `EffectSlot` id `compressor` 的键表，docs/CONTRACTS.md §2.4；范围 = `EffectParameterRanges.table["compressor"]`）。
/// 口径（sw_audio_rt.h 的注释是定义）：阈值按峰值 dBFS；比例 n:1；拐点宽 kneeDb（0 = 硬拐点，Giannoulis 2012 的二次过渡）；
/// 起音 / 释放 = 线性域峰值包络（解耦检测器）的一阶时间常数；补偿增益加在最后。不用前瞻，组延迟按设计 0 帧。
public struct CompressorParameters: Hashable, Sendable {
    public var thresholdDb: Double
    public var ratio: Double
    public var kneeDb: Double
    public var attackSeconds: Double
    public var releaseSeconds: Double
    public var makeupGainDb: Double

    public init(thresholdDb: Double = -20, ratio: Double = 4, kneeDb: Double = 6, attackSeconds: Double = 0.005, releaseSeconds: Double = 0.1, makeupGainDb: Double = 0) {
        self.thresholdDb = thresholdDb; self.ratio = ratio; self.kneeDb = kneeDb
        self.attackSeconds = attackSeconds; self.releaseSeconds = releaseSeconds; self.makeupGainDb = makeupGainDb
    }

    /// 算法自报的组延迟（帧）：前馈、不用前瞻 → 0。装格 / 改参数时集成层用 `AudioMixer.probeCompressorLatency` 冲激法复核，不一致按量到的记。
    public static let reportedLatencyFrames = 0

    /// 钳到契约范围（`EffectParameterRanges`）。
    public func clamped() -> CompressorParameters {
        func c(_ v: Double, _ key: String) -> Double { EffectParameterRanges.clamp(v, effect: "compressor", key: key).value }
        return CompressorParameters(thresholdDb: c(thresholdDb, "thresholdDb"), ratio: c(ratio, "ratio"), kneeDb: c(kneeDb, "kneeDb"),
                                    attackSeconds: c(attackSeconds, "attackSeconds"), releaseSeconds: c(releaseSeconds, "releaseSeconds"), makeupGainDb: c(makeupGainDb, "makeupGainDb"))
    }

    /// 静态曲线：输入电平（dBFS，峰值）→ 稳态增益（dB，含补偿）。测试与报告用的理论值，与 C 的增益计算同一公式。
    public func staticGainDb(inputDb x: Double) -> Double {
        let p = clamped()
        let over = x - p.thresholdDb, w = p.kneeDb, half = w / 2, slope = 1 / p.ratio - 1
        let gr: Double
        if w <= 0 { gr = over > 0 ? slope * over : 0 }                       // 硬拐点
        else if over > half { gr = slope * over }                              // 拐点上沿以上：斜率 1/R
        else if over < -half { gr = 0 }                                        // 拐点下沿以下：不动
        else { let t = over + half; gr = slope * t * t / (2 * w) }             // 拐点内：二次过渡
        return gr + p.makeupGainDb
    }

    /// C 侧的系数（状态清零）。
    func cValue(sampleRate: Int = AudioFormat.sampleRate) -> sw_compressor {
        let p = clamped()
        var c = sw_compressor()
        c.threshold_db = Float(p.thresholdDb)
        c.inv_ratio = Float(1 / p.ratio)
        c.knee_db = Float(p.kneeDb)
        c.alpha_attack = sw_compressor_alpha(p.attackSeconds, UInt32(sampleRate))
        c.alpha_release = sw_compressor_alpha(p.releaseSeconds, UInt32(sampleRate))
        c.makeup_lin = Float(pow(10, p.makeupGainDb / 20))
        c.env_release = 0; c.env = 0
        sw_compressor_update_derived(&c)
        return c
    }
}

extension AudioMixer {
    // MARK: 格的开关 / 种类 / 参数（任意非实时线程；命令在块边界应用）

    /// 开 / 关一格（总线或输入）。关 = 跳过这一格，逐样本旁路。
    public func setEffectEnabled(_ location: EffectLocation, _ on: Bool) {
        pushCommand(SW_CMD_EFFECT_ENABLE, index: location.cIndex, i0: location.cSlot, i1: on ? 1 : 0, i2: location.cTarget)
    }
    /// 这一格跑装着的 AU 还是自写压缩器。
    public func setEffectKind(_ location: EffectLocation, _ kind: EffectSlotKind) {
        pushCommand(SW_CMD_FX_KIND, index: location.cIndex, i0: location.cSlot, i1: kind.rawValue, i2: location.cTarget)
    }
    /// 自写压缩器的参数（先钳到契约范围，系数在这里算好；六条命令在同一块边界应用——即使被块边界隔开也只是一块里系数半新半旧）。
    public func setCompressor(_ location: EffectLocation, _ parameters: CompressorParameters) {
        let c = parameters.cValue()
        let pairs: [(sw_comp_param, Float)] = [(SW_COMP_THRESHOLD_DB, c.threshold_db), (SW_COMP_INV_RATIO, c.inv_ratio), (SW_COMP_KNEE_DB, c.knee_db),
                                               (SW_COMP_ALPHA_ATTACK, c.alpha_attack), (SW_COMP_ALPHA_RELEASE, c.alpha_release), (SW_COMP_MAKEUP_LIN, c.makeup_lin)]
        for (id, v) in pairs {
            pushCommand(SW_CMD_FX_PARAM, index: location.cIndex, i0: location.cSlot, i1: Int32(id.rawValue), i2: location.cTarget, f0: v)
        }
    }
    /// 格内输出增益（`peakLimiter.ceilingDb`，024 顺带 (2)）：渲染完乘一个系数，一阶平滑；0 dB = 不动。
    public func setEffectOutputGain(_ location: EffectLocation, dB: Double) {
        pushCommand(SW_CMD_FX_POST_GAIN, index: location.cIndex, i0: location.cSlot, i2: location.cTarget, f0: Float(pow(10, dB / 20)))
    }
    /// 复位一格的内部状态（AudioUnitReset + 压缩器包络清零）。只能在实时线程不会 render 它时调（格关着且已确认 / 槽位空闲且 detach 已确认）。
    public func resetEffectState(_ location: EffectLocation) {
        sw_mix_ctx_reset_effect_state(context, UInt32(location.cTarget), UInt32(location.cIndex), UInt32(location.cSlot))
    }

    // MARK: 监听来源（提案 026）与借 Master 声道（X09）

    /// 耳机出口放哪条总线：master / busA / busB；`.headphones` = 耳机总线自己（W1-D3 之前的行为，混音器的默认）。有独听时总是耳机总线。
    public func setMonitorSource(_ bus: Bus) { pushCommand(SW_CMD_MONITOR_SOURCE, i0: Int32(bus.rawValue)) }
    /// 开着且有独听时 Master 出口放耳机总线（2 声道设备上听独听）；消费者队列不受影响。
    public func setBorrowMasterForMonitor(_ on: Bool) { pushCommand(SW_CMD_MONITOR_BORROW_MASTER, i0: on ? 1 : 0) }

    // MARK: 延迟探针

    /// 冲激法量自写压缩器的组延迟（帧）：静音里一个 0.25 的冲激，输出峰值所在帧 − 冲激位置。用独立实例，不碰任何在跑的格；控制线程调。
    public static func probeCompressorLatency(_ parameters: CompressorParameters, impulseAt: Int = 1000, frames: Int = 4800) -> Int {
        var c = parameters.cValue()
        return Int(sw_compressor_probe_latency(&c, UInt32(max(0, impulseAt)), UInt32(max(frames, impulseAt + 1))))
    }

    // MARK: 每路两格的预建（W1-D3：按最大输入数预建，运行期只开关 / 设参数 / 切种类）

    /// 为每个输入槽位建好 EQ（AUNBandEQ 16 段，全部旁路）和动态（DynamicsProcessor，参数显式设成编辑器默认）两格并挂进混音器；
    /// 都处于关闭状态。返回建了几个 AU、用了多久（报告用）。已建过的槽位先卸下重建。
    @discardableResult
    public func installInputEffects() throws -> (units: Int, seconds: Double) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var n = 0
        for slot in 0..<inputCapacity {
            let eq = try installEffect(at: .input(slot: slot, .parametricEQ), kind: .nBandEQ)
            _ = eq
            let dyn = try installEffect(at: .input(slot: slot, .dynamics), kind: .dynamicsProcessor)
            dyn.setDynamics(thresholdDb: -20, headroomDb: 5, expansionRatio: 2, attack: 0.001, release: 0.05, overallGainDb: 0)
            n += 2
        }
        return (n, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
    }
}
