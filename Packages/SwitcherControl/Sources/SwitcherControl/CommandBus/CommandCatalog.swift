import Foundation
import SwitcherContracts

// 命令目录：Command 的 34 个 case 各一条说明和一个样例。docs/api.md 由它生成（switcher-apidoc），
// HTTP API 的 GET /api/v1/commands 也返回它。`CommandKind(of:)` 是穷举 switch：契约加 case 这里编译就红，
// 目录不会悄悄落后（CommandCatalogTests 再钉一遍：每个 kind 都有样例、样例的 JSON 顶层键就是 case 名）。

/// Command 的 case 名（= JSON 顶层键）。
public enum CommandKind: String, CaseIterable, Sendable, Codable {
    case cut, fade, setTransition, setTransitionParams, autoTransition, setPreview, setProgram, tbar, ftb
    case overlay, setOverlay, setOverlayDecoration
    case audioGain, mute, busGain, busMute, setAFV, setMonitorMode, setBusEffects
    case startRecord, stopRecord, startStream, stopStream, setOutputEnabled, renameOutput
    case setInputSettings, renameInput, addInput, removeInput, setInputSource
    case addOutput, removeOutput, setOutputSettings
    case loadShow

    /// 一条命令属于哪个 case。
    public init(of command: Command) {
        switch command {
        case .cut: self = .cut
        case .fade: self = .fade
        case .setTransition: self = .setTransition
        case .setTransitionParams: self = .setTransitionParams
        case .autoTransition: self = .autoTransition
        case .setPreview: self = .setPreview
        case .setProgram: self = .setProgram
        case .tbar: self = .tbar
        case .ftb: self = .ftb
        case .overlay: self = .overlay
        case .setOverlay: self = .setOverlay
        case .setOverlayDecoration: self = .setOverlayDecoration
        case .audioGain: self = .audioGain
        case .mute: self = .mute
        case .busGain: self = .busGain
        case .busMute: self = .busMute
        case .setAFV: self = .setAFV
        case .setMonitorMode: self = .setMonitorMode
        case .setBusEffects: self = .setBusEffects
        case .startRecord: self = .startRecord
        case .stopRecord: self = .stopRecord
        case .startStream: self = .startStream
        case .stopStream: self = .stopStream
        case .setOutputEnabled: self = .setOutputEnabled
        case .renameOutput: self = .renameOutput
        case .setInputSettings: self = .setInputSettings
        case .renameInput: self = .renameInput
        case .addInput: self = .addInput
        case .removeInput: self = .removeInput
        case .setInputSource: self = .setInputSource
        case .addOutput: self = .addOutput
        case .removeOutput: self = .removeOutput
        case .setOutputSettings: self = .setOutputSettings
        case .loadShow: self = .loadShow
        }
    }
}

/// 目录里的一条。
public struct CommandDoc: Sendable {
    public var kind: CommandKind
    /// 分组（切换 / 叠加 / 音频 / 输出 / 输入表 / 输出表 / 节目）。
    public var group: String
    /// 一句话说明。
    public var summary: String
    /// 参数说明（参数名：含义）。
    public var parameters: [(name: String, note: String)]
    /// 样例。
    public var example: Command
}

/// 命令目录。
public enum CommandCatalog {
    public static func entry(for kind: CommandKind) -> CommandDoc {
        entries.first { $0.kind == kind }!
    }

