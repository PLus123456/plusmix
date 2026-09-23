// 右侧可收起的调音台（W3-E 交付第 4 条）：每路条子（表、推子、静音、独听、声像、总线送出、跟随视频开关 + AFV 门控）、四总线（表、推子、静音、效果链）、
// AFV 总开关、监听选择（PFL / AFL）。SwiftUI 表单放 NSHostingView；动作只发 Command，显示只读快照。
// 表的数字只有一个来源（AudioMixer.meters，铁律 4）：读数文字 + A1 计数从 1 Hz 的 Stats.audio.meters 来（提案 004）；
// 条子按 AudioEngineStatus（控制循环每 50 ms 刷新的同一份读数）每 50 ms 刷，UI 高刷新率的表允许另读这一份（Stats.swift 的说明）。
// 监听方式 / 总线效果链走提案 012 的 setMonitorMode / setBusEffects（P3 落地）；每路"跟随视频"= InputAudioSettings.afv（用户 2026-09-22 批），
// 走 setInputSettings，门控显示读 AudioEngineStatus.afvGain（afv = false 的路引擎恒给 1 = 0 dB）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherAudioIntegration

/// 表的读数（50 ms）：输入 / 总线的推子后峰值（dBFS，[L, R]）与 AFV 门控。
@MainActor
final class MixerMeters: ObservableObject {
    @Published private(set) var inputPeakDb: [Int: [Double]] = [:]
    @Published private(set) var busPeakDb: [Bus: [Double]] = [:]
    @Published private(set) var afvGain: [Int: Float] = [:]
    @Published private(set) var busLoudnessLUFS: [Bus: Double] = [:]

    func clear() {
        inputPeakDb = [:]
        busPeakDb = [:]
        afvGain = [:]
        busLoudnessLUFS = [:]
    }

    func apply(status: AudioEngineStatus) {
        var inputs: [Int: [Double]] = [:]
        var gains: [Int: Float] = [:]
        for i in status.inputs where !i.removing {
            inputs[i.number] = i.peakDb
            gains[i.number] = i.afvGain
        }
        var buses: [Bus: [Double]] = [:]
        var lufs: [Bus: Double] = [:]
        for b in status.buses {
            buses[b.bus] = b.peakDb
            lufs[b.bus] = b.shortTermLUFS
        }
        if inputs != inputPeakDb { inputPeakDb = inputs }
        if gains != afvGain { afvGain = gains }
        if buses != busPeakDb { busPeakDb = buses }
        if lufs != busLoudnessLUFS { busLoudnessLUFS = lufs }
    }
}

/// 调音台的状态与动作。
@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var state = MixerState()
    /// A1 计数 + Master 读数文字（Stats，1 Hz）。
    @Published private(set) var statsText = ""
    @Published private(set) var masterPeakText = "−∞ dBFS"
    var send: ((Command) -> Void)?
    var onOpenInputSettings: ((Int) -> Void)?

    /// 推子范围（dB）。
    static let faderRange = -60.0...12.0
    /// 低于它显示 −∞（Stats 的 dB 下限是 −120）。
    static let silenceDb = -119.0

    var inputNumbers: [Int] { state.inputs.map(\.number) }

    func apply(state: MixerState) { self.state = state }

    func apply(stats: Stats) {
        let a = stats.audio
        statsText = L("mixer.a1", Int(a.dropouts), Int(a.underruns), Int(a.discontinuities))
        if let master = a.meters.buses.first(where: { $0.bus == Bus.master.name }) {
            masterPeakText = Self.peakText(master.peakDb)
        } else {
            masterPeakText = "−∞ dBFS"
        }
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
}

/// AppKit 容器：主窗口右栏；SwiftUI 内容 + 50 ms 的表定时器。
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
    /// 音频引擎（换 session 时换）；nil = 表不动。
    var audio: AudioRuntime? {
        didSet { restartMeterTimer() }
    }
    private var meterTimer: Timer?
    private let host: NSHostingView<MixerView>
    /// 最近一次从 Stats 读到的 Master 峰值（dBFS，[L, R]；nil = 还没有）。测试看。
    private(set) var masterPeakDb: [Double]?
    /// 表的刷新间隔（与 AudioEngine.statusInterval 一样 50 ms）。
    static let meterInterval: TimeInterval = 0.05

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

    /// 1 Hz：读数文字 + A1。
    func apply(stats: Stats) {
        model.apply(stats: stats)
        masterPeakDb = stats.audio.meters.buses.first { $0.bus == Bus.master.name }?.peakDb
    }

    private func restartMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        meters.clear()
        guard audio != nil else { return }
        let t = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeters() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func refreshMeters() {
        guard let audio else { meters.clear(); return }
        meters.apply(status: audio.status)
        onMeters?(meters.inputPeakDb)
    }

    /// 每次刷表之后（50 ms）：把每路读数转给别处用（纯音频输入的缩略图格子画电平表），同一份数。
    var onMeters: (([Int: [Double]]) -> Void)?

    var displayedGain: String { MixerModel.gainText(model.busState(.master).gainDb) }
    var displayedPeak: String { model.masterPeakText }
}

