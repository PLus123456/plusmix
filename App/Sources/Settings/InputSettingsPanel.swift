// 输入设置窗（W3-E 交付第 2 条）：裁切 / 变换、延迟补偿（0–500 ms）、音频路由（四总线）、增益 / 静音 / 独听 / 声像、抠像参数、
// 效果链（W5-B 起叫"音频效果"，引擎还不读它：页顶横幅写"效果尚未作用到声音"）、来源。模型只发 setInputSettings / renameInput / setInputSource，快照回来再刷新表单。
// W3-E2：来源一节可编辑（提案 012 的 setInputSource：编号 / 名字 / 设置 / PGM / PVW / 叠加引用全保留，运行表按新来源重建这一路），
// 表单复用 Add Input 的 InputSourceFormView；摘要显示 DeckLink 接口、NDI 带宽 / 抖动缓冲（提案 008）与声道映射（提案 014）。
import AppKit
import Combine
import SwiftUI
import SwitcherContracts

@MainActor
final class InputSettingsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case general, geometry, audio, keyer, effects, source
        var id: String { rawValue }
        var title: String { L("inputSettings.section.\(rawValue)") }
    }

    let number: Int
    @Published var section: Section = .general
    @Published private(set) var config: InputConfig
    @Published private(set) var settings: InputSettings
    /// 名字编辑框的值（回车 / 失焦时 rename）。
    @Published var name: String
    var send: ((Command) -> Void)?
    /// 我们刚发出去还没回来的设置：快照没赶上前别用旧值盖掉表单。
    private var pending: InputSettings?
    private var pendingSince = Date.distantPast

    init(config: InputConfig) {
        number = config.number
        self.config = config
        settings = config.settings
        name = config.name
    }

    /// 改一项：本地先改（表单立刻响应），再整体替换发给状态机（reducer 会 clamped）。
    func update(_ body: (inout InputSettings) -> Void) {
        var s = settings
        body(&s)
        guard s != settings else { return }
        settings = s
        pending = s
        pendingSince = Date()
        send?(.setInputSettings(input: number, settings: s))
    }

    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != config.name else { name = config.name; return }
        name = trimmed
        send?(.renameInput(input: number, name: trimmed))
    }

    /// 快照回来：我们发的到了（相等或被 clamped 后 300 ms 内没再发）就接受。
    func apply(state: MixerState) {
        guard let c = state.input(number) else { return }
        let oldSource = config.source
        config = c
        // 来源被别处换了（API / 另一个窗口）且表单没被动过：表单跟着换；动过的留着（用户还没点应用）
        if c.source != oldSource, let form = sourceForm, (try? form.model.makeSource()) == oldSource {
            var m = AddInputModel(source: c.source)
            m.number = number
            m.name = c.name
            form.model = m
        }
        if name != c.name, pending == nil { name = c.name }
        if let p = pending {
            if c.settings == p || Date().timeIntervalSince(pendingSince) > 0.3 {
                pending = nil
                settings = c.settings
            }
        } else if c.settings != settings {
            settings = c.settings
        }
    }

    /// SwiftUI 绑定：读本地值，写走 update。
    func bind<T>(_ keyPath: WritableKeyPath<InputSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { v in self.update { $0[keyPath: keyPath] = v } })
    }

    /// 延迟补偿的 Int 绑定（0–500）。
    var delayBinding: Binding<Double> {
        Binding(get: { Double(self.settings.audio.delayMs) }, set: { v in self.update { $0.audio.delayMs = Int(v.rounded()) } })
    }

    /// "音频效果"页顶部的横幅：音频引擎还不读每路效果链（W5-B，X07；102 接上后 AudioEffectsSupport 翻了就没了）。
    var effectsBanner: String? { AudioEffectsSupport.banner(applied: AudioEffectsSupport.inputEffectsApplied) }

    var effectsBinding: Binding<EffectChainEditor> {
        Binding(get: { EffectChainEditor(slots: self.settings.effects) }, set: { e in self.update { $0.effects = e.slots } })
    }

    var keyColorBinding: Binding<Color> {
        Binding(get: {
            let k = self.settings.keyer.keyColor
            return Color(red: Double(k.red) / 255, green: Double(k.green) / 255, blue: Double(k.blue) / 255)
        }, set: { c in
            guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
            let rgb = RGB8(red: UInt8(max(0, min(255, (ns.redComponent * 255).rounded()))), green: UInt8(max(0, min(255, (ns.greenComponent * 255).rounded()))),
                           blue: UInt8(max(0, min(255, (ns.blueComponent * 255).rounded()))))
            self.update { $0.keyer.keyColor = rgb }
        })
    }

    // MARK: 来源（提案 012：setInputSource）

    /// 来源一节的表单（第一次打开那一节时建：要列设备、挂音频设备插拔订阅）。
    private(set) var sourceForm: AddInputFormModel?
    private var sourceFormChange: AnyCancellable?
    @Published private(set) var sourceError = ""

    func sourceFormModel() -> AddInputFormModel {
        if let f = sourceForm { return f }
        let f = AddInputFormModel(editing: config)
        sourceFormChange = f.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }   // "应用"按钮的可用状态跟着表单变
        sourceForm = f
        return f
    }

    /// 表单出来的来源与当前的不同（表单不完整也算不同：点应用会报缺什么）。
    var sourceChanged: Bool {
        guard let form = sourceForm else { return false }
        return (try? form.model.makeSource()) != config.source
    }

    /// 换来源：setInputSource（编号 / 名字 / 设置 / PGM / PVW / 叠加引用都保留；运行表按"编号 + 来源"变了重建这一路）。
    func applySource() {
        guard let form = sourceForm else { return }
        do {
            let source = try form.model.makeSource()
            sourceError = ""
            guard source != config.source else { return }
            send?(.setInputSource(input: number, source: source))
        } catch {
            sourceError = "\(error)"
        }
    }

    /// 表单改回当前来源。
    func revertSource() {
        guard let form = sourceForm else { return }
        var m = AddInputModel(source: config.source)
        m.number = number
        m.name = config.name
        form.model = m
        sourceError = ""
    }

    /// 窗口关掉：摘掉表单的设备插拔订阅。
    func close() {
        sourceForm?.close()
    }

    /// 声道映射（提案 014）的摘要后缀："（第 5、6 路）"；空（前两路）没有后缀。
    static func channelsSuffix(_ channels: [Int]) -> String {
        channels.isEmpty ? "" : L("inputSettings.source.channels", ChannelMapChoice.summary(channels))
    }

    /// 来源摘要。
    var sourceSummary: String {
        switch config.source {
        case .camera(let id): return L("inputSettings.source.camera", id)
        case .decklink(let id, let connection, let channels):
            let card = id.isEmpty ? L("addInput.decklink.firstCard") : id
            let port = connection.map { L("decklink.connection.\($0.rawValue)") } ?? L("addInput.decklink.connection.keep")
            return L("inputSettings.source.decklink", card, port) + Self.channelsSuffix(channels)
        case .screen(let target, let rate, let audio):
            let t: String
            switch target {
            case .display(let id): t = L("inputSettings.source.screen.display", Int(id))
            case .window(let id): t = L("inputSettings.source.screen.window", Int(id))
            case .application(let b): t = L("inputSettings.source.screen.application", b)
            }
            return L("inputSettings.source.screen", t, rate.map { "\($0)" } ?? L("addInput.screen.frameRateProgram"), audio ? L("common.on") : L("common.off"))
        case .file(let path, let end, let rate): return L("inputSettings.source.file", path, L("addInput.file.endAction.\(end.rawValue)"), rate)
        case .image(let path): return L("inputSettings.source.image", path)
        case .ndi(let name, let bandwidth, let jitter): return L("inputSettings.source.ndi", name, L("ndi.bandwidth.\(bandwidth.rawValue)"), jitter)
        case .audio(let uid, let channels):
            return L("inputSettings.source.audio", uid.isEmpty ? L("addInput.audio.systemDefault") : uid) + Self.channelsSuffix(channels)
        case .synthetic(let s): return L("inputSettings.source.synthetic", "\(s.frameRate)", s.width, s.height)
        }
    }
}

