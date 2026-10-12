// 右侧可收起的调音台（W3-E 交付第 4 条）：每路条子（表、推子、静音、独听、声像、总线送出、跟随视频开关 + AFV 门控）、四总线（表、推子、静音、效果链）、
// AFV 总开关、监听选择（PFL / AFL）。SwiftUI 表单放 NSHostingView；动作只发 Command，显示只读快照。
// 表的数字只有一个来源（AudioMixer.meters，铁律 4）：读数文字 + A1 计数从 1 Hz 的 Stats.audio.meters 来（提案 004）；
// 条子按 AudioEngineStatus（控制循环每 50 ms 刷新的同一份读数）每 50 ms 刷，UI 高刷新率的表允许另读这一份（Stats.swift 的说明）。
// W3-E3：50 ms 的定时器挪到 session（AudioMeterFeed），同一份快照同时喂多画面电平表；条子画"RMS 实心条 + 峰值细线"（提案 017）。
// 监听方式 / 总线效果链走提案 012 的 setMonitorMode / setBusEffects（P3 落地）；每路"跟随视频"= InputAudioSettings.afv（用户 2026-09-22 批），
// 走 setInputSettings，门控显示读 AudioEngineStatus.afvGain（afv = false 的路引擎恒给 1 = 0 dB）。
// W5-B（X06）：音频引擎还不读总线效果链（AudioEffectsSupport）：总线条的"效果"不亮计数、效果 sheet 顶部写"效果尚未作用到声音（本版本）"。
// W5-K（prompt 97 交付 4，01a J2 / J3 / J6 / J7，02 X12 / X31，03 V-04）：
// - 每条总线条顶部、每路输入条上的齿轮开独立的"音频设置 — Master / 输入 n"窗（AudioSettingsPanel），去掉挂在主窗口上的效果 sheet（开着时快捷键全失灵）；
//   总线条的"效果 (n)"直达那扇窗的均衡页；输入条右键"输入设置…"仍开整窗。
// - 布局：Master 条常驻最右、总线组（Bus A / Bus B / 耳机）固定在它左边、输入组在最左边横向滚动；输入组与总线组都可收起成一根竖条（X31：输入多时
//   Master / 总线不再被挤出视野）；表头不折行（V-04）。设备没有耳机声道时表头写明（X09，音频设备页同一句）。
// - Master 条："监听"（耳机里听哪条总线；现在只有耳机总线，听 Master / Bus A / B 要音频引擎支持——灰着写原因，问题单 W5K-w1-audio-monitor-selected-bus）
//   与 i = 响度详情（瞬时 / 短期 / 积分 / LRA / 真峰值，读 Stats 1 Hz）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherAudioIntegration

/// 表的读数（50 ms）：输入 / 总线的推子后峰值与 RMS（dBFS，[L, R]；RMS 是提案 017 的 300 ms 平均）与 AFV 门控。
@MainActor
final class MixerMeters: ObservableObject {
    @Published private(set) var inputPeakDb: [Int: [Double]] = [:]
    @Published private(set) var inputRmsDb: [Int: [Double]] = [:]
    @Published private(set) var busPeakDb: [Bus: [Double]] = [:]
    @Published private(set) var busRmsDb: [Bus: [Double]] = [:]
    @Published private(set) var afvGain: [Int: Float] = [:]
    @Published private(set) var busLoudnessLUFS: [Bus: Double] = [:]
    /// 装着自写压缩器时引擎冲激法量到的延迟（帧，W1-D3；按设计 0）：音频设置窗压缩页的"延迟自测"一行（W5-O）。没装的不在里面。
    @Published private(set) var busCompressorLatencyFrames: [Bus: Int] = [:]
    @Published private(set) var inputCompressorLatencyFrames: [Int: Int] = [:]

    func clear() {
        inputPeakDb = [:]
        inputRmsDb = [:]
        busPeakDb = [:]
        busRmsDb = [:]
        afvGain = [:]
        busLoudnessLUFS = [:]
        busCompressorLatencyFrames = [:]
        inputCompressorLatencyFrames = [:]
    }

