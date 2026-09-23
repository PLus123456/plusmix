// W3-B2 的固定状态：纯音频输入的多画面格、电平表读数（Stats.audio.meters 的形态，提案 004）。全部确定性，参考图和结构测试共用。
import SwitcherContracts

extension ReferenceStates {
    /// fixed8 里换成纯音频设备的那一路（原来是 stinger 图；输入表里照样给它帧，验"纯音频格不画画面"）。
    static let audioOnlyNumber = 6

    /// 3×3 多画面（PGM、PVW、输入 1–7），输入 6 换成纯音频设备。meters 默认关：只有纯音频格画电平表。
    static func audioOnly3x3(meters: Bool = false) -> MixerState {
        var s = withMultiviewLayout(fixed8(), MultiviewLayoutSettings(preset: "3x3", meters: meters))
        s.inputs[audioOnlyNumber - 1] = InputConfig(number: audioOnlyNumber, name: "话筒 Mic",
                                                    source: .audio(deviceUID: "BuiltInMicrophoneDevice"))
        return s
    }

    /// 一份 Stats.audio.meters：输入按编号给 [L, R] 峰值（dBFS），master 给 PGM 格用；其余三条总线静音（−120）。
    static func meters(inputs: [Int: [Double]], master: [Double]?) -> Stats.AudioCounters.Meters {
        var m = Stats.AudioCounters.Meters()
        m.inputs = inputs.mapValues { Stats.AudioCounters.InputMeter(peakDb: $0) }
        if let master {
            let floor = Stats.AudioCounters.Meters.floorDb
            m.buses = Bus.allCases.map { bus in
                let peak = bus == .master ? master : [floor, floor]
                return Stats.AudioCounters.BusMeter(bus: bus.name, peakDb: peak, truePeakDb: peak,
                                                    lufsM: floor, lufsS: floor, lufsI: floor, lra: 0)
            }
        }
        return m
    }

    /// 喂表的时间基点：离线渲染不看钟，峰值保持只看相邻两次喂数的时间差，所以用固定值。
    static let meterT0 = HostTime(ticks: 1_000_000_000)

    /// 参考图 v8-multiview-meters 的读数（布局 = customLayout：PGM、PVW = 输入 2、输入 3 / 4 / 1 / 2 / 5）：
    /// 输入 1 红区（−3 / −5）、输入 3 黄区（−14 / −16）、输入 4 绿区（−33 / −40）、Master（PGM 格）−9 / −10；
    /// 输入 2（也是 PVW）和 5 没有读数 → 输入格退回占位、PVW 格不画表。
    /// 先喂一次输入 4 更高的读数（−21 / −27），0.5 s 后再喂最终读数 → 输入 4 的峰值保持停在 −21 / −27（1 s 内不回落）。
    /// 挑的数避开了四道刻度（−12 / −24 / −36 / −48）和两个分段点（−18 / −6），结构测试取样时不会落在线上。
    static let referenceMeterInputs: [Int: [Double]] = [1: [-3, -5], 3: [-14, -16], 4: [-33, -40]]
    static let referenceMeterMaster: [Double] = [-9, -10]
    static let referenceMeterHold: [Double] = [-21, -27]
    static var referenceMeterCalls: [V8ReferenceTests.MeterFeedCall] {
        var first = referenceMeterInputs
        first[4] = referenceMeterHold
        return [
            V8ReferenceTests.MeterFeedCall(meters: meters(inputs: first, master: referenceMeterMaster), at: meterT0),
            V8ReferenceTests.MeterFeedCall(meters: meters(inputs: referenceMeterInputs, master: referenceMeterMaster),
                                           at: meterT0 + HostDuration(milliseconds: 500)),
        ]
    }
}