struct InputSettingsView: View {
    @ObservedObject var model: InputSettingsModel

    var body: some View {
        HStack(spacing: 0) {
            List(InputSettingsModel.Section.allCases, selection: sectionSelection) { s in Text(s.title).tag(s) }
                .listStyle(.sidebar)
                .frame(width: 150)
                .accessibilityLabel(L("inputSettings.sectionList"))
            Divider()
            Form { sectionBody }.formStyle(.grouped)
        }
    }

    private var sectionSelection: Binding<InputSettingsModel.Section?> {
        Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch model.section {
        case .general: general
        case .geometry: geometry
        case .audio: audio
        case .keyer: keyer
        case .effects:
            if let banner = model.effectsBanner {
                Section {
                    Text(banner).font(.headline).foregroundStyle(.orange)
                    Text(L("effects.notEffectiveHelp")).font(.caption).foregroundStyle(.secondary)
                }
            }
            EffectChainView(editor: model.effectsBinding)
        case .source: source
        }
    }

    private var general: some View {
        Section(L("inputSettings.general.title")) {
            LabeledContent(L("inputSettings.general.number"), value: "\(model.number)")
            TextField(L("inputSettings.general.name"), text: $model.name).onSubmit { model.rename(model.name) }
            Button(L("inputSettings.general.applyName")) { model.rename(model.name) }
            LabeledContent(L("inputSettings.general.kind"), value: L("addInput.kind.\(model.config.kind.rawValue)"))
        }
    }