    func apply(status: AudioEngineStatus) {
        var inputs: [Int: [Double]] = [:]
        var inputRms: [Int: [Double]] = [:]
        var gains: [Int: Float] = [:]
        var inputLatency: [Int: Int] = [:]
        for i in status.inputs where !i.removing {
            inputs[i.number] = i.peakDb
            inputRms[i.number] = i.rmsDb
            gains[i.number] = i.afvGain
            if let frames = i.effects.compressorMeasuredLatencyFrames { inputLatency[i.number] = frames }
        }
        var buses: [Bus: [Double]] = [:]
        var busRms: [Bus: [Double]] = [:]
        var lufs: [Bus: Double] = [:]
        var busLatency: [Bus: Int] = [:]
        for b in status.buses {
            buses[b.bus] = b.peakDb
            busRms[b.bus] = b.rmsDb
            lufs[b.bus] = b.shortTermLUFS
            if let frames = b.effects.compressorMeasuredLatencyFrames { busLatency[b.bus] = frames }
        }
        if inputLatency != inputCompressorLatencyFrames { inputCompressorLatencyFrames = inputLatency }
        if busLatency != busCompressorLatencyFrames { busCompressorLatencyFrames = busLatency }
        if inputs != inputPeakDb { inputPeakDb = inputs }
        if inputRms != inputRmsDb { inputRmsDb = inputRms }
        if gains != afvGain { afvGain = gains }
        if buses != busPeakDb { busPeakDb = buses }
        if busRms != busRmsDb { busRmsDb = busRms }
        if lufs != busLoudnessLUFS { busLoudnessLUFS = lufs }
    }
}

/// 一条总线的响度详情（Stats.audio.meters.buses[]，1 Hz；铁律 4：界面不另算）。
struct LoudnessDetail: Equatable {
    var momentary: Double
    var shortTerm: Double
    var integrated: Double
    var range: Double
    var truePeak: [Double]

    /// 弹出层的五行（名字, 读数）。LUFS 到下限（静音）写 "—"。
    var rows: [(label: String, value: String)] {
        func lufs(_ v: Double) -> String { v <= Stats.AudioCounters.Meters.floorDb + 0.5 ? "—" : String(format: "%.1f LUFS", v) }
        let tp = truePeak.max() ?? Stats.AudioCounters.Meters.floorDb
        return [(L("mixer.loudness.momentary"), lufs(momentary)), (L("mixer.loudness.shortTerm"), lufs(shortTerm)),
                (L("mixer.loudness.integrated"), lufs(integrated)), (L("mixer.loudness.range"), String(format: "%.1f LU", max(0, range))),
                (L("mixer.loudness.truePeak"), tp <= Stats.AudioCounters.Meters.floorDb + 0.5 ? "—" : String(format: "%.1f dBTP", tp))]
    }
}

