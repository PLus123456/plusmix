// 输入设置窗（W3-E 交付第 2 条）：裁切 / 变换、延迟补偿（0–500 ms）、音频路由（四总线）、增益 / 静音 / 独听 / 声像、抠像参数、
// 效果链、来源（DeckLink / NDI 特有项）。模型只发 setInputSettings / renameInput，快照回来再刷新表单。
import AppKit
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
        config = c
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

    /// 来源摘要。
    var sourceSummary: String {
        switch config.source {
        case .camera(let id): return L("inputSettings.source.camera", id)
        case .decklink(let id, _): return L("inputSettings.source.decklink", id)   // 接口 / 带宽等 008 的新参数进摘要归 W3-E2
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
        case .ndi(let name, _, _): return L("inputSettings.source.ndi", name)
        case .audio(let uid): return L("inputSettings.source.audio", uid)
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
        case .effects: EffectChainView(editor: model.effectsBinding)
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
        Section(L("inputSettings.source.title")) {
            Text(model.sourceSummary)
            Text(L("inputSettings.source.changeHint")).font(.caption).foregroundStyle(.secondary)
        }
        switch model.config.source {
        case .decklink:
            Section(L("inputSettings.decklink.title")) {
                Picker(L("inputSettings.decklink.connection"), selection: .constant(0)) { Text(L("inputSettings.decklink.connection.auto")).tag(0) }.disabled(true)
                Picker(L("inputSettings.decklink.videoFormat"), selection: .constant(0)) { Text(L("inputSettings.decklink.videoFormat.auto")).tag(0) }.disabled(true)
                Text(L("inputSettings.decklink.pending")).font(.caption).foregroundStyle(.secondary)
            }
        case .ndi:
            Section(L("inputSettings.ndi.title")) {
                Picker(L("inputSettings.ndi.bandwidth"), selection: .constant(0)) { Text(L("inputSettings.ndi.bandwidth.highest")).tag(0) }.disabled(true)
                Toggle(L("inputSettings.ndi.tally"), isOn: .constant(true)).disabled(true)
                Text(L("inputSettings.ndi.pending")).font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

@MainActor
final class InputSettingsWindowController: PanelWindowController {
    let model: InputSettingsModel

    init(model: InputSettingsModel) {
        self.model = model
        super.init(title: L("inputSettings.windowTitle", model.number, model.config.name), size: NSSize(width: 640, height: 520),
                   autosaveName: "InputSettings", content: InputSettingsView(model: model))
    }

    func apply(state: MixerState) {
        model.apply(state: state)
        window?.title = L("inputSettings.windowTitle", model.number, model.config.name)
    }
}