// MARK: - SwiftUI

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var meters: MixerMeters
    @State private var effectsBus: Bus?

    var body: some View {
        VStack(spacing: 6) {
            header
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(model.state.inputs) { input in
                        MixerInputStrip(model: model, meters: meters, input: input)
                    }
                    if !model.state.inputs.isEmpty { Divider().frame(height: 300) }
                    ForEach(Bus.allCases, id: \.self) { bus in
                        MixerBusStrip(model: model, meters: meters, bus: bus) { effectsBus = bus }
                    }
                }
                .padding(.horizontal, 6)
            }
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
        .sheet(item: $effectsBus) { bus in
            BusEffectsSheet(model: model, bus: bus)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("mixer.title")).font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle(L("mixer.afv"), isOn: Binding(get: { model.state.audio.afv }, set: { model.setAFV(on: $0) }))
                .toggleStyle(.switch).controlSize(.mini)
                .help(L("mixer.afvHelp"))
            Picker(L("mixer.monitor"), selection: Binding(get: { model.state.audio.monitorMode }, set: { model.setMonitorMode($0) })) {
                Text("AFL").tag(MonitorMode.afl)
                Text("PFL").tag(MonitorMode.pfl)
            }
            .pickerStyle(.segmented).controlSize(.mini).frame(width: 90)
            .help(L("mixer.monitorHelp"))
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

extension Bus: @retroactive Identifiable {
    public var id: Int { rawValue }
}

/// 一路输入的条子。
struct MixerInputStrip: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var meters: MixerMeters
    let input: InputConfig

    private var audio: InputAudioSettings { input.settings.audio }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(input.number) \(input.name)").font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(width: 84)
            HStack(spacing: 4) {
                MeterBar(peakDb: meters.inputPeakDb[input.number])
                VerticalFader(value: audio.gainDb, range: MixerModel.faderRange, label: L("mixer.inputFader", input.number)) { model.setInputGain(input.number, dB: $0) }
            }
            .frame(height: 170)
            Text(MixerModel.gainText(audio.gainDb)).font(.system(size: 10, design: .monospaced))
            Slider(value: Binding(get: { audio.pan }, set: { model.setPan(input.number, value: $0) }), in: -1...1) { Text(L("mixer.pan", input.number)) }
                .labelsHidden().controlSize(.mini).frame(width: 80)
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
            Button(L("mixer.inputSettings")) { model.onOpenInputSettings?(input.number) }.controlSize(.mini)
        }
        .frame(width: 92)
        .padding(4)
        .background(Color(nsColor: Theme.cellBackground), in: RoundedRectangle(cornerRadius: 4))
    }

    private var afvIndicator: some View {
        Text(MixerModel.afvGateText(globalAFV: model.state.audio.afv, gain: meters.afvGain[input.number]))
            .font(.system(size: 9)).foregroundStyle(.secondary).help(L("mixer.afvIndicatorHelp"))
    }
}

/// 一条总线的条子。
struct MixerBusStrip: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var meters: MixerMeters
    let bus: Bus
    let onEffects: () -> Void

    var body: some View {
        let s = model.busState(bus)
        VStack(spacing: 4) {
            Text(L("bus.\(bus.name)")).font(.system(size: 11, weight: .semibold)).frame(width: 84)
            HStack(spacing: 4) {
                MeterBar(peakDb: meters.busPeakDb[bus])
                VerticalFader(value: s.gainDb, range: MixerModel.faderRange, label: L("mixer.busFader", L("bus.\(bus.name)"))) { model.setBusGain(bus, dB: $0) }
            }
            .frame(height: 170)
            Text(MixerModel.gainText(s.gainDb)).font(.system(size: 10, design: .monospaced))
            Text(meters.busLoudnessLUFS[bus].map { $0 > -100 ? String(format: "%.1f LUFS", $0) : "— LUFS" } ?? "— LUFS")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).help(L("mixer.lufsHelp"))
            Toggle(L("mixer.mute"), isOn: Binding(get: { s.muted }, set: { model.setBusMute(bus, on: $0) }))
                .toggleStyle(.button).controlSize(.mini)
            Button(L("mixer.effects", s.effects.count)) { onEffects() }.controlSize(.mini)
        }
        .frame(width: 92)
        .padding(4)
        .background(Color(nsColor: Theme.cellBackground), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 总线效果链的 sheet。
struct BusEffectsSheet: View {
    @ObservedObject var model: MixerModel
    let bus: Bus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                EffectChainView(editor: Binding(get: { EffectChainEditor(slots: model.busState(bus).effects) }, set: { model.setBusEffects(bus, $0.slots) }))
                Text(L("mixer.busEffectsHint")).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(L("mixer.busEffectsTitle", L("bus.\(bus.name)"))).font(.headline)
                Spacer()
                Button(L("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 420, height: 520)
    }
}

/// 竖表：0 … −60 dBFS，nil = −∞。分段颜色按设计方案 §7（2026-09-24 定，三处表同一套）：< −18 dBFS 绿、−18…−6 黄、≥ −6 红。
struct MeterBar: View {
    let peakDb: [Double]?
    /// 表高比例：−18 dBFS = 0.7，−6 dBFS = 0.9（−60…0 线性）。
    static let yellowFrom = 0.7, redFrom = 0.9

    var body: some View {
        GeometryReader { geo in
            let level = peakDb?.max().flatMap { $0 > MixerModel.silenceDb ? $0 : nil }
            let fraction = level.map { min(max(1 + $0 / 60, 0), 1) } ?? 0
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: Theme.divider))
                Rectangle().fill(Color(nsColor: Theme.tallyPreview)).frame(height: h * min(fraction, Self.yellowFrom))
                Rectangle().fill(Color(nsColor: .systemYellow)).frame(height: h * max(0, min(fraction, Self.redFrom) - Self.yellowFrom)).offset(y: -h * Self.yellowFrom)
                Rectangle().fill(Color(nsColor: Theme.recording)).frame(height: h * max(0, fraction - Self.redFrom)).offset(y: -h * Self.redFrom)
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