/// 调音台的状态与动作。
@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var state = MixerState()
    /// A1 计数 + Master 读数文字（Stats，1 Hz）。
    @Published private(set) var statsText = ""
    @Published private(set) var masterPeakText = "−∞ dBFS"
    /// 每条总线的响度详情（Stats，1 Hz；Master 条的 i，J7 / V08）。
    @Published private(set) var loudness: [Bus: LoudnessDetail] = [:]
    var send: ((Command) -> Void)?
    var onOpenInputSettings: ((Int) -> Void)?

    /// 推子范围（dB）。
    static let faderRange = -60.0...12.0
    /// 低于它显示 −∞（Stats 的 dB 下限是 −120）。
    static let silenceDb = -119.0

    var inputNumbers: [Int] { state.inputs.map(\.number) }

    /// 快照来了：调音台只用输入表与音频状态，转场进度 / 叠加动画这些每拍都变的字段不触发重画（W5-K；主窗口每帧重画会拖慢点击，W5-F 的坑）。
    func apply(state: MixerState) {
        guard state.inputs != self.state.inputs || state.audio != self.state.audio else { return }
        self.state = state
    }

    func apply(stats: Stats) {
        let a = stats.audio
        statsText = L("mixer.a1", Int(a.dropouts), Int(a.underruns), Int(a.discontinuities))
        if let master = a.meters.buses.first(where: { $0.bus == Bus.master.name }) {
            masterPeakText = Self.peakText(master.peakDb)
        } else {
            masterPeakText = "−∞ dBFS"
        }
        var details: [Bus: LoudnessDetail] = [:]
        for m in a.meters.buses {
            guard let bus = Bus.allCases.first(where: { $0.name == m.bus }) else { continue }
            details[bus] = LoudnessDetail(momentary: m.lufsM, shortTerm: m.lufsS, integrated: m.lufsI, range: m.lra, truePeak: m.truePeakDb)
        }
        if details != loudness { loudness = details }
    }

    /// "−20.1 dBFS"（取 L / R 的最大值）；静音显示 −∞。
    static func peakText(_ peakDb: [Double]) -> String {
        guard let m = peakDb.max(), m > silenceDb else { return "−∞ dBFS" }
        return String(format: "%.1f dBFS", m)
    }

    static func gainText(_ dB: Double) -> String {
        dB <= faderRange.lowerBound ? "−∞ dB" : String(format: "%+.1f dB", dB)
    }

    /// 条子上的 AFV 门控：全局 AFV 关 = "AFV 关"；否则把 AudioEngineStatus 的门控增益换成 dB（1 = 0 dB、0 = −∞）。
    /// 不跟随视频（afv = false）的路引擎恒给 1，所以恒显示 0 dB——读的是同一份数，不在这里另算。
    static func afvGateText(globalAFV: Bool, gain: Float?) -> String {
        guard globalAFV else { return L("mixer.afvOff") }
        guard let g = gain else { return "—" }
        let db: String
        if g >= 0.9999 { db = "0 dB" }
        else if g <= 0.0001 { db = "−∞ dB" }
        else { db = String(format: "%.1f dB", 20 * log10(Double(g))) }
        return L("mixer.afvGate", db)
    }

    // MARK: 每路

    private func updateInput(_ number: Int, _ body: (inout InputSettings) -> Void) {
        guard let i = state.inputs.firstIndex(where: { $0.number == number }) else { return }
        var s = state.inputs[i].settings
        body(&s)
        guard s != state.inputs[i].settings else { return }
        state.inputs[i].settings = s
        send?(.setInputSettings(input: number, settings: s))
    }

    func setInputGain(_ number: Int, dB: Double) {
        let v = (dB * 10).rounded() / 10
        send?(.audioGain(input: number, dB: v <= Self.faderRange.lowerBound ? InputAudioSettings.gainRangeDb.lowerBound : v))
    }
    func setMute(_ number: Int, on: Bool) { send?(.mute(input: number, on: on)) }
    func setSolo(_ number: Int, on: Bool) { updateInput(number) { $0.audio.solo = on } }
    func setPan(_ number: Int, value: Double) { updateInput(number) { $0.audio.pan = min(max(value, -1), 1) } }
    func setRouting(_ number: Int, bus: Bus, on: Bool) { updateInput(number) { $0.audio.routing[bus] = on } }
    func setDelay(_ number: Int, ms: Int) { updateInput(number) { $0.audio.delayMs = ms } }
    func setInputEffects(_ number: Int, _ effects: [EffectSlot]) { updateInput(number) { $0.effects = effects } }

    // MARK: 总线

    func setBusGain(_ bus: Bus, dB: Double) {
        let v = (dB * 10).rounded() / 10
        send?(.busGain(bus: bus, dB: v <= Self.faderRange.lowerBound ? InputAudioSettings.gainRangeDb.lowerBound : v))
    }
    func setBusMute(_ bus: Bus, on: Bool) { send?(.busMute(bus: bus, on: on)) }
    func setAFV(on: Bool) { send?(.setAFV(on: on)) }

    /// 监听方式 PFL / AFL（提案 012 的 setMonitorMode；不再 loadShow 整体替换，转场进行中也不会被 resetTransientState 打断）。
    func setMonitorMode(_ mode: MonitorMode) {
        guard state.audio.monitorMode != mode else { return }
        state.audio.monitorMode = mode
        send?(.setMonitorMode(mode: mode))
    }

    /// 总线条"效果"按钮的字：效果真的作用到声音之后才带计数"效果 (n)"，没接上时不亮计数（W5-B，X06）。
    static func busEffectsButtonTitle(count: Int, applied: Bool = AudioEffectsSupport.busEffectsApplied) -> String {
        applied ? L("mixer.effects", count) : L("mixer.effectsInactive")
    }
    func busEffectsButtonTitle(_ bus: Bus) -> String { Self.busEffectsButtonTitle(count: busState(bus).effects.count) }
    /// 总线效果页顶部的横幅（没接上时）。
    var busEffectsBanner: String? { AudioEffectsSupport.banner(applied: AudioEffectsSupport.busEffectsApplied) }

    /// 总线效果链（提案 012 的 setBusEffects）。
    func setBusEffects(_ bus: Bus, _ effects: [EffectSlot]) {
        guard let i = state.audio.buses.firstIndex(where: { $0.bus == bus }), state.audio.buses[i].effects != effects else { return }
        state.audio.buses[i].effects = effects
        send?(.setBusEffects(bus: bus, effects: effects))
    }

    /// 某一路参不参与 AFV 门控（`InputAudioSettings.afv`，用户 2026-09-22 批）：走 setInputSettings，没有单独的命令。
    func setInputAFV(_ input: Int, on: Bool) {
        guard let i = state.inputs.firstIndex(where: { $0.number == input }), state.inputs[i].settings.audio.afv != on else { return }
        state.inputs[i].settings.audio.afv = on
        send?(.setInputSettings(input: input, settings: state.inputs[i].settings))
    }

    func busState(_ bus: Bus) -> BusState { state.audio.buses.first { $0.bus == bus } ?? BusState(bus: bus) }

    // MARK: 音频设置窗与设备声道（W5-K）

    /// 条子上的齿轮：打开这一条的"音频设置"窗（page = 直达哪一页）。
    var onOpenAudioSettings: ((AudioStrip, AudioSettingsPage?) -> Void)?
    func openAudioSettings(_ strip: AudioStrip, page: AudioSettingsPage? = nil) { onOpenAudioSettings?(strip, page) }

    /// 输入组 / 总线组展开着（收起 = 一根竖条；X31）。Master 条常驻，不收。
    @Published var inputsExpanded = true
    @Published var busesExpanded = false

    /// 调音台头部的提示（设备没有耳机声道，X09）。
    @Published private(set) var headerHint: String?
    /// 现在的输出设备有几个声道（空设备 / 不知道为 nil）与每条总线的出口（AudioRuntime 建引擎时用的那一份）。
    func setOutputInfo(outputChannels: Int?, map: BusOutputMap?) {
        let hint = Self.headphonesHint(outputChannels: outputChannels, map: map)
        if hint != headerHint { headerHint = hint }
    }

    /// 设备只有 2 个（或更少）输出声道、耳机总线又没占 Master 的声道：耳机 / 独听 / PFL 都听不到（X09）。空设备不提示。
    static func headphonesHint(outputChannels: Int?, map: BusOutputMap?) -> String? {
        guard let channels = outputChannels, channels > 0 else { return nil }
        if let hp = map?.headphones, hp + 1 < channels { return nil }
        guard channels <= 2 else { return nil }
        return L("audioDevice.noHeadphoneChannels")
    }

    // MARK: 监听这条（J7；提案 026 的 setMonitorSource，W1-D3 引擎 + P5-3 允许 headphones，W5-O 接上）

    /// 耳机里现在听的是哪条总线：快照的 audio.monitorSource（新节目默认 Master；API 改的也从这里来）。有独听 / PFL / AFL 时引擎总是听独听的那一路。
    var listenBus: Bus { state.audio.monitorSource }
    /// 菜单里的四项（顺序）：Master / Bus A / Bus B / 耳机总线（= 耳机总线自己：只听每路送耳机的那一条，提案 026 用户 2026-10-12 允许）。
    static let listenBuses: [Bus] = [.master, .busA, .busB, .headphones]
    /// 能不能让耳机听别的总线：引擎（W1-D3）与契约（026）都支持了（原来只能听耳机总线自己，菜单那三项灰着）。
    static let listenToOtherBusSupported = true

    static func listenTitle(_ bus: Bus) -> String { bus == .headphones ? L("mixer.listen.headphones") : L("bus.\(bus.name)") }

    /// 选耳机里听哪条总线：发 setMonitorSource（契约命令，与 API 同一条），菜单的勾等快照回来再变。已经是它就不发（不在状态行冒"命令被忽略"）。
    /// 没接 session 时返回 false。
    @discardableResult
    func listen(_ bus: Bus) -> Bool {
        guard let send else { return false }
        if bus != listenBus { send(.setMonitorSource(bus: bus)) }
        return true
    }
}

