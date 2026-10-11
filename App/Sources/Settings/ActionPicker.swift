// 共用的"选动作"面板（W5-J，01a N1 / N3 / N5）：快捷键表、MIDI 映射（以后的触发器）每一行的动作位置是一个按钮（一句话摘要），
// 点开 popover——顶部搜索（打开即获焦点）、左栏分组（切换 / 叠加 / 音频 / 输出 / 输入 / 节目 / 界面 / 全部 / 最近用过；MIDI CC 只有推杆类）、
// 右栏我们自己的动作名 + 一行说明 + 小字 API 键名、下方按类型化参数生成的表单与"按下时会发什么"预览（按当前快照解析）。
// 打开时定位到这一行现在的动作；整条替换类默认不列，勾"显示整条替换类"或选"高级：手写 JSON"（Q51）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherControl

@MainActor
final class ActionPickerModel: ObservableObject {
    let context: ActionPickerContext
    /// 这个场合能选的全部项。
    let entries: [ActionEntry]
    @Published var group: ActionGroup
    @Published var search = ""
    /// 显示整条替换 / 增删类（高级）。
    @Published var showsAdvanced = false
    @Published private(set) var selectedID: String?
    /// 表单里各格的值（JSON 键 → 值）。
    @Published var values: [String: FieldValue] = [:]
    /// "高级：手写 JSON"那一项的文字（一条命令）。
    @Published var jsonText = ""
    /// 快照（输入 / 输出下拉、预览用）。
    let state: () -> MixerState?
    private let defaults: UserDefaults

    /// 最近用过的项（本机，最多 10 个）。
    static let recentsKey = "ActionPickerRecents"
    static let recentsLimit = 10

    init(context: ActionPickerContext, current: MIDIAction?, state: @escaping () -> MixerState?, defaults: UserDefaults) {
        self.context = context
        self.state = state
        self.defaults = defaults
        entries = ActionCatalog.entries(for: context)
        group = context == .midiCC ? .fader : .switching
        if let current { load(current) }
    }

    convenience init(context: ActionPickerContext, current: ControlAction?, state: @escaping () -> MixerState?, defaults: UserDefaults) {
        self.init(context: context, current: current.map { .action($0) }, state: state, defaults: defaults)
    }

    var frameRate: FrameRate { state()?.format.frameRate ?? .fps60 }

    /// 左栏。
    var groups: [ActionGroup] {
        context == .midiCC ? [.fader] : [.switching, .overlay, .audio, .output, .input, .show, .ui, .all, .recent]
    }

    var recents: [String] { defaults.stringArray(forKey: Self.recentsKey) ?? [] }

    func entry(id: String) -> ActionEntry? { entries.first { $0.id == id } }

    var selected: ActionEntry? { selectedID.flatMap(entry(id:)) }