    /// 按 Command.swift 的声明顺序。
    public static let entries: [CommandDoc] = {
        let sampleInput = InputConfig(number: 5, name: "机位 5", source: .synthetic(settings: SyntheticSourceSettings()))
        let sampleOutput = OutputState(number: 3, kind: .stream, name: "推流 B",
                                       settings: OutputSettings(video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                                stream: StreamSettings(url: "rtmp://localhost/live", streamKey: "key")))
        var showState = MixerState(format: .hd1080p60)
        showState.inputs = [InputConfig(number: 1, name: "机位 1", source: .synthetic(settings: SyntheticSourceSettings()))]
        showState.program = 1
        let sampleShow = Show(name: "示例", state: showState)
        return [
            CommandDoc(kind: .cut, group: "切换", summary: "PGM 与 PVW 原子对调，无中间态；转场进行中发 Cut 立即完成对调。", parameters: [], example: .cut),
            CommandDoc(kind: .fade, group: "切换", summary: "选 Fade 并立即开始 auto 转场（= setTransition(fade, d) + autoTransition）。",
                       parameters: [("durationTicks", "时长（拍）；0 等于 Cut")], example: .fade(durationTicks: 30)),
            CommandDoc(kind: .setTransition, group: "切换", summary: "选下一次转场的类型和时长，不开始；T-bar 用的也是它选的类型。",
                       parameters: [("type", "cut / fade / wipe / zoom / stinger"), ("durationTicks", "时长（拍）")],
                       example: .setTransition(type: .wipe, durationTicks: 20)),
            CommandDoc(kind: .setTransitionParams, group: "切换", summary: "改 Wipe / Stinger 参数（两组整体替换），下一次转场起生效；转场进行中（含 T-bar 推到一半）被拒。",
                       parameters: [("wipe", "{direction: leftToRight / rightToLeft / topToBottom / bottomToTop / diagonal, softness: 软边宽占画面的比例 0–1，超出钳住}"),
                                    ("stinger", "{input: 作 stinger 的输入编号（带 alpha 的文件 / 图片），不写 = 未设置；cutAtTick: 第几拍换底，≥ 0，≥ 时长 = 完成时换}")],
                       example: .setTransitionParams(wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams(input: 4, cutAtTick: 12))),
            CommandDoc(kind: .autoTransition, group: "切换", summary: "按已选的类型 / 时长开始 auto 转场；进行中再发则忽略。", parameters: [], example: .autoTransition),
            CommandDoc(kind: .setPreview, group: "切换", summary: "把 PVW 换成该输入。", parameters: [("input", "输入编号；0 = 黑场")], example: .setPreview(input: 2)),
            CommandDoc(kind: .setProgram, group: "切换", summary: "直接把 PGM 换成该输入（硬切），PVW 不变。", parameters: [("input", "输入编号；0 = 黑场")], example: .setProgram(input: 3)),
            CommandDoc(kind: .tbar, group: "切换", summary: "推杆位置 0–1；到 1 提交（对调并回到 0）。", parameters: [("progress", "0–1")], example: .tbar(progress: 0.5)),
            CommandDoc(kind: .ftb, group: "切换", summary: "渐黑开 / 关（显式目标，脚本可重放）；时长用状态里的 ftb.durationTicks。", parameters: [("on", "true = 黑")], example: .ftb(on: true)),
            CommandDoc(kind: .overlay, group: "叠加", summary: "开关叠加通道 1–4；input 非 null 时同时换该通道用的输入。",
                       parameters: [("channel", "1–4"), ("on", "开 / 关"), ("input", "输入编号或 null（不换）")], example: .overlay(channel: 1, on: true, input: 4)),
            CommandDoc(kind: .setOverlay, group: "叠加", summary: "改叠加通道的位置尺寸与进出动画。",
                       parameters: [("channel", "1–4"), ("rect", "{x, y, width, height} 都是 0–1 比例"), ("animation", "{kind: cut/fade/slide/zoom, durationTicks}")],
                       example: .setOverlay(channel: 2, rect: .bottomRightQuarter, animation: OverlayAnimation(kind: .fade, durationTicks: 15))),
            CommandDoc(kind: .setOverlayDecoration, group: "叠加", summary: "改叠加通道的装饰：画中画边框、锚点、是否在 PVW 里预览。",
                       parameters: [("channel", "1–4"), ("border", "{width: 占节目高的比例（渲染器钳到 0–0.1）, color: {red, green, blue}} 或 null（不画）"),
                                    ("anchor", "topLeft / top / topRight / left / center / right / bottomLeft / bottom / bottomRight；缩放动画绕它缩"),
                                    ("previewOn", "true = 这一路也画进 PVW")],
                       example: .setOverlayDecoration(channel: 1, border: OverlayBorder(), anchor: .bottomRight, previewOn: true)),
            CommandDoc(kind: .audioGain, group: "音频", summary: "某路输入的增益（dB，−96…+24，超出钳住）。", parameters: [("input", "输入编号"), ("dB", "增益")], example: .audioGain(input: 1, dB: -6)),
            CommandDoc(kind: .mute, group: "音频", summary: "某路输入静音开 / 关。", parameters: [("input", "输入编号"), ("on", "true = 静音")], example: .mute(input: 1, on: true)),
            CommandDoc(kind: .busGain, group: "音频", summary: "总线增益（dB）。", parameters: [("bus", "0 = master, 1 = busA, 2 = busB, 3 = headphones"), ("dB", "增益")], example: .busGain(bus: .master, dB: -3)),
            CommandDoc(kind: .busMute, group: "音频", summary: "总线静音开 / 关。", parameters: [("bus", "0–3，同 busGain"), ("on", "true = 静音")], example: .busMute(bus: .busA, on: true)),
            CommandDoc(kind: .setAFV, group: "音频", summary: "音频跟随视频开 / 关。", parameters: [("on", "开 / 关")], example: .setAFV(on: true)),
            CommandDoc(kind: .setMonitorMode, group: "音频", summary: "耳机监听方式：AFL（推子后）/ PFL（推子前）。",
                       parameters: [("mode", "afl / pfl")], example: .setMonitorMode(mode: .pfl)),
            CommandDoc(kind: .setBusEffects, group: "音频", summary: "整体替换一条总线的效果链；链顺序 = 处理顺序，enabled = false 的格旁路。",
                       parameters: [("bus", "0 = master, 1 = busA, 2 = busB, 3 = headphones"),
                                    ("effects", "[{id, enabled, params}]：id 与参数键见 CONTRACTS.md §2.4")],
                       example: .setBusEffects(bus: .master, effects: [EffectSlot(id: "peakLimiter", params: ["attackSeconds": 0.012, "decaySeconds": 0.024, "preGainDb": 0])])),
            CommandDoc(kind: .startRecord, group: "输出", summary: "开始录制（output 必须是 record 类型的输出）。", parameters: [("output", "输出编号")], example: .startRecord(output: 1)),
            CommandDoc(kind: .stopRecord, group: "输出", summary: "停止录制。", parameters: [("output", "输出编号")], example: .stopRecord(output: 1)),
            CommandDoc(kind: .startStream, group: "输出", summary: "开始推流（output 必须是 stream 类型的输出，url / key 在它的设置里）。", parameters: [("output", "输出编号")], example: .startStream(output: 2)),
            CommandDoc(kind: .stopStream, group: "输出", summary: "停止推流。", parameters: [("output", "输出编号")], example: .stopStream(output: 2)),
            CommandDoc(kind: .setOutputEnabled, group: "输出", summary: "非录制 / 推流输出（NDI / 外部显示 / 虚拟摄像头 / 多画面）的目标开关；record / stream 被拒。多画面的开关 = 要不要把多画面送给下游（NDI 之类），布局与它无关。",
                       parameters: [("output", "输出编号"), ("on", "true = 应该在跑")], example: .setOutputEnabled(output: 3, on: true)),
            CommandDoc(kind: .renameOutput, group: "输出", summary: "改一个输出的显示名。",
                       parameters: [("output", "输出编号"), ("name", "新名字")], example: .renameOutput(output: 3, name: "大屏")),
            CommandDoc(kind: .setInputSettings, group: "输入表", summary: "整体替换一路输入的设置（裁切 / 变换 / 音频 / 效果 / 抠像），超范围的值钳住。",
                       parameters: [("input", "输入编号"), ("settings", "InputSettings 整体")],
                       example: .setInputSettings(input: 1, settings: InputSettings(audio: InputAudioSettings(gainDb: -3, delayMs: 40)))),
            CommandDoc(kind: .renameInput, group: "输入表", summary: "改一路输入的显示名。", parameters: [("input", "输入编号"), ("name", "新名字")], example: .renameInput(input: 1, name: "主机位")),
            CommandDoc(kind: .addInput, group: "输入表", summary: "加一路输入；编号已存在则拒绝。", parameters: [("config", "InputConfig：number, name, source, settings")], example: .addInput(config: sampleInput)),
            CommandDoc(kind: .removeInput, group: "输入表", summary: "删一路输入；它若在 PGM / PVW / 叠加 / Stinger 上，那些位置变成 0 / null。", parameters: [("input", "输入编号")], example: .removeInput(input: 5)),
            CommandDoc(kind: .setInputSource, group: "输入表",
                       summary: "换一路输入的来源（文件路径 / 播完动作 / 屏幕目标 / 帧率 / NDI 源名与带宽 / DeckLink 接口……）；编号、名字、设置、PGM / PVW / 叠加引用全部保留。",
                       parameters: [("input", "输入编号"), ("source", "InputSource；kind 由它推出")],
                       example: .setInputSource(input: 1, source: .ndi(sourceName: "MAC (Cam 1)", bandwidth: .lowest, jitterBufferFrames: 2))),
            CommandDoc(kind: .addOutput, group: "输出表", summary: "加一个输出；编号已存在则拒绝。settings.extra 里的旧写法（layout / displayID / fallbackToMain）先搬进正式字段 multiview / display，与读节目文件相同。", parameters: [("config", "OutputState：number, kind, name, enabled, settings")], example: .addOutput(config: sampleOutput)),
            CommandDoc(kind: .removeOutput, group: "输出表", summary: "删一个输出。", parameters: [("output", "输出编号")], example: .removeOutput(output: 3)),
            CommandDoc(kind: .setOutputSettings, group: "输出表", summary: "整体替换一个输出的设置；extra 里的旧写法同 addOutput 先搬进正式字段。", parameters: [("output", "输出编号"), ("settings", "OutputSettings 整体")],
                       example: .setOutputSettings(output: 1, settings: OutputSettings(video: VideoEncodeSettings(codec: .hevc, bitrateBps: 12_000_000),
                                                                                       record: RecordSettings(directory: "/Volumes/Rec")))),
            CommandDoc(kind: .loadShow, group: "节目", summary: "用节目文件整体替换状态；旧写法按读节目文件同一套规则先搬迁（show.migratingLegacyKeys().makeState()），不合法的节目文件被拒。", parameters: [("show", "Show 整体")], example: .loadShow(show: sampleShow)),
        ]
    }()
}