/// AppKit 容器：主窗口右栏；SwiftUI 内容。表的 50 ms 读数由 session 的 AudioMeterFeed 推过来（MainWindowController 接线）。
@MainActor
final class MixerPanelView: NSView {
    let model = MixerModel()
    let meters = MixerMeters()
    var send: ((Command) -> Void)? {
        didSet { model.send = send }
    }
    var onOpenInputSettings: ((Int) -> Void)? {
        didSet { model.onOpenInputSettings = onOpenInputSettings }
    }
    /// 齿轮：打开音频设置窗（W5-K）。
    var onOpenAudioSettings: ((AudioStrip, AudioSettingsPage?) -> Void)? {
        didSet { model.onOpenAudioSettings = onOpenAudioSettings }
    }
    private let host: NSHostingView<MixerView>
    /// 最近一次从 Stats 读到的 Master 峰值（dBFS，[L, R]；nil = 还没有）。测试看。
    private(set) var masterPeakDb: [Double]?

    override init(frame: NSRect) {
        host = NSHostingView(rootView: MixerView(model: model, meters: meters))
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: MixerState) { model.apply(state: state) }

    /// 1 Hz：读数文字 + A1 + 响度详情。
    func apply(stats: Stats) {
        model.apply(stats: stats)
        masterPeakDb = stats.audio.meters.buses.first { $0.bus == Bus.master.name }?.peakDb
    }