    private var geometry: some View {
        Group {
            Section(L("inputSettings.crop.title")) {
                Slider(value: model.bind(\.crop.left), in: 0...1) { Text(L("inputSettings.crop.left", model.settings.crop.left * 100)) }
                Slider(value: model.bind(\.crop.top), in: 0...1) { Text(L("inputSettings.crop.top", model.settings.crop.top * 100)) }
                Slider(value: model.bind(\.crop.right), in: 0...1) { Text(L("inputSettings.crop.right", model.settings.crop.right * 100)) }
                Slider(value: model.bind(\.crop.bottom), in: 0...1) { Text(L("inputSettings.crop.bottom", model.settings.crop.bottom * 100)) }
                Button(L("inputSettings.crop.reset")) { model.update { $0.crop = .none } }
            }
            Section(L("inputSettings.transform.title")) {
                Slider(value: model.bind(\.transform.scale), in: 0.05...4) { Text(L("inputSettings.transform.scale", model.settings.transform.scale)) }
                Slider(value: model.bind(\.transform.offsetX), in: -1...1) { Text(L("inputSettings.transform.offsetX", model.settings.transform.offsetX)) }
                Slider(value: model.bind(\.transform.offsetY), in: -1...1) { Text(L("inputSettings.transform.offsetY", model.settings.transform.offsetY)) }
                Slider(value: model.bind(\.transform.rotationDegrees), in: -180...180) { Text(L("inputSettings.transform.rotation", model.settings.transform.rotationDegrees)) }
                Toggle(L("inputSettings.transform.flipH"), isOn: model.bind(\.transform.flipHorizontal))
                Toggle(L("inputSettings.transform.flipV"), isOn: model.bind(\.transform.flipVertical))
                Button(L("inputSettings.transform.reset")) { model.update { $0.transform = .identity } }
            }
        }
    }