    /// 右栏现在列哪些：默认不列高级项与旧写法（旧写法是当前动作时照列）；有搜索词时跨组搜（动作名 / 说明 / API 键名）。
    var visibleEntries: [ActionEntry] {
        let base = entries.filter { (!$0.advanced || showsAdvanced) && (!$0.legacy || $0.id == selectedID) }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            return base.filter { [$0.title, $0.summary, $0.apiKey].contains { $0.lowercased().contains(query) } }
        }
        switch group {
        case .all: return base
        case .recent: return recents.compactMap { id in base.first { $0.id == id } }
        default: return base.filter { $0.group == group }
        }
    }

    /// 选一项：表单回到这一项的默认值（输入 = 当前 PVW……）。
    func select(_ id: String) {
        guard let e = entry(id: id) else { return }
        selectedID = id
        values = ActionCatalog.defaults(for: e, state: state())
        if case .json = e.kind, jsonText.isEmpty { jsonText = "{\n  \"cut\": {}\n}" }
        if case .command(let k) = e.kind, e.advanced {
            // 高级命令：从目录的样例起步，在 JSON 里改
            jsonText = CommandText.json(CommandCatalog.entry(for: k).example)
        }
    }

    func set(_ name: String, _ value: FieldValue) { values[name] = value }

    /// 打开时定位到当前动作。
    private func load(_ action: MIDIAction) {
        let located = ActionCatalog.locate(action, frameRate: frameRate)
        guard let e = entry(id: located.entryID) else { return }
        selectedID = e.id
        values = ActionCatalog.defaults(for: e, state: state()).merging(located.values) { _, new in new }
        group = e.group
        if case .json = e.kind, case .action(.command(let c)) = action { jsonText = CommandText.json(c) }
        if e.advanced { showsAdvanced = true }
    }

    /// 手写 JSON 那一项：解不出来的原因（解得出来为 nil）。
    var jsonError: String? {
        guard selected?.kind == .json || selected?.advanced == true else { return nil }
        do {
            _ = try CommandText.parse(jsonText)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// 表单拼出的动作（快捷键 / MIDI 音符）；缺参数 / 解不出来为 nil。
    var builtAction: ControlAction? {
        guard let e = selected else { return nil }
        if case .json = e.kind { return (try? CommandText.parse(jsonText)).map { .command($0) } }
        if e.advanced { return (try? CommandText.parse(jsonText)).map { .command($0) } }
        return ActionCatalog.build(e, values: values, frameRate: frameRate)
    }

    /// MIDI 映射的动作：CC 的推杆类，或音符的动作。
    var builtMIDIAction: MIDIAction? {
        guard let e = selected else { return nil }
        if case .fader = e.kind { return ActionCatalog.buildFader(e, values: values) }
        return builtAction.map { .action($0) }
    }

    /// "按下时会发什么"：按当前快照解析（组合动作一行一条）；界面动作 / 推杆 / 解析不出各写一句。
    var preview: [String] {
        guard let e = selected else { return [L("actionPicker.preview.none")] }
        switch e.kind {
        case .ui: return [L("actionPicker.preview.ui")]
        case .fader(let f):
            return [L("actionPicker.preview.fader.\(f.rawValue)")]
        default:
            guard let action = builtAction else { return [L("actionPicker.preview.incomplete")] }
            guard let s = state() else { return [L("actionPicker.preview.noShow")] }
            let commands = action.resolve(in: s)
            guard !commands.isEmpty else { return [L("actionPicker.preview.nothing")] }
            return commands.map(Self.commandLine)
        }
    }

    /// 预览那几行是不是命令（不是"解析不出 / 界面动作"这类说明）。
    var previewIsCommands: Bool {
        guard let e = selected, let action = builtAction, let s = state() else { return false }
        switch e.kind {
        case .ui, .fader: return false
        default: return !action.resolve(in: s).isEmpty
        }
    }

    /// 一条命令写成"setPreview（input: 3）"——就是进总线的那一条（API 键名 + 参数）。
    static func commandLine(_ c: Command) -> String {
        let kind = CommandKind(of: c).rawValue
        let params = CommandText.parameters(c)
        return params.isEmpty ? kind : L("actionPicker.preview.line", kind, params)
    }

    /// 用了一项（点"完成"）：记进最近用过。
    func noteUsed() {
        guard let id = selectedID else { return }
        var list = recents.filter { $0 != id }
        list.insert(id, at: 0)
        defaults.set(Array(list.prefix(Self.recentsLimit)), forKey: Self.recentsKey)
    }
}

// MARK: 一句话摘要（行上的按钮、快捷键一览）

@MainActor
enum ActionText {
    /// "叠加 1 开关""选进 PVW 并转场 · 输入 3「合成 3」""Fade · 1 秒"；高级命令 = 命令目录的说明 + 参数（CommandText）。
    static func summary(_ action: ControlAction, state: MixerState? = nil) -> String {
        if case .command(let c) = action, !CommandKind(of: c).operatorFacing { return CommandText.summary(c) }
        let rate = state?.format.frameRate ?? .fps60
        let located = ActionCatalog.locate(action, frameRate: rate)
        guard let entry = ActionCatalog.entries(for: .hotkey).first(where: { $0.id == located.entryID }), entry.kind != .json else {
            if case .command(let c) = action { return CommandText.summary(c) }
            return ControlActionKind(of: action).rawValue
        }
        // 按拍存的旧 Fade：照拍数写（时长跟着节目帧率走）
        if case .command(.fade(let ticks)) = action { return L("actionPicker.summary.legacyFade", ticks) }
        let parts = entry.fields.compactMap { f in located.values[f.name].map { value(f, $0, state: state) } }
        return ([entry.title] + parts).joined(separator: " · ")
    }

    static func summary(_ action: MIDIAction, state: MixerState? = nil) -> String {
        switch action {
        case .tbar: return L("actionPicker.fader.tbar")
        case .inputGain(let n, let lo, let hi): return L("midi.action.inputGainDesc", n, lo, hi)
        case .busGain(let b, let lo, let hi): return L("midi.action.busGainDesc", L("bus.\(b.name)"), lo, hi)
        case .action(let a): return summary(a, state: state)
        }
    }

    /// 一格的值写成人话。
    static func value(_ field: CommandField, _ value: FieldValue, state: MixerState?) -> String {
        switch (field.type, value) {
        case (_, .input(let ref)): return input(ref, state: state)
        case (.overlayChannel, .int(let n)): return L("actionPicker.value.channel", n)
        case (.output, .int(let n)): return output(n, state: state)
        case (.outputKind, .string(let s)): return L("actionPicker.value.outputKind.\(s)")
        case (.bus, .int(let b)): return Bus(rawValue: b).map { L("bus.\($0.name)") } ?? "\(b)"
        case (.onOff, .bool(let on)): return on ? L("actionPicker.value.on") : L("actionPicker.value.off")
        case (.switchMode, .string(let s)): return L("actionPicker.value.mode.\(s)")
        case (_, .seconds(let s)): return seconds(s)
        case (.transitionType, .string(let s)): return L("transition.type.\(s)")
        case (.fraction, .double(let d)): return "\(Int((d * 100).rounded()))%"
        case (.decibels, .double(let d)): return String(format: "%g dB", d)
        case (.text, .string(let s)): return "“\(s)”"
        case (_, .string(let s)): return s
        case (_, .int(let n)): return "\(n)"
        case (_, .double(let d)): return String(format: "%g", d)
        case (_, .bool(let b)): return b ? L("actionPicker.value.on") : L("actionPicker.value.off")
        case (_, .routing): return ""   // W5-M 红灯轮的桩
        }
    }

    static func input(_ ref: InputRef, state: MixerState?) -> String {
        switch ref {
        case .preview: return L("actionPicker.value.currentPreview")
        case .program: return L("actionPicker.value.currentProgram")
        case .number(let n):
            if n == MixerState.noInput { return L("actionPicker.value.black") }
            if let name = state?.input(n)?.name { return L("actionPicker.value.inputNamed", n, name) }
            return L("actionPicker.value.input", n)
        }
    }

    static func output(_ n: Int, state: MixerState?) -> String {
        if let name = state?.output(n)?.name { return L("actionPicker.value.outputNamed", n, name) }
        return L("actionPicker.value.output", n)
    }

    /// "0.5 秒""1 秒""1.25 秒"（不加千分位、不写多余的 0）。
    static func seconds(_ s: Double) -> String {
        let rounded = (s * 1000).rounded() / 1000
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
        return L("actionPicker.value.seconds", text)
    }
}

// MARK: 视图

/// 行上的动作按钮：显示一句话摘要，点开选动作 popover。
struct ActionButton: View {
    let summary: String
    let context: ActionPickerContext
    /// 打开时现建模型（定位到这一行现在的动作）。
    let makeModel: () -> ActionPickerModel
    let onPick: (ActionPickerModel) -> Void
    @State private var model: ActionPickerModel?

    var body: some View {
        Button { model = makeModel() } label: { Text(summary).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
            .accessibilityLabel(L("actionPicker.button.a11y", summary))
            .help(summary)
        .popover(isPresented: Binding(get: { model != nil }, set: { if !$0 { model = nil } }), arrowEdge: .bottom) {
            if let model {
                ActionPickerView(model: model, done: {
                    model.noteUsed()
                    onPick(model)
                    self.model = nil
                }, cancel: { self.model = nil })
            }
        }
    }
}

struct ActionPickerView: View {
    @ObservedObject var model: ActionPickerModel
    let done: () -> Void
    let cancel: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("actionPicker.search"), text: $model.search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel(L("actionPicker.search"))
            HStack(spacing: 0) {
                List(model.groups, selection: Binding(get: { model.group }, set: { if let g = $0 { model.group = g } })) { g in
                    Text(g.title).tag(g)
                }
                .listStyle(.sidebar)
                .frame(width: 120)
                Divider()
                List(model.visibleEntries, selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(e.title)
                            if e.advanced { Text(L("actionPicker.advancedTag")).font(.caption2).foregroundStyle(.orange) }
                        }
                        Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(e.apiKey).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .tag(e.id)
                }
            }
            .frame(height: 300)
            Divider()
            ActionFieldsForm(model: model)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("actionPicker.preview.title")).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.preview.enumerated()), id: \.offset) { _, line in
                    // 进总线的命令用等宽字，解释性的话（解析不出、界面动作……）用正文字
                    Text(line).font(model.previewIsCommands ? .caption.monospaced() : .caption).lineLimit(2)
                }
            }
            HStack {
                if model.context != .midiCC { Toggle(L("actionPicker.showAdvanced"), isOn: $model.showsAdvanced).toggleStyle(.checkbox) }
                Spacer()
                Button(L("common.cancel")) { cancel() }.keyboardShortcut(.cancelAction)
                Button(L("actionPicker.done")) { done() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.context == .midiCC ? model.builtMIDIAction == nil : model.builtAction == nil)
            }
        }
        .padding(12)
        .frame(width: 620)
        .onAppear { searchFocused = true }
    }
}