    /// 50 ms：session 的 AudioMeterFeed 推来的快照（与多画面电平表同一份）。
    func apply(audioStatus status: AudioEngineStatus) {
        meters.apply(status: status)
        onMeters?(meters.inputPeakDb)
    }

    /// 换 session / 没有 session：表清空。
    func clearMeters() { meters.clear() }

    /// 每次刷表之后（50 ms）：把每路读数转给别处用（纯音频输入的缩略图格子画电平表），同一份数。
    var onMeters: (([Int: [Double]]) -> Void)?

    var displayedGain: String { MixerModel.gainText(model.busState(.master).gainDb) }
    var displayedPeak: String { model.masterPeakText }
}

// MARK: - SwiftUI

/// 总线条的宽（比输入条窄：没有声像 / 送出；Master + 三条总线在 340 pt 的调音台里放得下，X31）。
let mixerBusStripWidth: CGFloat = 64

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var meters: MixerMeters

    var body: some View {
        VStack(spacing: 6) {
            MixerHeaderView(model: model)
            if let hint = model.headerHint {
                Label(hint, systemImage: "headphones")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .help(L("audioDevice.noHeadphoneChannelsHelp"))
            }
            Divider()
            HStack(alignment: .top, spacing: 4) {
                inputGroup
                Divider().frame(height: 300)
                busGroup
                MixerBusStrip(model: model, meters: meters, bus: .master)   // Master 常驻、固定在最右（X31）
            }
            .padding(.horizontal, 6)
            Divider()
            HStack {
                Text(model.masterPeakText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .help(L("mixer.masterPeakHelp"))
                Spacer()
                Text(model.statsText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .help(L("mixer.a1Help"))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // 内容贴顶（V-03：原来垂直居中，上下各空约 250 pt）
    }

    /// 输入组：横向滚动；收起 = 一根竖条（点了展开）。
    @ViewBuilder
    private var inputGroup: some View {
        if model.inputsExpanded {
            VStack(spacing: 2) {
                GroupToggle(title: L("mixer.group.inputs", model.state.inputs.count), expanded: true) { model.inputsExpanded = false }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(model.state.inputs) { input in
                            MixerInputStrip(model: model, meters: meters, input: input)
                        }
                        if model.state.inputs.isEmpty {
                            Text(L("mixer.noInputs")).font(.caption).foregroundStyle(.secondary).frame(width: 92)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CollapsedGroupBar(title: L("mixer.group.inputs", model.state.inputs.count)) { model.inputsExpanded = true }
        }
    }

    /// 总线组（Bus A / Bus B / 耳机）：固定在 Master 左边，不随输入滚动；收起 = 一根竖条。
    @ViewBuilder
    private var busGroup: some View {
        if model.busesExpanded {
            VStack(spacing: 2) {
                GroupToggle(title: L("mixer.group.buses"), expanded: true) { model.busesExpanded = false }
                HStack(alignment: .top, spacing: 4) {
                    ForEach([Bus.busA, .busB, .headphones], id: \.self) { bus in
                        MixerBusStrip(model: model, meters: meters, bus: bus)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            CollapsedGroupBar(title: L("mixer.group.buses")) { model.busesExpanded = true }
        }
    }
}

/// 调音台表头：标题 + AFV 总开关 + 监听方式；不折行（V-04：原来"监听"折成两行、窄的时候"调音台"也折、"AFV"消失）。
struct MixerHeaderView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        HStack(spacing: 8) {
            Text(L("mixer.title")).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Toggle(L("mixer.afv"), isOn: Binding(get: { model.state.audio.afv }, set: { model.setAFV(on: $0) }))
                .toggleStyle(.switch).controlSize(.mini)
                .fixedSize()
                .help(L("mixer.afvHelp"))
            Picker(L("mixer.monitor"), selection: Binding(get: { model.state.audio.monitorMode }, set: { model.setMonitorMode($0) })) {
                Text("AFL").tag(MonitorMode.afl)
                Text("PFL").tag(MonitorMode.pfl)
            }
            .labelsHidden()
            .pickerStyle(.segmented).controlSize(.mini).frame(width: 84)
            .help(L("mixer.monitorHelp"))
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

/// 组标题（展开时）：名字 + 收起箭头。
private struct GroupToggle: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .accessibilityLabel(L("mixer.group.collapse", title))
            .buttonStyle(.plain)
            .help(L("mixer.group.collapse", title))
    }

    private var label: some View {
        HStack(spacing: 3) {
            Image(systemName: expanded ? "chevron.left" : "chevron.right").font(.system(size: 8, weight: .bold))
            Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }
}

/// 组收起后的竖条：点了展开。
private struct CollapsedGroupBar: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .accessibilityLabel(L("mixer.group.expand", title))
            .buttonStyle(.plain)
            .help(L("mixer.group.expand", title))
    }

    private var label: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            Text(title).font(.system(size: 10, weight: .semibold)).fixedSize().rotationEffect(.degrees(-90)).frame(width: 14, height: 120)
        }
        .frame(width: 20, height: 300)
        .foregroundStyle(.secondary)
        .background(Color(nsColor: Theme.cellBackground), in: RoundedRectangle(cornerRadius: 4))
    }
}

extension Bus: @retroactive Identifiable {
    public var id: Int { rawValue }
}

/// 条子顶部的齿轮（开这一条的音频设置窗）。
private struct StripGear: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "gearshape").font(.system(size: 10)) }
            .accessibilityLabel(label)
            .buttonStyle(.borderless)
            .help(label)
    }
}

