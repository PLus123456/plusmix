// 音频设置窗（W5-K，prompt 97 交付 4，01a J2–J5 / 02 X12）：每条总线 / 每路输入一扇独立窗"音频设置 — Master / 输入 n"（同一条只开一个），
// 原来调音台总线条的"效果 (n)"开的是挂在主窗口上的 SwiftUI sheet——开着时主窗口不是 key 窗口，快捷键全失灵（X12，S1）。
// 窗左常驻这一条推子后的电平表（读调音台同一份 50 ms 的 AudioEngineStatus，MixerMeters），左侧分页 常规 / 均衡 / 压缩 / 限幅（只总线）；
// 噪声门 / 插件等提案 023 与后续方案。均衡 / 压缩 / 限幅每页顶部一个"启用"开关（"用 X"和"启用"合一：关 = 旁路、参数留着）+ 参数 + 复位，改了即时生效。
// 范围沿用 EffectEditorRanges（界面 ⊆ 引擎钳位，AudioEffectsTests 钉着），EQ 段数上限 3（一个 AUNBandEQ 格最多 16 段）。
// 压缩页（W5-O，提案 024 (b)；问题单 W1D3-app-monitor-source-and-input-effects-wiring 第 4 条）：顶上选"压缩器（阈值 + 比例）"= 自写 C 压缩器 compressor
// 或"苹果动态处理器（阈值 + 压缩量）"= dynamicsProcessor，同一格二选一，新开默认是压缩器。压缩器简单模式给阈值 / 比例 / 补偿，拐点 / 起音 / 释放放"高级"，
// 范围 = 引擎的 EffectParameterRanges["compressor"]；"延迟自测"一行读引擎冲激法量到的延迟（调音台同一份 50 ms 状态，MixerMeters；按设计 0）。
// 动态处理器照旧"阈值 + 压缩量 + 输出增益"（压缩量就是 AUDynamicsProcessor 的 headroom，不冒充固定比例），起音 / 释放 / 扩展比放"高级"。
// 限幅页多一个"天花板"（peakLimiter.ceilingDb，−20…0 dBFS：限幅之后同一格内的输出增益，提案 024 顺带 (2)）。
// 每路的效果格 102 之前还没作用到声音：输入的均衡 / 压缩页照留"效果尚未作用到声音（本版本）"的横幅（AudioEffectsSupport）。
// 常规页只读格式 + 推子读数（前级增益 / 自动增益先不加，J5 有意保留）。模型只发 setBusEffects / setInputSettings，快照回来再刷新。
import AppKit
import SwiftUI
import SwitcherContracts

/// 调音台上的一条：总线或输入。
enum AudioStrip: Hashable {
    case bus(Bus)
    case input(Int)
}

enum AudioSettingsPage: String, CaseIterable, Identifiable {
    case general, eq, compressor, limiter
    var id: String { rawValue }
    var title: String { L("audioSettings.page.\(rawValue)") }
}

@MainActor
final class AudioSettingsModel: ObservableObject {
    let strip: AudioStrip
    @Published var page: AudioSettingsPage
    @Published private(set) var state: MixerState
    var send: ((Command) -> Void)?
    /// 我们刚发出去还没回来的效果链：快照没赶上前别用旧值盖掉表单（同输入设置窗）。
    private var pendingSlots: [EffectSlot]?
    private var pendingSince = Date.distantPast
    @Published private var localSlots: [EffectSlot]
    /// 打开"输入设置"窗（输入的常规页上的按钮）。
    var onOpenInputSettings: ((Int) -> Void)?

    /// 限幅页"起音就是前瞻"那一句按总线分开（W5-P，W4C3 第 4 条）：G8b 接了 W1-B4 之后 Master 的效果延迟由画面一起延后来对齐（状态窗写着视频延后 n ms），
    /// Master 的监听不再晚于画面；Bus A / B（耳机）自己的延迟没补，照旧"监听会晚这么多"。
    var limiterLatencyHint: String {
        strip == .bus(.master) ? L("audioSettings.limiter.latencyHintMaster") : L("audioSettings.limiter.latencyHint")
    }

