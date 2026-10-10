// 命令（设计方案 §9.1）：UI、快捷键、MIDI、API 都只发命令，不直接改状态。

/// 一条命令的内容。覆盖 §9.1 列出的全部，另加几条后续会话必然要用的（转场选择、总线、输出与叠加的设置）。
/// 34 个 case（P3 按提案 010 / 012 加了 setOverlayDecoration、setMonitorMode、setBusEffects、setOutputEnabled、
/// renameOutput、setInputSource，W3-E2 按提案 016 加了 setTransitionParams；对照见 CONTRACTS.md §8）。
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
    /// 改 Wipe / Stinger 参数（`TransitionState.wipe` / `.stinger` 两组整体替换；提案 016），下一次转场起生效。
    /// 转场进行中被拒（与 setTransition 同一口径：进行中的那一次按开始时的参数走）；stinger.input 非 nil 时须是存在的输入；
    /// softness 钳到 0–1，cutAtTick 钳到 ≥ 0（≥ durationTicks = 完成时换，不钳上限）。
    case setTransitionParams(wipe: WipeParams, stinger: StingerParams)
    /// 按已选的类型 / 时长开始 auto 转场；进行中再发则忽略。
    case autoTransition
    /// 把 PVW 换成该输入（0 = 黑场）；转场进行中被拒（与 autoTransition 同一口径，提案 023）。
    case setPreview(input: Int)
    /// 直接把 PGM 换成该输入（硬切），PVW 不变。转场进行中被拒（提案 023）。
    case setProgram(input: Int)
    /// 推杆位置 0–1；到 1 提交（对调并回到 0）。
    case tbar(progress: Double)
    case ftb(on: Bool)

    // 叠加
    /// 开关叠加通道 1–4；input 非 nil 时同时换通道用的输入。
    case overlay(channel: Int, on: Bool, input: Int?)
    /// 改叠加通道的位置尺寸与进出动画。
    case setOverlay(channel: Int, rect: NormalizedRect, animation: OverlayAnimation)
    /// 改叠加通道的装饰：边框（nil = 不画）、锚点、PVW 预览标志（提案 010 A4，P3 定）。
    /// 与 setOverlay 分开是为了不改它的 JSON 形态（W2-C 的客户端已经在用）。
    case setOverlayDecoration(channel: Int, border: OverlayBorder?, anchor: OverlayAnchor, previewOn: Bool)

    // 音频
    case audioGain(input: Int, dB: Double)
    case mute(input: Int, on: Bool)
    case busGain(bus: Bus, dB: Double)
    case busMute(bus: Bus, on: Bool)
    /// AFV 全局总开关。每路参不参与由 `InputAudioSettings.afv` 定（走 setInputSettings）。
    case setAFV(on: Bool)
    /// 耳机监听方式 PFL / AFL（提案 012）。监听点（延迟线前 / 后）是 `AudioState.monitorPoint`，走 Show，不是这条。
    case setMonitorMode(mode: MonitorMode)
    /// 整体替换一条总线的效果链（提案 012）。链顺序 = 处理顺序，`enabled = false` 的格旁路。
    case setBusEffects(bus: Bus, effects: [EffectSlot])

    // 输出（output = OutputState.number；kind 不匹配的命令被拒）
    case startRecord(output: Int)
    case stopRecord(output: Int)
    /// §9.1 的 startStream(dest)：dest 就是编号为 output 的 stream 输出，其 url / key 在它的设置里。
    case startStream(output: Int)
    case stopStream(output: Int)
    /// 非录制 / 推流输出（ndi / externalDisplay / virtualCamera / multiview）的目标开关（提案 012）。
    /// multiview 的开关 = 要不要把多画面 NV12 送给下游，布局与它无关（见 `OutputState.enabled`）。
    /// record / stream 被拒：它们走 startRecord / startStream，语义与起止拍绑定。
    case setOutputEnabled(output: Int, on: Bool)
    /// 改输出显示名（提案 012）。
    case renameOutput(output: Int, name: String)

    // 输入表
    /// 整体替换一路输入的设置（reducer 先 `clamped()`）。
    case setInputSettings(input: Int, settings: InputSettings)
    case renameInput(input: Int, name: String)
    /// 编号已存在则拒绝。
    case addInput(config: InputConfig)
    /// 删一路输入：PGM / PVW 用它的变成 0（黑场），叠加通道与 Stinger 对它的引用置 nil（Stinger 是 P4 加的，与叠加同口径）。
    case removeInput(input: Int)
    /// 换一路输入的来源（提案 012）：编号、名字、设置、PGM / PVW / 叠加引用全部保留，kind 由 source 推出。
    /// 与 removeInput + addInput 的区别就在这里——后者会清掉 PGM / PVW / 叠加对它的引用，直播中不可接受。
    case setInputSource(input: Int, source: InputSource)

    // 输出表
    /// 编号已存在则拒绝。设置先按 `OutputSettings.migratingLegacyKeys()` 搬过渡键（P4，与 Show.load 同一套规则）。
    case addOutput(config: OutputState)
    case removeOutput(output: Int)
    /// 整体替换一个输出的设置；同样先搬过渡键（P4）。
    case setOutputSettings(output: Int, settings: OutputSettings)

    // 节目
    /// 用节目文件整体替换状态（`show.migratingLegacyKeys().makeState()`：与 Show.load 读文件同一套搬迁，P4）；`validate()` 不过的被拒。
    case loadShow(show: Show)
}

/// 进了命令总线的命令：总线（W2-C）分配 `sequence`、记 `issuedAt`，状态机（W1-B）按 sequence 严格顺序应用。
/// 场景脚本和 HTTP API 里只有 `Command`，信封在入口才加。
public struct IssuedCommand: Hashable, Codable, Sendable {
    /// 全局单调递增，从 1 起；乱序到达的排队等前一条。
    public var sequence: UInt64
    /// 命令进总线的时刻（服务端 host time；提案 003 §C）。`生效拍点时刻 − issuedAt` 是"服务端收到 → 生效"；
    /// C1 的客户端口径（客户端发出 → 画面生效）由客户端自己记发送时刻（scripts/apitest），比它多一个单程网络延迟。
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
    /// 状态是否真的变了（提案 003 §A）。false = reducer 按规则忽略了它（转场进行中再 fade、FTB 目标已相同、mute 已是该值……），状态原样；
    /// 结构性非法的命令（引用不存在的输入 / 输出）到不了这里，在总线入口就被拒。
    public var applied: Bool
    public init(sequence: UInt64, appliedTick: Tick, applied: Bool = true) {
        self.sequence = sequence
        self.appliedTick = appliedTick
        self.applied = applied
    }

    enum CodingKeys: String, CodingKey { case sequence, appliedTick, applied }
    /// 老的 JSON 没有 applied 键：当 true。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try c.decode(UInt64.self, forKey: .sequence)
        appliedTick = try c.decode(Tick.self, forKey: .appliedTick)
        applied = try c.decodeIfPresent(Bool.self, forKey: .applied) ?? true
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