/// 一路输入的条子。
struct MixerInputStrip: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var meters: MixerMeters
    let input: InputConfig

    private var audio: InputAudioSettings { input.settings.audio }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text("\(input.number) \(input.name)").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                StripGear(label: L("mixer.audioSettingsOf", L("audioSettings.inputTitle", input.number))) { model.openAudioSettings(.input(input.number)) }
            }
            .frame(width: 84)
            HStack(spacing: 4) {
                MeterBar(peakDb: meters.inputPeakDb[input.number], rmsDb: meters.inputRmsDb[input.number])
                VerticalFader(value: audio.gainDb, range: MixerModel.faderRange, label: L("mixer.inputFader", input.number)) { model.setInputGain(input.number, dB: $0) }
            }
            .frame(height: 170)
            Text(MixerModel.gainText(audio.gainDb)).font(.system(size: 10, design: .monospaced))
            PanSlider(value: audio.pan, label: L("mixer.pan", input.number)) { model.setPan(input.number, value: $0) }
                .frame(width: 80, height: 16)
                .help(L("mixer.panHelp", audio.pan))
            HStack(spacing: 2) {
                Toggle(L("mixer.mute"), isOn: Binding(get: { audio.muted }, set: { model.setMute(input.number, on: $0) }))
                Toggle(L("mixer.solo"), isOn: Binding(get: { audio.solo }, set: { model.setSolo(input.number, on: $0) }))
            }
            .toggleStyle(.button).controlSize(.mini)
            HStack(spacing: 2) {
                ForEach(Bus.allCases) { bus in
                    Toggle(L("bus.short.\(bus.name)"), isOn: Binding(get: { audio.routing[bus] }, set: { model.setRouting(input.number, bus: bus, on: $0) }))
                        .help(L("mixer.routingHelp", L("bus.\(bus.name)")))
                }
            }
            .toggleStyle(.button).controlSize(.mini)
            Toggle(L("mixer.followVideo"), isOn: Binding(get: { audio.afv }, set: { model.setInputAFV(input.number, on: $0) }))
                .toggleStyle(.button).controlSize(.mini)
                .help(L("mixer.followVideoHelp"))
            afvIndicator
        }
        .frame(width: 92)
        .padding(4)
        .background(Color(nsColor: Theme.cellBackground), in: RoundedRectangle(cornerRadius: 4))
        .contextMenu {
            Button(L("mixer.audioSettingsOf", L("audioSettings.inputTitle", input.number))) { model.openAudioSettings(.input(input.number)) }
            Button(L("mixer.inputSettings")) { model.onOpenInputSettings?(input.number) }
        }
    }

    private var afvIndicator: some View {
        Text(MixerModel.afvGateText(globalAFV: model.state.audio.afv, gain: meters.afvGain[input.number]))
            .font(.system(size: 9)).foregroundStyle(.secondary).help(L("mixer.afvIndicatorHelp"))
    }
}