    init(strip: AudioStrip, state: MixerState, page: AudioSettingsPage = .general) {
        self.strip = strip
        self.state = state
        self.page = page
        localSlots = Self.slots(of: strip, in: state)
    }

    /// 总线有限幅一页，输入没有（限幅只在总线上，J4）。
    var pages: [AudioSettingsPage] {
        if case .bus = strip { return [.general, .eq, .compressor, .limiter] }
        return [.general, .eq, .compressor]
    }

    var stripTitle: String {
        switch strip {
        case .bus(let bus): L("bus.\(bus.name)")
        case .input(let n): L("audioSettings.inputTitle", n)
        }
    }

    var windowTitle: String { L("audioSettings.windowTitle", stripTitle) }

    static func slots(of strip: AudioStrip, in state: MixerState) -> [EffectSlot] {
        switch strip {
        case .bus(let bus): state.audio.buses.first { $0.bus == bus }?.effects ?? []
        case .input(let n): state.input(n)?.settings.effects ?? []
        }
    }

    /// 这扇窗用得到的那部分快照（总线 / 这一路的设置）：转场 / 叠加动画期间快照每拍都变，没变的不重画（主窗口每帧重设控件会拖慢点击，W5-F 的坑）。
    private static func relevant(_ s: MixerState, _ strip: AudioStrip) -> [AnyHashable] {
        switch strip {
        case .bus: [AnyHashable(s.audio.buses)]
        case .input(let n): [AnyHashable(s.input(n)), AnyHashable(s.audio.buses)]
        }
    }

    func apply(state: MixerState) {
        guard Self.relevant(state, strip) != Self.relevant(self.state, strip) else { return }
        self.state = state
        let incoming = Self.slots(of: strip, in: state)
        if let p = pendingSlots {
            if incoming == p || Date().timeIntervalSince(pendingSince) > 0.3 {
                pendingSlots = nil
                if incoming != localSlots { localSlots = incoming }
            }
        } else if incoming != localSlots {
            localSlots = incoming
        }
    }

    // MARK: 效果链（EffectChainEditor 是值模型）

    var editor: EffectChainEditor { EffectChainEditor(slots: localSlots) }

