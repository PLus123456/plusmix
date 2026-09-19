import Foundation
import SwitcherContracts
import SwitcherAudio

/// 音频引擎的状态快照（UI / API / 测试读；表读数进 Stats 要契约加字段，见 docs/contract-changes/004）。
/// 数字来源只有一处：混音器的统计 / 表 + 集成层的槽位表；每 `statusInterval` 刷新一次。
public struct AudioEngineStatus: Sendable {
    /// 一路输入。
    public struct InputStatus: Hashable, Sendable {
        public var number: Int
        public var slot: Int
        /// 环已填到设定点、在稳定输出。
        public var primed: Bool
        /// 对齐延迟已按本次就绪的年龄设好、已取消对齐静音。
        public var aligned: Bool
        /// 就绪那一刻的年龄（帧）= 重采样输入位置相对块首的滞后。W1-D2 起 = 目标年龄 ± 半帧（相位不利时可能更大）。
        public var ageSetpointFrames: Double
        /// 注册时给混音器的目标年龄（帧；0 = 旧规则）。
        public var targetAgeFrames: Int
        /// 当前年龄（帧，估计器控制量）。
        public var ageFrames: Double
        /// 对齐延迟线（帧）。
        public var alignmentDelayFrames: Int
        /// 补不齐的部分（帧）：年龄超过对齐延迟；> 0 说明这路比节目晚这么多。
        public var residualFrames: Int
        /// 用户延迟补偿（ms，契约 InputAudioSettings.delayMs）。
        public var userDelayMs: Int
        /// 重采样比（输出 / 输入）。
        public var ratio: Double
        public var ratioPpm: Double { (ratio - 1) * 1e6 }
        public var underrunBlocks: UInt64
        public var reprimes: UInt64
        /// AFV 门控目标（0…1）。
        public var afvGain: Float
        /// 推子后峰值（dBFS，L / R）。
        public var peakDb: [Double]
        /// 正在摘除（淡出中）。
        public var removing: Bool
    }
    /// 一条总线的表。
    public struct BusStatus: Hashable, Sendable {
        public var bus: Bus
        public var peakDb: [Double]
        public var truePeakDb: [Double]
        public var peakHoldDb: [Double]
        public var momentaryLUFS: Double
        public var shortTermLUFS: Double
        public var integratedLUFS: Double
        public var loudnessRangeLU: Double
        public var gainDb: Double
        public var muted: Bool
    }
    /// 输出设备。
    public struct DeviceStatus: Hashable, Sendable {
        public var kind: String
        public var name: String
        public var blockFrames: Int
        public var running: Bool
        public var callbacks: UInt64
        public var rebuilds: Int
        /// 回调抖动最大值（ms）。
        public var maxJitterMs: Double
    }
    /// 一个消费者来源。
    public struct ConsumerStatus: Hashable, Sendable {
        public var source: String
        public var consumers: [String]
        public var blocks: UInt64
        public var frames: UInt64
        public var tapDropped: UInt64
        /// 设备时钟相对 host 的 ppm（重采样开着时）。
        public var devicePpm: Double?
        public var resampleRatio: Double?
        public var resamplerStarved: UInt64
    }

    public var device: DeviceStatus
    /// 对齐延迟（帧 / ms）。
    public var alignmentFrames: Int
    public var alignmentMs: Double
    public var inputs: [InputStatus]
    public var buses: [BusStatus]
    public var afv: Bool
    public var monitorMode: MonitorMode
    /// 耳机取延迟线前 / 后（W1-D2）。
    public var monitorPoint: MonitorPoint
    /// 进行中的转场（from, to, 起点）。
    public var activeTransition: String?
    /// FTB 当前黑比例（音频侧算的）。
    public var ftbLevel: Double
    /// 测试标准 §7 audio{dropouts, underruns}（铁律 4：与 Stats 同源）。
    public var counters: Stats.AudioCounters
    /// A1 第三项：Master 消费者流上的波形不连续。
    public var discontinuities: UInt64
    public var realtimeViolations: UInt64
    public var tapDrops: UInt64
    public var commandsDropped: UInt64
    public var blocksRendered: UInt64
    public var consumers: [ConsumerStatus]
    /// 快照时刻。
    public var at: HostTime
}