/// 一条总线的条子（比输入条窄）：齿轮、表 + 推子、读数、LUFS、静音、效果 (n)；Master 另有监听与响度详情。
struct MixerBusStrip: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var meters: MixerMeters
    let bus: Bus
    @State private var showingLoudness = false

    var body: some View {
        let s = model.busState(bus)
        VStack(spacing: 4) {
            HStack(spacing: 1) {
                Text(L("bus.\(bus.name)")).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                StripGear(label: L("mixer.audioSettingsOf", L("bus.\(bus.name)"))) { model.openAudioSettings(.bus(bus)) }
            }
            .frame(width: mixerBusStripWidth - 4)
            HStack(spacing: 4) {
                MeterBar(peakDb: meters.busPeakDb[bus], rmsDb: meters.busRmsDb[bus])
                VerticalFader(value: s.gainDb, range: MixerModel.faderRange, label: L("mixer.busFader", L("bus.\(bus.name)"))) { model.setBusGain(bus, dB: $0) }
            }
            .frame(height: 170)
            Text(MixerModel.gainText(s.gainDb)).font(.system(size: 10, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            Text(meters.busLoudnessLUFS[bus].map { $0 > -100 ? String(format: "%.1f LUFS", $0) : "— LUFS" } ?? "— LUFS")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7).help(L("mixer.lufsHelp"))
            Toggle(L("mixer.mute"), isOn: Binding(get: { s.muted }, set: { model.setBusMute(bus, on: $0) }))
                .toggleStyle(.button).controlSize(.mini)
            Button(model.busEffectsButtonTitle(bus)) { model.openAudioSettings(.bus(bus), page: .eq) }.controlSize(.mini)
                .accessibilityLabel(L("mixer.busEffectsTitle", L("bus.\(bus.name)")))
                .foregroundStyle(model.busEffectsBanner == nil ? HierarchicalShapeStyle.primary : .secondary)
                .help(model.busEffectsBanner.map { $0 + "\n" + L("effects.notEffectiveHelp") } ?? L("mixer.busEffectsHint"))
            if bus == .master { masterExtras }
        }
        .frame(width: mixerBusStripWidth)
        .padding(4)
        .background(Color(nsColor: Theme.cellBackground), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Master 条：监听（耳机里听哪条总线）+ i（响度详情）。
    private var masterExtras: some View {
        HStack(spacing: 2) {
            Menu {
                // 四项单选、勾在快照的 monitorSource 上（W5-O）
                Picker(L("mixer.listen"), selection: Binding(get: { model.listenBus }, set: { model.listen($0) })) {
                    ForEach(MixerModel.listenBuses, id: \.self) { bus in Text(MixerModel.listenTitle(bus)).tag(bus) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "headphones")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("mixer.listen"))
            .help(L("mixer.listenHelp"))
            Button { showingLoudness.toggle() } label: { Image(systemName: "info.circle") }
                .accessibilityLabel(L("mixer.loudness.title"))
                .buttonStyle(.borderless)
                .help(L("mixer.loudness.title"))
                .popover(isPresented: $showingLoudness, arrowEdge: .leading) { LoudnessDetailView(model: model, bus: bus) }
        }
    }
}

/// 响度详情（J7 / V08）：瞬时 / 短期 / 积分 / LRA / 真峰值，读 Stats（1 Hz）。积分复位要不要进命令待定（02 V08），这一版没有复位。
struct LoudnessDetailView: View {
    @ObservedObject var model: MixerModel
    let bus: Bus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("mixer.loudness.heading", L("bus.\(bus.name)"))).font(.headline)
            if let detail = model.loudness[bus] {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(detail.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value).font(.system(.body, design: .monospaced))
                        }
                    }
                }
            } else {
                Text(L("mixer.loudness.none")).foregroundStyle(.secondary)
            }
            Text(L("mixer.loudness.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// 竖表：0 … −60 dBFS 线性，nil = −∞。提案 017 之后画"RMS 实心条 + 峰值细线"：实心条到 RMS（300 ms 平均，读得出响不响），
/// 2 px 细线在峰值（L / R 取大）；没有 RMS 的读数（017 之前 / 空数组）退回峰值实心条、不画细线。
/// 分段颜色按设计方案 §7（2026-09-24 定，三处表同一套）：< −18 dBFS 绿、−18…−6 黄、≥ −6 红；细线按它所在的那一段上色。
struct MeterBar: View {
    let peakDb: [Double]?
    var rmsDb: [Double]? = nil
    /// 表高比例：−18 dBFS = 0.7，−6 dBFS = 0.9（−60…0 线性）。
    static let yellowFrom = 0.7, redFrom = 0.9
    /// 峰值细线的粗细（点）。
    static let peakLineHeight: CGFloat = 2

    /// dBFS → 表高比例（−60…0 → 0…1）；nil / 低于静音线 = 0。
    static func fraction(_ db: Double?) -> Double {
        guard let db, db > MixerModel.silenceDb else { return 0 }
        return min(max(1 + db / 60, 0), 1)
    }

    /// 实心条的高度与峰值细线的位置（表高比例）。有 RMS：条 = RMS、线 = 峰值（静音不画线）；没有 RMS：条 = 峰值、没有线。
    static func levels(peakDb: [Double]?, rmsDb: [Double]?) -> (bar: Double, peakLine: Double?) {
        let peak = fraction(peakDb?.max())
        guard let rms = rmsDb, !rms.isEmpty else { return (peak, nil) }
        return (fraction(rms.max()), peak > 0 ? peak : nil)
    }

    /// 某个高度上的分段颜色。
    static func segmentColor(at fraction: Double) -> Color {
        if fraction >= redFrom { return Color(nsColor: Theme.recording) }
        if fraction >= yellowFrom { return Color(nsColor: .systemYellow) }
        return Color(nsColor: Theme.meterGreen)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let (bar, line) = Self.levels(peakDb: peakDb, rmsDb: rmsDb)
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: Theme.divider))
                Rectangle().fill(Self.segmentColor(at: 0)).frame(height: h * min(bar, Self.yellowFrom))
                Rectangle().fill(Self.segmentColor(at: Self.yellowFrom)).frame(height: h * max(0, min(bar, Self.redFrom) - Self.yellowFrom)).offset(y: -h * Self.yellowFrom)
                Rectangle().fill(Self.segmentColor(at: Self.redFrom)).frame(height: h * max(0, bar - Self.redFrom)).offset(y: -h * Self.redFrom)
                if let line {
                    // 细线以峰值为中心，贴顶 / 贴底时不出表
                    Rectangle().fill(Self.segmentColor(at: line)).frame(height: Self.peakLineHeight)
                        .offset(y: -max(0, min(h * line - Self.peakLineHeight / 2, h - Self.peakLineHeight)))
                }
                ForEach([0.0, -6, -12, -24, -40], id: \.self) { db in
                    Rectangle().fill(db == 0 ? Color(nsColor: Theme.recording) : Color(nsColor: Theme.dimText)).frame(height: 1)
                        .offset(y: -geo.size.height * (1 + db / 60) + 1)
                }
            }
        }
        .frame(width: 10)
        .accessibilityLabel(L("mixer.meter"))
        .accessibilityValue(peakDb.map { MixerModel.peakText($0) } ?? "−∞ dBFS")
    }
}

