import CoreAudio
import SwitcherContracts
import SwitcherAudio

/// 音频引擎（集成层）的参数。
public struct AudioEngineConfiguration: Sendable {
    /// 输出设备。
    public enum Output: Sendable {
        /// 假设备时钟（W1-D 的 NullOutputDevice：time-constraint 线程 + mach_wait_until），不出声；CI 用。时钟 = host 时钟。
        case null
        /// 系统默认输出设备，跟随默认设备变更。
        case systemDefault
        /// 按名字找（精确或包含）。
        case device(name: String)
        /// 按 AudioDeviceID。
        case deviceID(AudioDeviceID)
        /// 没有驱动：测试自己用 `OfflineAudioDriver` 推块，并按块调 `runControlCycle(now:)` / `pumpOnce()`。
        case offline
    }
    /// 消费者块的时钟处理。
    public enum HostClockResampling: Sendable {
        /// 真设备重采样到 host 时钟，空设备 / 离线不重采样（它们的时钟就是 host 时钟）。
        case auto
        case on
        case off
    }
    /// 控制循环由谁驱动。
    public enum ControlMode: Sendable {
        /// 自己的控制线程（周期 `controlPeriod`，转场事件到达时立即唤醒）。
        case thread
        /// 调用方按需调 `runControlCycle(now:)`（离线测试）。
        case manual
    }

    public var output: Output = .systemDefault
    /// 名义块（= 设备 buffer size 请求值）。
    public var blockFrames: Int = AudioFormat.defaultBlockFrames
    /// 总线 → 设备通道；nil = 按设备声道数取标准映射。测试传 `BusChannelMap(master: nil)` 让扬声器静音而 Master 照常处理、照常送消费者。
    public var outputChannelMap: BusChannelMap? = nil
    /// 节目音频的对齐延迟（帧）：每路输入"环年龄（重采样输入位置相对块首的年龄，InputSlotStats.ageSetpoint）+ 对齐延迟线"= 它；
    /// Master / 总线 / ISO 块的 PTS = 块首样本 host time − 它。默认 2048 帧 = 42.67 ms：盖住 HAL（P 256）、合成源、AVCapture（P ≤ 1024）、
    /// NDI（1920）这些生产者的年龄，且与视频内部延迟（≈ 3 帧 50 ms）同量级，扬声器与 PGM 画面自然对上。
    /// W1-D2 起环年龄由混音器按目标就绪（`AudioInputHints.targetAgeFrames`，默认 = 任何相位都能命中的最小值：目标 + 3P/2 + 63，P 256 时 959 帧），
    /// 是确定值；对齐延迟线 = 它减年龄（959 → 1089 帧），也是确定的。目标年龄比它大的输入压到它（P 1024 时 2048，年龄正好 = 对齐延迟、延迟线 0）；
    /// 混音器安全下限（目标 + P/2 + 63 + 相位）都超过它的输入补不齐（`AudioEngineStatus.InputStatus.residualFrames`），需要调大它或减小该路的 targetFrames。
    /// 耳机总线默认不经对齐延迟线（`monitorPoint`），监听延迟 = 环年龄 + 设备。
    public var alignmentFrames: Int = 2048
    /// 耳机总线取每路输入延迟线前（默认：不带对齐延迟 / 延迟补偿，低延迟监听，A5）还是延迟线后（与节目同刻）的信号。W1-D2。
    /// 节目文件里的那一份是契约的 `SwitcherContracts.MonitorPoint`（提案 007），组装方用下面的转换填进来。
    public var monitorPoint: SwitcherAudio.MonitorPoint = .preDelayLine
    /// Cut 的短淡（块数，≥ 1；1 块 = 5.33 ms @256）：避免爆音。
    public var cutFadeBlocks: Int = 1
    /// FTB 同步淡出 Master（线性，与画面同一斜坡）。
    public var fadeMasterWithFTB: Bool = true
    /// 消费者块的时钟处理。
    public var hostClockResampling: HostClockResampling = .auto
    /// 控制循环周期。
    public var controlPeriod: HostDuration = HostDuration(milliseconds: 2)
    public var controlMode: ControlMode = .thread
    /// 摘除输入前先把它的 AFV 增益淡到 0，等这么多块再 detach（3 ms 平滑 + 余量）。
    public var removalFadeBlocks: Int = 3
    /// 每个消费者队列的容量（块）。
    public var tapCapacityBlocks: Int = 64
    /// 泵线程周期。
    public var pumpPeriod: HostDuration = HostDuration(milliseconds: 2)
    /// 对 Master 消费者流做波形不连续检测（A1 第三项）。
    public var detectDiscontinuities: Bool = true
    /// 混音器参数（块、槽位数、估计器、时基）。`blockFrames` 会覆盖它的 blockFrames。
    public var mixer = AudioMixerConfiguration()

    public init() {}

    /// 空设备 + 手动控制 + 不重采样：离线测试的默认。
    public static var offline: AudioEngineConfiguration {
        var c = AudioEngineConfiguration()
        c.output = .offline
        c.controlMode = .manual
        c.hostClockResampling = .off
        return c
    }
}

/// 一路输入注册时的提示（决定环的就绪门限；见 W1-D 报告 §5 "设定点与交付抖动"）。
public struct AudioInputHints: Sendable {
    /// 生产者一次写多少帧（HAL 256、AVCapture 512–1024、NDI 1920、文件读 4096）；nil = 按默认块。
    public var producerBlockFrames: Int? = nil
    /// 生产者最坏交付抖动（帧）；nil = 一块。
    public var deliveryJitterFrames: Int? = nil
    /// 与输出设备同一时钟（聚合设备自己的输入）：不重采样。
    public var sameClockAsOutput: Bool = false
    /// 直接指定 targetFrames（覆盖上面的推算；0 = 混音器默认 2 块）。
    public var targetFramesOverride: Int? = nil
    /// 就绪目标年龄（帧；W1-D2）：nil = min(混音器任何相位都能命中的最小值 = 目标 + P/2 + hf + chunk/2 + P（真设备再加输出提前量 buffer + 安全偏移）, 对齐延迟)；
    /// 0 = 混音器旧规则（年龄 = 安全下限 + 相位，随机）；显式值 = 想要的年龄（低于安全下限时按下限就绪，见 residualFrames）。
    public var targetAgeFrames: Int? = nil
    public init() {}

    /// 就绪目标（环里平均保有帧数）：max(2 块, 生产者块 + 1 块, 抖动 + 1 块)。生产者块大的源必须 ≥ 生产者块，否则两次交付之间会欠载。
    func targetFrames(blockFrames: Int) -> Int {
        if let o = targetFramesOverride { return o }
        var t = 2 * blockFrames
        if let p = producerBlockFrames { t = max(t, p + blockFrames) }
        if let j = deliveryJitterFrames { t = max(t, j + blockFrames) }
        return t
    }
}

extension SwitcherAudio.MonitorPoint {
    /// 契约的监听点（`AudioState.monitorPoint`，提案 007）→ 混音器的监听点。两个同名类型分处两个模块，组装方用它转换。
    public init(_ point: SwitcherContracts.MonitorPoint) {
        switch point {
        case .preDelayLine: self = .preDelayLine
        case .postDelayLine: self = .postDelayLine
        }
    }
}
