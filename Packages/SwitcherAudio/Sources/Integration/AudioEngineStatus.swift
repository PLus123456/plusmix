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
        /// 推子后 RMS（dBFS，L / R；300 ms 一阶平均，提案 017）。
        public var rmsDb: [Double]
        /// 正在摘除（淡出中）。
        public var removing: Bool
        /// 这一路的两格效果（W1-D3）。
        public var effects: InputEffects
    }
    /// 一路输入两格效果的现场（W1-D3）：EQ（≤ 16 段）→ 动态（compressor / dynamicsProcessor 二选一）；延迟从这一路的对齐延迟线里扣。
    public struct InputEffects: Hashable, Sendable {
        public var eqEnabled: Bool
        /// 装进 EQ 格的段数（契约链里的 parametricEQ 格数，≤ 16）。
        public var eqBands: Int
        /// 链里的动态格种类：`.compressor` / `.dynamicsProcessor`；nil = 没有。
        public var dynamicsKind: EffectKind?
        public var dynamicsEnabled: Bool
        /// 已打开的格的延迟之和（帧）：从这一路的对齐延迟线里扣掉（`InputStatus.alignmentDelayFrames` 已经少了它）。
        public var latencyFrames: Int
        /// 压缩器冲激法实测的延迟（帧）；没装压缩器为 nil。按设计 0；≠ 自报时按量到的记并记日志。
        public var compressorMeasuredLatencyFrames: Int?
        /// 契约链里没装上的格数（限幅、认不出的 id、第 17 段起、第二个动态）。
        public var ignored: Int

        public static let none = InputEffects(eqEnabled: false, eqBands: 0, dynamicsKind: nil, dynamicsEnabled: false, latencyFrames: 0,
                                              compressorMeasuredLatencyFrames: nil, ignored: 0)
    }
    /// 一条总线的表。
    public struct BusStatus: Hashable, Sendable {
        public var bus: Bus
        public var peakDb: [Double]
        /// RMS dBFS（提案 017）。
        public var rmsDb: [Double]
        public var truePeakDb: [Double]
        public var peakHoldDb: [Double]
        public var momentaryLUFS: Double
        public var shortTermLUFS: Double
        public var integratedLUFS: Double
        public var loudnessRangeLU: Double
        public var gainDb: Double
        public var muted: Bool
        /// 效果链（W5-C）。
        public var effects: BusEffects
    }
    /// 一条总线效果链的现场（W5-C）：三格各装了什么、开没开、延迟、换格记录。
    public struct BusEffects: Hashable, Sendable {
        /// 已打开的 AU 的延迟之和（帧）：这条总线消费者流的 PTS 再减去它（泵），A/V 对齐不因开效果而漂。
        public var latencyFrames: Int
        /// 三格（处理顺序 0 → 1 → 2）各挂着的 AU 种类，nil = 空格。
        public var slots: [EffectKind?]
        /// 三格的开关（已推给混音器的）。
        public var enabled: [Bool]
        /// 契约链里没装上的格数（认不出的 id、超出三格）。
        public var ignored: Int
        /// 准备好了、等实时线程确认关格之后才换进去 / 拆掉的格数。
        public var pendingSwaps: Int
        /// 累计：装进空格、换掉别的种类、拆掉。
        public var installs: Int
        public var swaps: Int
        public var removals: Int
        /// 最近一次换格那一格最多旁路了几块（上界 = 关格命令入队到开格命令入队之间混音器渲染的块数 + 1：两条命令都在入队后的下一块开头应用）。
        public var lastBypassBlocks: Int?
        /// 装着压缩器时它冲激法实测的延迟（帧，W1-D3；按设计 0，≠ 自报时按量到的记并记日志）；没装为 nil。
        public var compressorMeasuredLatencyFrames: Int?

        public static let empty = BusEffects(latencyFrames: 0, slots: [nil, nil, nil], enabled: [false, false, false], ignored: 0, pendingSwaps: 0,
                                             installs: 0, swaps: 0, removals: 0, lastBypassBlocks: nil, compressorMeasuredLatencyFrames: nil)
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
        /// 当前按多少帧补 PTS：audioPTS = 该总线的效果链延迟（输入来源 0，W5-C）；videoDelay = L_bus − L_m（Master 0，输入来源 −L_m：PTS 往后挪，W1-B4）。
        public var latencyFrames: Int
        /// 效果链延迟变大时丢掉的帧（AU 前瞻垫进来的那一段）/ 变小时补的静音帧，累计。W5-C。
        public var latencyFramesDropped: UInt64
        public var latencyFramesInserted: UInt64
    }

    public var device: DeviceStatus
    /// 对齐延迟（帧 / ms）。
    public var alignmentFrames: Int
    public var alignmentMs: Double
    public var inputs: [InputStatus]
    public var buses: [BusStatus]
    public var afv: Bool
    public var monitorMode: MonitorMode
    /// 耳机取延迟线前 / 后（W1-D2）。混音器侧的那个 `MonitorPoint`（契约里的同名类型见提案 007）。
    public var monitorPoint: SwitcherAudio.MonitorPoint
    /// 耳机出口放哪条总线（提案 026，`AudioState.monitorSource`，W1-D3 落到混音器）：master / busA / busB；有独听时总是独听的路。
    public var monitorSource: Bus
    /// 2 声道设备上"独听时临时占用 Master 声道"（X09）：开着且有独听时 Master 出口放耳机总线；本机设置，组装方按 `AppSettings.borrowMasterForMonitor` 设。
    public var borrowMasterForMonitor: Bool
    /// 实际生效的 A/V 补偿方式（W1-B4）：配置是 videoDelay 且接了视频引擎才是 videoDelay。
    public var avCompensation: AVCompensation
    /// 最近交给视频引擎的视频延后（帧 @48 k；audioPTS 或没接时 0）。引擎那边实际在用的值（slew 过程中可能还没到）看 `Engine.videoDelayApplied`。
    public var videoDelayFrames: Int
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