/// 竖推子（NSSlider）：SwiftUI 的 Slider 只有横的。
struct VerticalFader: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var label: String
    var onChange: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let s = NSSlider()
        s.isVertical = true
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        s.doubleValue = value
        s.numberOfTickMarks = 7
        s.allowsTickMarkValuesOnly = false
        s.isContinuous = true
        s.controlSize = .small
        s.target = context.coordinator
        s.action = #selector(Coordinator.changed(_:))
        s.setAccessibilityLabel(label)
        s.cell?.setAccessibilityLabel(label)
        s.setContentHuggingPriority(.defaultLow, for: .vertical)
        return s
    }

    func updateNSView(_ s: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        s.setAccessibilityLabel(label)
        s.cell?.setAccessibilityLabel(label)
        if !context.coordinator.dragging, abs(s.doubleValue - value) > 0.05 { s.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        var dragging = false
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func changed(_ s: NSSlider) {
            dragging = NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .leftMouseDown
            onChange(s.doubleValue)
        }
    }
}

/// 声像滑块（V-27）：中点有刻度、轨道不填充。系统滑块从最小值往把手填强调色，pan = 0 时显示半条蓝，像是偏了一半；带刻度也照填（探针确认）、
/// trackFillColor 只是换色，所以自己画轨道（PanSliderCell），把手仍是系统的。
struct PanSlider: NSViewRepresentable {
    var value: Double
    var label: String
    var onChange: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let s = NSSlider()
        s.cell = PanSliderCell()
        s.minValue = -1
        s.maxValue = 1
        s.doubleValue = value
        s.isContinuous = true
        s.controlSize = .mini
        s.target = context.coordinator
        s.action = #selector(Coordinator.changed(_:))
        s.setAccessibilityLabel(label)
        s.cell?.setAccessibilityLabel(label)
        return s
    }

    func updateNSView(_ s: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        s.setAccessibilityLabel(label)
        s.cell?.setAccessibilityLabel(label)
        if !context.coordinator.dragging, abs(s.doubleValue - value) > 0.005 { s.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        var dragging = false
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func changed(_ s: NSSlider) {
            dragging = NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .leftMouseDown
            onChange(s.doubleValue)
        }
    }
}

/// 声像滑块的轨道：一条同色细轨 + 中点一道刻度（把手在 0 时正好盖住它）。
final class PanSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        Theme.sliderTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        Theme.text.setFill()
        NSRect(x: rect.midX.rounded() - 0.5, y: rect.midY - 5, width: 1, height: 10).fill()
    }
}
