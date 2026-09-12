// 命令（设计方案 §9.1）：UI、快捷键、MIDI、API 都只发命令，不直接改状态。

/// 一条命令的内容。覆盖 §9.1 列出的全部，另加几条后续会话必然要用的（转场选择、总线、输出与叠加的设置）。
/// JSON 形态由 Swift 合成的 Codable 决定：`{"fade":{"durationTicks":30}}`、无参数的是 `{"cut":{}}`；
/// 快照钉在 SwitcherContractsTests 里，是 HTTP API 的 wire format。
public enum Command: Hashable, Codable, Sendable {
    // 切换
    /// PGM 与 PVW 原子对调，无中间态。
    case cut
    /// 选 fade 并立即开始 auto 转场（= setTransition(.fade, d) + autoTransition）。§9.1 原文的 fade(duration)。
    case fade(durationTicks: Int)
    /// 选下一次转场的类型和时长，不开始。T-bar 用的也是它选的类型。
    case setTransition(type: TransitionType, durationTicks: Int)
    /// 按已选的类型 / 时长开始 auto 转场；进行中再发则忽略。
    case autoTransition
    case setPreview(input: Int)
    /// 直接把 PGM 换成该输入（硬切），PVW 不变。
    case setProgram(input: Int)
    /// 推杆位置 0–1；到 1 提交（对调并回到 0）。
    case tbar(progress: Double)
    case ftb(on: Bool)

    // 叠加
    /// 开关叠加通道 1–4；input 非 nil 时同时换通道用的输入。
    case overlay(channel: Int, on: Bool, input: Int?)
    /// 改叠加通道的位置尺寸与进出动画。
    case setOverlay(channel: Int, rect: NormalizedRect, animation: OverlayAnimation)

    // 音频
    case audioGain(input: Int, dB: Double)
    case mute(input: Int, on: Bool)
    case busGain(bus: Bus, dB: Double)
    case busMute(bus: Bus, on: Bool)
    case setAFV(on: Bool)

    // 输出（output = OutputState.number；kind 不匹配的命令被拒）
    case startRecord(output: Int)
    case stopRecord(output: Int)
    /// §9.1 的 startStream(dest)：dest 就是编号为 output 的 stream 输出，其 url / key 在它的设置里。
    case startStream(output: Int)
    case stopStream(output: Int)

    // 输入表
    /// 整体替换一路输入的设置（reducer 先 `clamped()`）。
    case setInputSettings(input: Int, settings: InputSettings)
    case renameInput(input: Int, name: String)
    /// 编号已存在则拒绝。
    case addInput(config: InputConfig)
    case removeInput(input: Int)

    // 输出表
    case addOutput(config: OutputState)
    case removeOutput(output: Int)
    case setOutputSettings(output: Int, settings: OutputSettings)

    // 节目
    /// 用节目文件整体替换状态（`show.makeState()`）。
    case loadShow(show: Show)
}

/// 进了命令总线的命令：总线（W2-C）分配 `sequence`、记 `issuedAt`，状态机（W1-B）按 sequence 严格顺序应用。
/// 场景脚本和 HTTP API 里只有 `Command`，信封在入口才加。
public struct IssuedCommand: Hashable, Codable, Sendable {
    /// 全局单调递增，从 1 起；乱序到达的排队等前一条。
    public var sequence: UInt64
    /// 发出时刻（host time）。C1 命令延迟 = 生效拍点时刻 − issuedAt。
    public var issuedAt: HostTime
    /// 命令内容。
    public var command: Command
    public init(sequence: UInt64, issuedAt: HostTime, command: Command) {
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.command = command
    }
}

/// 状态机对一条命令的回执。
public struct CommandReceipt: Hashable, Codable, Sendable {
    /// 对应命令的 sequence。
    public var sequence: UInt64
    /// 命令落在哪一拍（切换永远在拍点边界生效）。
    public var appliedTick: Tick
    public init(sequence: UInt64, appliedTick: Tick) {
        self.sequence = sequence
        self.appliedTick = appliedTick
    }
}

/// 状态机的纯函数部分（实现在 SwitcherEngine，W1-B）。签名在这里冻结，让 Control / TestKit 能对着它写测试。
///
/// - `reduce`：把一条命令应用到状态，返回新状态。纯函数：同样的 (state, command, tick) 永远得到同样的结果；
///   不做 I/O、不看时钟；非法命令（不存在的输入、通道越界、kind 不符）返回原状态不变。
/// - `advance`：把状态推进到某一拍：转场 / FTB / 叠加动画的进度按各自 durationTicks 推进，
///   auto 转场到 1 时对调 program / preview 并回到空闲。每拍先 advance 再 reduce 该拍的命令。
public protocol MixerReducing: Sendable {
    func reduce(_ state: MixerState, _ command: Command, at tick: Tick) -> MixerState
    func advance(_ state: MixerState, to tick: Tick) -> MixerState
}