    private var audio: some View {
        Group {
            Section(L("inputSettings.audio.title")) {
                Slider(value: model.bind(\.audio.gainDb), in: InputAudioSettings.gainRangeDb) { Text(L("inputSettings.audio.gain", model.settings.audio.gainDb)) }
                Toggle(L("inputSettings.audio.muted"), isOn: model.bind(\.audio.muted))
                Toggle(L("inputSettings.audio.solo"), isOn: model.bind(\.audio.solo))
                Slider(value: model.bind(\.audio.pan), in: -1...1) { Text(L("inputSettings.audio.pan", model.settings.audio.pan)) }
                Slider(value: model.delayBinding, in: Double(InputAudioSettings.delayRangeMs.lowerBound)...Double(InputAudioSettings.delayRangeMs.upperBound), step: 1) {
                    Text(L("inputSettings.audio.delay", model.settings.audio.delayMs))
                }
                Text(L("inputSettings.audio.delayHint")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("inputSettings.routing.title")) {
                Toggle(L("bus.master"), isOn: model.bind(\.audio.routing.master))
                Toggle(L("bus.busA"), isOn: model.bind(\.audio.routing.busA))
                Toggle(L("bus.busB"), isOn: model.bind(\.audio.routing.busB))
                Toggle(L("bus.headphones"), isOn: model.bind(\.audio.routing.headphones))
            }
        }
    }

    private var keyer: some View {
        Section(L("inputSettings.keyer.title")) {
            Toggle(L("inputSettings.keyer.enabled"), isOn: model.bind(\.keyer.enabled))
            ColorPicker(L("inputSettings.keyer.keyColor"), selection: model.keyColorBinding, supportsOpacity: false)
            Slider(value: model.bind(\.keyer.tolerance), in: 0...1) { Text(L("inputSettings.keyer.tolerance", model.settings.keyer.tolerance)) }
            Slider(value: model.bind(\.keyer.softness), in: 0...1) { Text(L("inputSettings.keyer.softness", model.settings.keyer.softness)) }
            Slider(value: model.bind(\.keyer.spillSuppression), in: 0...1) { Text(L("inputSettings.keyer.spill", model.settings.keyer.spillSuppression)) }
            Text(L("inputSettings.keyer.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var source: some View {
        let form = model.sourceFormModel()
        Section(L("inputSettings.source.title")) {
            LabeledContent(L("inputSettings.source.current"), value: model.sourceSummary)
            Picker(L("inputSettings.source.kind"), selection: Binding(get: { form.model.kind }, set: { form.model.kind = $0 })) {
                ForEach(AddInputModel.Kind.allCases) { Text($0.title).tag($0) }
            }
        }
        InputSourceFormView(form: form)
        Section {
            HStack {
                Button(L("inputSettings.source.apply")) { model.applySource() }.disabled(!model.sourceChanged)
                Button(L("inputSettings.source.revert")) { model.revertSource() }.disabled(!model.sourceChanged)
            }
            if !model.sourceError.isEmpty { Text(model.sourceError).foregroundStyle(.red) }
            Text(L("inputSettings.source.changeHint")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class InputSettingsWindowController: PanelWindowController {
    let model: InputSettingsModel

    init(model: InputSettingsModel) {
        self.model = model
        // 存档名带编号（W5-A / X44：原来所有输入共用一个，同时开几路都跳到同一个存档位置、叠在一起）
        super.init(title: L("inputSettings.windowTitle", model.number, model.config.name), size: NSSize(width: 640, height: 520),
                   autosaveName: Self.autosaveName(input: model.number), content: InputSettingsView(model: model))
    }

    static func autosaveName(input number: Int) -> String { "InputSettings-\(number)" }

    func apply(state: MixerState) {
        model.apply(state: state)
        window?.title = L("inputSettings.windowTitle", model.number, model.config.name)
    }

    override func windowWillClose(_ notification: Notification) {
        model.close()
        super.windowWillClose(notification)
    }
}