/// 参数表单：按 CommandField 的类型出控件（N3）。
struct ActionFieldsForm: View {
    @ObservedObject var model: ActionPickerModel

    var body: some View {
        if let e = model.selected {
            if e.kind == .json || e.advanced {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $model.jsonText).font(.system(size: 12, design: .monospaced)).frame(height: 90)
                        .accessibilityLabel(L("hotkeys.json.editor"))
                    if let err = model.jsonError { Text(err).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    Text(L("hotkeys.json.hint")).font(.caption).foregroundStyle(.secondary)
                }
            } else if e.fields.isEmpty {
                Text(L("actionPicker.noParameters")).font(.caption).foregroundStyle(.secondary)
            } else {
                Form {
                    ForEach(e.fields, id: \.name) { field in fieldControl(field) }
                }
                .formStyle(.columns)
            }
        } else {
            Text(L("actionPicker.pickOne")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fieldControl(_ f: CommandField) -> some View {
        let label = L("actionPicker.field.\(f.name)")
        switch f.type {
        case .input(let allowsBlack):
            Picker(label, selection: inputBinding(f)) {
                if f.optional { Text(L("actionPicker.value.keepInput")).tag(Optional<InputRef>.none) }
                if allowsBlack { Text(L("actionPicker.value.black")).tag(Optional(InputRef.number(MixerState.noInput))) }
                ForEach(inputs, id: \.number) { i in Text(L("actionPicker.value.inputNamed", i.number, i.name)).tag(Optional(InputRef.number(i.number))) }
            }
        case .inputRef:
            Picker(label, selection: inputBinding(f)) {
                Text(L("actionPicker.value.currentPreview")).tag(Optional(InputRef.preview))
                Text(L("actionPicker.value.currentProgram")).tag(Optional(InputRef.program))
                ForEach(inputs, id: \.number) { i in Text(L("actionPicker.value.inputNamed", i.number, i.name)).tag(Optional(InputRef.number(i.number))) }
            }
        case .overlayChannel, .transitionSlot:   // 叠加通道 1–4 / 转场槽 1–4（020）都是四段
            Picker(label, selection: intBinding(f, 1)) {
                ForEach(1...MixerState.overlayCount, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
        case .output(let kinds):
            Picker(label, selection: intBinding(f, 0)) {
                ForEach(model.state()?.outputs.filter { kinds.isEmpty || kinds.contains($0.kind) } ?? [], id: \.number) { o in
                    Text(L("actionPicker.value.outputNamed", o.number, o.name)).tag(o.number)
                }
            }
        case .outputKind(let kinds):
            Picker(label, selection: stringBinding(f, kinds.first?.rawValue ?? "")) {
                ForEach(kinds, id: \.self) { k in Text(L("actionPicker.value.outputKind.\(k.rawValue)")).tag(k.rawValue) }
            }
        case .bus:
            Picker(label, selection: intBinding(f, 0)) {
                ForEach(Bus.allCases, id: \.self) { b in Text(L("bus.\(b.name)")).tag(b.rawValue) }
            }
            .pickerStyle(.segmented)
        case .onOff:
            Picker(label, selection: boolBinding(f)) {
                Text(L("actionPicker.value.on")).tag(true)
                Text(L("actionPicker.value.off")).tag(false)
            }
            .pickerStyle(.segmented)
        case .switchMode:
            Picker(label, selection: stringBinding(f, SwitchMode.toggle.rawValue)) {
                ForEach(SwitchMode.allCases, id: \.self) { m in Text(L("actionPicker.value.mode.\(m.rawValue)")).tag(m.rawValue) }
            }
            .pickerStyle(.segmented)
        case .durationTicks, .durationMs, .seconds:   // .seconds（021）：秒数直接写进 JSON，不换算
            DurationField(label: label, seconds: secondsBinding(f))
        case .transitionType:
            Picker(label, selection: stringBinding(f, TransitionType.fade.rawValue)) {
                ForEach(TransitionType.allCases, id: \.self) { t in Text(L("transition.type.\(t.rawValue)")).tag(t.rawValue) }
            }
        case .fraction:
            Slider(value: doubleBinding(f, 0.5), in: 0...1) { Text(label) }
        case .decibels(let lo, let hi):
            TextField(label, value: Binding(get: { min(max(doubleBinding(f, 0).wrappedValue, lo), hi) }, set: { model.set(f.name, .double(min(max($0, lo), hi))) }),
                      format: .number.grouping(.never))
        case .text:
            TextField(label, text: stringBinding(f, ""))
        case .choice(let options):
            Picker(label, selection: stringBinding(f, options.first ?? "")) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .json, .busRouting:   // busRouting（023 五）的勾选控件归 100
            EmptyView()
        }
    }

    private var inputs: [InputConfig] { model.state()?.inputs ?? [] }

    private func inputBinding(_ f: CommandField) -> Binding<InputRef?> {
        Binding(get: { if case .input(let r)? = model.values[f.name] { return r }; return nil },
                set: { r in if let r { model.set(f.name, .input(r)) } else { model.values[f.name] = nil } })
    }
    private func intBinding(_ f: CommandField, _ d: Int) -> Binding<Int> {
        Binding(get: { if case .int(let v)? = model.values[f.name] { return v }; return d }, set: { model.set(f.name, .int($0)) })
    }
    private func boolBinding(_ f: CommandField) -> Binding<Bool> {
        Binding(get: { if case .bool(let v)? = model.values[f.name] { return v }; return true }, set: { model.set(f.name, .bool($0)) })
    }
    private func stringBinding(_ f: CommandField, _ d: String) -> Binding<String> {
        Binding(get: { if case .string(let v)? = model.values[f.name] { return v }; return d }, set: { model.set(f.name, .string($0)) })
    }
    private func doubleBinding(_ f: CommandField, _ d: Double) -> Binding<Double> {
        Binding(get: { if case .double(let v)? = model.values[f.name] { return v }; return d }, set: { model.set(f.name, .double($0)) })
    }
    private func secondsBinding(_ f: CommandField) -> Binding<Double> {
        Binding(get: { if case .seconds(let v)? = model.values[f.name] { return v }; return 0.5 }, set: { model.set(f.name, .seconds(max(0, $0))) })
    }
}

/// 时长：0.5 / 1 / 2 秒三个预设 + 自定义（秒，N3）。
struct DurationField: View {
    let label: String
    @Binding var seconds: Double
    static let presets: [Double] = [0.5, 1, 2]

    var body: some View {
        HStack {
            Picker(label, selection: Binding(get: { Self.presets.contains(seconds) ? seconds : -1 }, set: { if $0 >= 0 { seconds = $0 } })) {
                ForEach(Self.presets, id: \.self) { Text(ActionText.seconds($0)).tag($0) }
                Text(L("actionPicker.duration.custom")).tag(-1.0)
            }
            .pickerStyle(.segmented)
            TextField(L("actionPicker.duration.seconds"), value: $seconds, format: .number.grouping(.never).precision(.fractionLength(0...3)))
                .frame(width: 70)
        }
    }
}