    /// 改一项：本地先改（表单立刻响应），再整条发出去（setBusEffects / setInputSettings）。
    func edit(_ body: (inout EffectChainEditor) -> Void) {
        var e = editor
        body(&e)
        let slots = e.slots
        guard slots != localSlots else { return }
        localSlots = slots
        pendingSlots = slots
        pendingSince = Date()
        switch strip {
        case .bus(let bus):
            send?(.setBusEffects(bus: bus, effects: slots))
        case .input(let n):
            guard var settings = state.input(n)?.settings else { return }
            settings.effects = slots
            send?(.setInputSettings(input: n, settings: settings))
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<EffectChainEditor, T>) -> Binding<T> {
        Binding(get: { self.editor[keyPath: keyPath] }, set: { v in self.edit { $0[keyPath: keyPath] = v } })
    }

    /// 均衡 / 压缩 / 限幅页的横幅：效果还没作用到声音的那一半（每路 102 之前）。
    var effectsBanner: String? {
        switch strip {
        case .bus: AudioEffectsSupport.banner(applied: AudioEffectsSupport.busEffectsApplied)
        case .input: AudioEffectsSupport.banner(applied: AudioEffectsSupport.inputEffectsApplied)
        }
    }

    // MARK: 每页顶部的"启用"（"用 X"和"启用"合一：关 = 旁路、参数留着）

    var eqEnabled: Bool { editor.eq.contains { $0.enabled } }
    func setEQEnabled(_ on: Bool) {
        edit { e in
            if on && e.eq.isEmpty { e.eq = [Self.defaultBand(index: 0)] }
            for i in e.eq.indices { e.eq[i].enabled = on }
        }
    }

    /// 压缩页用的是哪一种（同一格二选一）；还没装时显示新开的默认——自写压缩器。
    var compressorKind: EffectChainEditor.DynamicsKind { editor.dynamicsKind ?? .compressor }
    func setCompressorKind(_ kind: EffectChainEditor.DynamicsKind) { edit { $0.setDynamicsKind(kind) } }

    var compressorEnabled: Bool {
        let e = editor
        switch e.dynamicsKind {
        case .compressor?: return e.compressor.enabled
        case .dynamicsProcessor?: return e.dynamics.enabled
        case nil: return false
        }
    }
    /// 启用 / 旁路动态格；还没装时启用 = 装一个自写压缩器（W5-O 起的默认，提案 024 (b)）。
    func setCompressorEnabled(_ on: Bool) {
        edit { e in
            if e.dynamicsKind == nil {
                guard on else { return }
                e.compressor.present = true
            }
            if e.compressor.present { e.compressor.enabled = on } else { e.dynamics.enabled = on }
        }
    }

    var limiterEnabled: Bool { editor.limiter.present && editor.limiter.enabled }
    func setLimiterEnabled(_ on: Bool) {
        edit { e in
            if on { e.limiter.present = true }
            e.limiter.enabled = on
        }
    }

    // MARK: 复位（参数回默认，开没开不动）

    /// 新加的第 n 段 EQ 默认放在哪：低 / 中 / 高（100 Hz / 1 kHz / 8 kHz），0 dB。
    static let defaultBandCenters: [Double] = [100, 1000, 8000]
    static func defaultBand(index: Int) -> EffectChainEditor.EQBand {
        var b = EffectChainEditor.EQBand()
        b.centerHz = defaultBandCenters[min(index, defaultBandCenters.count - 1)]
        return b
    }

    func addEQBand() {
        edit { e in
            guard e.eq.count < EffectChainEditor.maxEQBands else { return }
            var b = Self.defaultBand(index: e.eq.count)
            b.enabled = e.eq.isEmpty || e.eq.contains { $0.enabled }
            e.eq.append(b)
        }
    }

    func removeEQBand(at index: Int) { edit { e in if e.eq.indices.contains(index) { e.eq.remove(at: index) } } }

    /// 第 i 段 EQ 的一个参数（按下标：EffectChainEditor 每次从链重建、段的 id 不稳定；下标越界读 0、写不动）。
    func bandBinding(_ index: Int, _ keyPath: WritableKeyPath<EffectChainEditor.EQBand, Double>) -> Binding<Double> {
        Binding(get: {
            let eq = self.editor.eq
            return eq.indices.contains(index) ? eq[index][keyPath: keyPath] : 0
        }, set: { v in
            self.edit { e in if e.eq.indices.contains(index) { e.eq[index][keyPath: keyPath] = v } }
        })
    }

    func resetEQ() {
        edit { e in
            for i in e.eq.indices {
                let on = e.eq[i].enabled
                e.eq[i] = Self.defaultBand(index: i)
                e.eq[i].enabled = on
            }
        }
    }

    func resetCompressor() {
        edit { e in
            if e.compressor.present {
                let enabled = e.compressor.enabled
                e.compressor = EffectChainEditor.Compressor()
                e.compressor.present = true
                e.compressor.enabled = enabled
            } else {
                let (present, enabled) = (e.dynamics.present, e.dynamics.enabled)
                e.dynamics = EffectChainEditor.Dynamics()
                e.dynamics.present = present
                e.dynamics.enabled = enabled
            }
        }
    }

    /// 压缩页"延迟自测"一行（只给自写压缩器：动态处理器是 AU，延迟本来就算在这条的效果延迟里）：引擎装上压缩器后用冲激法量的实际延迟，
    /// 按设计 0 帧；还没量到（刚装、引擎还没换进去）写"还没量到"。不是压缩器时为 nil（不显示这一行）。
    func compressorLatencyFrames(_ meters: MixerMeters) -> Int? {
        switch strip {
        case .bus(let bus): meters.busCompressorLatencyFrames[bus]
        case .input(let n): meters.inputCompressorLatencyFrames[n]
        }
    }

    func compressorLatencyText(_ meters: MixerMeters) -> String? {
        guard editor.dynamicsKind == .compressor else { return nil }
        guard let frames = compressorLatencyFrames(meters) else { return L("audioSettings.compressor.latencyPending") }
        return L("audioSettings.compressor.latency", frames, Double(frames) / 48.0)
    }

    func resetLimiter() {
        edit { e in
            let (present, enabled) = (e.limiter.present, e.limiter.enabled)
            e.limiter = EffectChainEditor.Limiter()
            e.limiter.present = present
            e.limiter.enabled = enabled
        }
    }

    // MARK: 常规页（只读格式 + 推子读数）

    /// 引擎的格式（混音器全是 48 kHz 立体声，设计方案 §3.5）。
    var formatText: String { L("audioSettings.general.formatValue") }

    var faderDb: Double {
        switch strip {
        case .bus(let bus): state.audio.buses.first { $0.bus == bus }?.gainDb ?? 0
        case .input(let n): state.input(n)?.settings.audio.gainDb ?? 0
        }
    }
    var faderText: String { MixerModel.gainText(faderDb) }

    var isMuted: Bool {
        switch strip {
        case .bus(let bus): state.audio.buses.first { $0.bus == bus }?.muted ?? false
        case .input(let n): state.input(n)?.settings.audio.muted ?? false
        }
    }

    /// 表的读数（推子后，调音台同一份 50 ms 读数）。
    func meter(_ meters: MixerMeters) -> (peak: [Double]?, rms: [Double]?) {
        switch strip {
        case .bus(let bus): (meters.busPeakDb[bus], meters.busRmsDb[bus])
        case .input(let n): (meters.inputPeakDb[n], meters.inputRmsDb[n])
        }
    }
}

struct AudioSettingsView: View {
    @ObservedObject var model: AudioSettingsModel
    @ObservedObject var meters: MixerMeters
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                meterColumn
                Divider()
                List(model.pages, selection: pageSelection) { p in Text(p.title).tag(p) }
                    .listStyle(.sidebar)
                    .frame(width: 120)
                    .accessibilityLabel(L("audioSettings.pageList"))
                Divider()
                Form { pageBody }.formStyle(.grouped)
            }
            Divider()
            HStack {
                Text(model.windowTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("common.close")) { onClose() }
            }
            .padding(10)
        }
    }

    private var pageSelection: Binding<AudioSettingsPage?> {
        Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })
    }

    /// 窗左常驻这一条推子后的电平表（J4）。
    private var meterColumn: some View {
        let m = model.meter(meters)
        return VStack(spacing: 6) {
            Text(L("audioSettings.meterPost")).font(.system(size: 9)).foregroundStyle(.secondary)
            MeterBar(peakDb: m.peak, rmsDb: m.rms)
                .frame(width: 14)
                .frame(maxHeight: .infinity)
            Text(MixerModel.peakText(m.peak ?? [])).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.vertical, 12)
        .frame(width: 64)
    }

    @ViewBuilder
    private var pageBody: some View {
        switch model.page {
        case .general: general
        case .eq: eq
        case .compressor: compressor
        case .limiter: limiter
        }
    }

    private var banner: some View {
        Group {
            if let banner = model.effectsBanner {
                Section {
                    Text(banner).font(.headline).foregroundStyle(.orange)
                    Text(L("effects.notEffectiveHelp")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var general: some View {
        Section(L("audioSettings.page.general")) {
            LabeledContent(L("audioSettings.general.format"), value: model.formatText)
            LabeledContent(L("audioSettings.general.fader"), value: model.faderText)
            LabeledContent(L("audioSettings.general.mute"), value: model.isMuted ? L("common.on") : L("common.off"))
            Text(L("audioSettings.general.hint")).font(.caption).foregroundStyle(.secondary)
            if case .input(let n) = model.strip {
                Button(L("audioSettings.general.openInputSettings")) { model.onOpenInputSettings?(n) }
            }
        }
    }

    private func enableRow(_ on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(L("audioSettings.enabled"), isOn: Binding(get: { on }, set: set))
            .toggleStyle(.switch)
    }

    @ViewBuilder
    private var eq: some View {
        banner
        Section(L("effects.eq.title")) {
            enableRow(model.eqEnabled) { model.setEQEnabled($0) }
            let bands = model.editor.eq
            ForEach(Array(bands.indices), id: \.self) { i in
                let band = bands[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("audioSettings.eq.band", i + 1)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(L("effects.eq.remove")) { model.removeEQBand(at: i) }
                    }
                    Slider(value: model.bandBinding(i, \.centerHz), in: EffectEditorRanges.eqCenterHz) { Text(L("effects.eq.centerHz", Int(band.centerHz))) }
                    Slider(value: model.bandBinding(i, \.q), in: EffectEditorRanges.eqQ) { Text(L("effects.eq.q", band.q)) }
                    Slider(value: model.bandBinding(i, \.gainDb), in: EffectEditorRanges.eqGainDb) { Text(L("effects.eq.gainDb", band.gainDb)) }
                }
                .disabled(!band.enabled)
            }
            HStack {
                if model.editor.eq.count < EffectChainEditor.maxEQBands {
                    Button(L("effects.eq.add")) { model.addEQBand() }
                }
                Spacer()
                Button(L("audioSettings.reset")) { model.resetEQ() }
            }
        }
    }

    @ViewBuilder
    private var compressor: some View {
        banner
        Section(L("effects.dynamics.title")) {
            enableRow(model.compressorEnabled) { model.setCompressorEnabled($0) }
            Picker(L("audioSettings.compressor.kind"), selection: Binding(get: { model.compressorKind }, set: { model.setCompressorKind($0) })) {
                ForEach(EffectChainEditor.DynamicsKind.allCases) { kind in Text(L("audioSettings.compressor.kind.\(kind.rawValue)")).tag(kind) }
            }
            Group {
                switch model.compressorKind {
                case .compressor: simpleCompressor
                case .dynamicsProcessor: dynamicsProcessor
                }
            }
            .disabled(!model.compressorEnabled)
            if let latency = model.compressorLatencyText(meters) {
                Text(latency).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("audioSettings.reset")) { model.resetCompressor() }
            }
        }
    }

    /// 自写压缩器（提案 024 (b)）简单模式：阈值 / 比例 / 补偿；拐点 / 起音 / 释放放"高级"。
    @ViewBuilder
    private var simpleCompressor: some View {
        let c = model.editor.compressor
        Slider(value: model.binding(\.compressor.thresholdDb), in: EffectEditorRanges.compThresholdDb) { Text(L("effects.dynamics.thresholdDb", c.thresholdDb)) }
        Slider(value: model.binding(\.compressor.ratio), in: EffectEditorRanges.compRatio) { Text(L("audioSettings.compressor.ratio", c.ratio)) }
        Slider(value: model.binding(\.compressor.makeupGainDb), in: EffectEditorRanges.compMakeupGainDb) { Text(L("audioSettings.compressor.makeupGain", c.makeupGainDb)) }
        DisclosureGroup(L("audioSettings.advanced")) {
            Slider(value: model.binding(\.compressor.kneeDb), in: EffectEditorRanges.compKneeDb) { Text(L("audioSettings.compressor.knee", c.kneeDb)) }
            Slider(value: model.binding(\.compressor.attackSeconds), in: EffectEditorRanges.compAttackSeconds) { Text(L("effects.dynamics.attackMs", c.attackSeconds * 1000)) }
            Slider(value: model.binding(\.compressor.releaseSeconds), in: EffectEditorRanges.compReleaseSeconds) { Text(L("effects.dynamics.releaseMs", c.releaseSeconds * 1000)) }
        }
    }

    /// 动态处理器（AUDynamicsProcessor）："阈值 + 压缩量 + 输出增益"，压缩量就是 headroom（不冒充固定比例）；起音 / 释放 / 扩展比放"高级"。
    @ViewBuilder
    private var dynamicsProcessor: some View {
        let d = model.editor.dynamics
        Slider(value: model.binding(\.dynamics.thresholdDb), in: EffectEditorRanges.dynThresholdDb) { Text(L("effects.dynamics.thresholdDb", d.thresholdDb)) }
        Slider(value: model.binding(\.dynamics.headroomDb), in: EffectEditorRanges.dynHeadroomDb) { Text(L("audioSettings.compressor.amount", d.headroomDb)) }
        Text(L("audioSettings.compressor.amountHint", d.thresholdDb + d.headroomDb)).font(.caption).foregroundStyle(.secondary)
        Slider(value: model.binding(\.dynamics.overallGainDb), in: EffectEditorRanges.dynOverallGainDb) { Text(L("audioSettings.compressor.makeup", d.overallGainDb)) }
        DisclosureGroup(L("audioSettings.advanced")) {
            Slider(value: model.binding(\.dynamics.attackSeconds), in: EffectEditorRanges.dynAttackSeconds) { Text(L("effects.dynamics.attackMs", d.attackSeconds * 1000)) }
            Slider(value: model.binding(\.dynamics.releaseSeconds), in: EffectEditorRanges.dynReleaseSeconds) { Text(L("effects.dynamics.releaseMs", d.releaseSeconds * 1000)) }
            Slider(value: model.binding(\.dynamics.expansionRatio), in: EffectEditorRanges.dynExpansionRatio) { Text(L("effects.dynamics.expansionRatio", d.expansionRatio)) }
        }
    }

    @ViewBuilder
    private var limiter: some View {
        banner
        let l = model.editor.limiter
        Section(L("effects.limiter.title")) {
            enableRow(model.limiterEnabled) { model.setLimiterEnabled($0) }
            Group {
                Slider(value: model.binding(\.limiter.attackSeconds), in: EffectEditorRanges.limAttackSeconds) { Text(L("effects.limiter.attackMs", l.attackSeconds * 1000)) }
                Text(model.limiterLatencyHint).font(.caption).foregroundStyle(.secondary)
                Slider(value: model.binding(\.limiter.decaySeconds), in: EffectEditorRanges.limDecaySeconds) { Text(L("effects.limiter.decayMs", l.decaySeconds * 1000)) }
                Slider(value: model.binding(\.limiter.preGainDb), in: EffectEditorRanges.limPreGainDb) { Text(L("effects.limiter.preGainDb", l.preGainDb)) }
                Slider(value: model.binding(\.limiter.ceilingDb), in: EffectEditorRanges.limCeilingDb) { Text(L("audioSettings.limiter.ceiling", l.ceilingDb)) }
                Text(L("audioSettings.limiter.ceilingHint")).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.limiterEnabled)
            HStack {
                Spacer()
                Button(L("audioSettings.reset")) { model.resetLimiter() }
            }
        }
    }
}

/// 音频设置窗：每条一个（PanelCoordinator 管）；换 session 时关（模型绑的是旧 session）。不是 sheet，开着时主窗口照常点、照常收快捷键。
@MainActor
final class AudioSettingsWindowController: PanelWindowController {
    let model: AudioSettingsModel

    init(model: AudioSettingsModel, meters: MixerMeters) {
        self.model = model
        let close = CloseBox()
        super.init(title: model.windowTitle, size: NSSize(width: 640, height: 500), autosaveName: Self.autosaveName(model.strip),
                   content: AudioSettingsView(model: model, meters: meters, onClose: { close.action?() }), minSize: NSSize(width: 540, height: 400))
        close.action = { [weak self] in self?.close() }
    }

    /// 存档名按条分开（几扇同时开不叠在一起）。
    static func autosaveName(_ strip: AudioStrip) -> String {
        switch strip {
        case .bus(let bus): "AudioSettings-\(bus.name)"
        case .input(let n): "AudioSettings-input-\(n)"
        }
    }

    func apply(state: MixerState) { model.apply(state: state) }

    /// SwiftUI 视图要在 super.init 之前建好，"关闭"按钮的动作之后再接上。
    private final class CloseBox { var action: (() -> Void)? }
}
