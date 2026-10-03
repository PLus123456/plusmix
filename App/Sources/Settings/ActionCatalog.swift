// "选动作"面板的目录（W5-J，01a N1–N4，04 Q51–Q53）：快捷键、MIDI Note、以后的触发器共用一份。
// 一项 = 我们自己的动作名 + 一行说明（命令取 CommandCatalog 的 summary，开关 / 组合动作是我们自己写的）+ 小字 API 键名 + 类型化参数
// （SwitcherControl 的 CommandField：命令按 CommandCatalog.fields、开关 / 组合动作按 ControlActionKind.fields）。参数表单按类型生成，
// 填好的值拼成那条动作的 JSON 再用包里的 Codable 解出来——表单与 hotkeys.json / API 是同一个写法，不另造一套。
// 整条替换 / 增删类命令（CommandKind.operatorFacing == false）默认不列，放"高级：手写 JSON"（Q51）；界面动作（显示 / 隐藏调音台……）
// 进表、只在 App 里派发（Q53）；MIDI 的 CC 类（T-bar / 输入增益 / 总线增益）放"推杆类"组、只在触发是 CC 时出现。
// 动作名一律我们的说法（铁律 6）。
import Foundation
import SwitcherContracts
import SwitcherControl

/// 左栏的分组。
enum ActionGroup: String, CaseIterable, Identifiable, Sendable {
    case switching, overlay, audio, output, input, show, ui, fader, all, recent
    var id: String { rawValue }
    var title: String { L("actionPicker.group.\(rawValue)") }
}

/// 界面动作（Q53）：只在 App 里派发（ControlAction.ui(name:)），不进 CommandCatalog、API 用不了。
enum UIAction: String, CaseIterable, Sendable {
    /// 显示 / 隐藏调音台。
    case toggleMixer
    /// 多画面窗口开 / 关。
    case toggleMultiviewWindow
    /// 多画面窗口全屏 / 退出全屏（没开就先开）。
    case fullscreenMultiview
    var title: String { L("actionPicker.ui.\(rawValue)") }
    var summary: String { L("actionPicker.ui.\(rawValue).summary") }
}

/// MIDI CC 的连续控制（推杆类）。
enum FaderKind: String, CaseIterable, Sendable {
    case tbar, inputGain, busGain
}

/// 右栏的一项。
struct ActionEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// 开关 / 组合 / 毫秒 Fade（ControlAction 的一种）。
        case action(ControlActionKind)
        /// 包一条命令（ControlAction.command）。
        case command(CommandKind)
        /// 界面动作。
        case ui(UIAction)
        /// MIDI CC 推杆类。
        case fader(FaderKind)
        /// 高级：手写一条命令的 JSON。
        case json
    }

    let kind: Kind
    let group: ActionGroup
    /// 我们的动作名。
    let title: String
    /// 一行说明。
    let summary: String
    /// 小字：API / 表文件里的键名（组合动作写出会发哪几条）。
    let apiKey: String
    /// 参数（表单按它生成；JSON 键 + 类型）。
    let fields: [CommandField]
    /// 整条替换 / 增删类（默认不列）。
    let advanced: Bool
    /// 旧写法（按拍存的 Fade）：只在它就是当前动作时列出。
    let legacy: Bool

    var id: String {
        switch kind {
        case .action(let k): "action." + k.rawValue
        case .command(let k): "command." + k.rawValue
        case .ui(let u): "ui." + u.rawValue
        case .fader(let f): "fader." + f.rawValue
        case .json: "json"
        }
    }

    var commandKind: CommandKind? { if case .command(let k) = kind { return k }; return nil }
}

/// 表单里一格的值。
enum FieldValue: Hashable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case input(InputRef)
    /// 时长（秒；durationTicks 按节目帧率换拍、durationMs 换毫秒）。
    case seconds(Double)
}

@MainActor
enum ActionCatalog {
    /// 某个场合能选的全部项（含默认不列的高级项与旧写法）。
    static func entries(for context: ActionPickerContext) -> [ActionEntry] {
        switch context {
        case .midiCC:
            return FaderKind.allCases.map(faderEntry)
        case .hotkey, .midiNote:
            var out: [ActionEntry] = []
            for kind in ControlActionKind.allCases where kind != .command && kind != .ui { out.append(actionEntry(kind)) }
            for kind in CommandKind.allCases { out.append(commandEntry(kind)) }
            for ui in UIAction.allCases { out.append(uiEntry(ui)) }
            out.append(ActionEntry(kind: .json, group: .show, title: L("actionPicker.json.title"), summary: L("actionPicker.json.summary"),
                                   apiKey: "command", fields: [], advanced: false, legacy: false))
            return out
        }
    }

    /// 命令归到哪一组（同 CommandCatalog 的分组，"输入表 / 输出表"并进输入 / 输出；穷举：契约加命令这里编译就红）。
    static func group(of kind: CommandKind) -> ActionGroup {
        switch kind {
        case .cut, .fade, .setTransition, .setTransitionParams, .autoTransition, .setPreview, .setProgram, .tbar, .ftb: .switching
        case .overlay, .setOverlay, .setOverlayDecoration: .overlay
        case .audioGain, .mute, .busGain, .busMute, .setAFV, .setMonitorMode, .setBusEffects: .audio
        case .startRecord, .stopRecord, .startStream, .stopStream, .setOutputEnabled, .renameOutput, .addOutput, .removeOutput, .setOutputSettings: .output
        case .setInputSettings, .renameInput, .addInput, .removeInput, .setInputSource: .input
        case .loadShow: .show
        }
    }

    /// 开关 / 组合动作归到哪一组（同 ControlActionKind.group）。
    static func group(of kind: ControlActionKind) -> ActionGroup {
        switch kind {
        case .toggleFTB, .fadeMs, .previewAndTransition: .switching
        case .toggleOverlay, .overlayInput, .overlaysOff: .overlay
        case .toggleMute, .toggleAFV, .inputAFV, .busRoute, .solo, .busMuteSwitch: .audio
        case .toggleRecord, .toggleStream, .recordAll, .recordISO, .streamAll, .outputSwitch, .outputKindSwitch: .output
        case .ui: .ui
        case .command: .show
        }
    }

    static func actionEntry(_ kind: ControlActionKind) -> ActionEntry {
        let emits = kind.emits.map(\.rawValue)
        let api = emits.isEmpty ? kind.rawValue : kind.rawValue + " → " + emits.joined(separator: emits.count == 2 && kind == .previewAndTransition ? " + " : " / ")
        return ActionEntry(kind: .action(kind), group: group(of: kind), title: L("actionPicker.action.\(kind.rawValue)"),
                           summary: L("actionPicker.action.\(kind.rawValue).summary"), apiKey: api, fields: kind.fields, advanced: false, legacy: false)
    }

    static func commandEntry(_ kind: CommandKind) -> ActionEntry {
        let doc = CommandCatalog.entry(for: kind)
        return ActionEntry(kind: .command(kind), group: group(of: kind), title: L("actionPicker.command.\(kind.rawValue)"),
                           summary: usesCatalogText ? doc.summary : L("actionPicker.command.\(kind.rawValue)"), apiKey: kind.rawValue,
                           fields: doc.fields, advanced: !kind.operatorFacing, legacy: kind == .fade)
    }

    static func uiEntry(_ ui: UIAction) -> ActionEntry {
        ActionEntry(kind: .ui(ui), group: .ui, title: ui.title, summary: ui.summary, apiKey: "ui · " + ui.rawValue, fields: [], advanced: false, legacy: false)
    }

    static func faderEntry(_ f: FaderKind) -> ActionEntry {
        let fields: [CommandField]
        switch f {
        case .tbar: fields = []
        case .inputGain:
            fields = [CommandField(name: "input", type: .input(allowsBlack: false)), CommandField(name: "minDb", type: .decibels(min: -96, max: 24)),
                      CommandField(name: "maxDb", type: .decibels(min: -96, max: 24))]
        case .busGain:
            fields = [CommandField(name: "bus", type: .bus), CommandField(name: "minDb", type: .decibels(min: -96, max: 24)),
                      CommandField(name: "maxDb", type: .decibels(min: -96, max: 24))]
        }
        return ActionEntry(kind: .fader(f), group: .fader, title: L("actionPicker.fader.\(f.rawValue)"), summary: L("actionPicker.fader.\(f.rawValue).summary"),
                           apiKey: f.rawValue, fields: fields, advanced: false, legacy: false)
    }

    /// 命令的一行说明用 CommandCatalog 的原文（目录只有中文，英文界面用我们的动作名，同 CommandText）。
    static var usesCatalogText: Bool {
        (L10n.languageOverride ?? Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }

    // MARK: 动作 ↔ 表单

    /// 一条动作落在哪一项上、表单里各格是什么值（打开面板时定位到当前动作）。认不出（高级命令）落在 json 项上。
    static func locate(_ action: ControlAction, frameRate: FrameRate) -> (entryID: String, values: [String: FieldValue]) {
        if case .ui(let name) = action, let ui = UIAction(rawValue: name) { return ("ui." + ui.rawValue, [:]) }
        let kindName: String
        let body: [String: Any]
        let fields: [CommandField]
        let entryID: String
        if case .command(let c) = action {
            let kind = CommandKind(of: c)
            guard kind.operatorFacing, let b = jsonBody(of: c, key: kind.rawValue) else { return ("json", [:]) }
            (kindName, body, fields, entryID) = (kind.rawValue, b, CommandCatalog.fields(for: kind), "command." + kind.rawValue)
        } else {
            let kind = ControlActionKind(of: action)
            guard let b = jsonBody(of: action, key: kind.rawValue) else { return ("json", [:]) }
            (kindName, body, fields, entryID) = (kind.rawValue, b, kind.fields, "action." + kind.rawValue)
        }
        _ = kindName
        var values: [String: FieldValue] = [:]
        for f in fields {
            guard let raw = body[f.name], !(raw is NSNull) else { continue }
            if let v = fieldValue(raw, type: f.type, frameRate: frameRate) { values[f.name] = v }
        }
        return (entryID, values)
    }

    /// MIDI CC 的动作落在哪一项上。
    static func locate(_ action: MIDIAction, frameRate: FrameRate) -> (entryID: String, values: [String: FieldValue]) {
        switch action {
        case .tbar: return ("fader.tbar", [:])
        case .inputGain(let input, let lo, let hi): return ("fader.inputGain", ["input": .input(.number(input)), "minDb": .double(lo), "maxDb": .double(hi)])
        case .busGain(let bus, let lo, let hi): return ("fader.busGain", ["bus": .int(bus.rawValue), "minDb": .double(lo), "maxDb": .double(hi)])
        case .action(let a): return locate(a, frameRate: frameRate)
        }
    }

    /// 表单 → 动作（参数拼成 JSON，用包里的 Codable 解）；缺必填的格、或解不出来为 nil。
    static func build(_ entry: ActionEntry, values: [String: FieldValue], frameRate: FrameRate) -> ControlAction? {
        switch entry.kind {
        case .ui(let ui): return .ui(name: ui.rawValue)
        case .json, .fader: return nil
        case .command(let kind):
            guard let body = jsonObject(entry.fields, values: values, frameRate: frameRate) else { return nil }
            return decode(Command.self, [kind.rawValue: body]).map { .command($0) }
        case .action(let kind):
            guard let body = jsonObject(entry.fields, values: values, frameRate: frameRate) else { return nil }
            return decode(ControlAction.self, [kind.rawValue: body])
        }
    }

    /// 表单 → MIDI CC 动作。
    static func buildFader(_ entry: ActionEntry, values: [String: FieldValue]) -> MIDIAction? {
        guard case .fader(let f) = entry.kind else { return nil }
        func double(_ k: String, _ d: Double) -> Double { if case .double(let v)? = values[k] { return v }; return d }
        switch f {
        case .tbar: return .tbar
        case .inputGain:
            guard case .input(.number(let n))? = values["input"] else { return nil }
            return .inputGain(input: n, minDb: double("minDb", -60), maxDb: double("maxDb", 12))
        case .busGain:
            guard case .int(let b)? = values["bus"], let bus = Bus(rawValue: b) else { return nil }
            return .busGain(bus: bus, minDb: double("minDb", -60), maxDb: double("maxDb", 12))
        }
    }

    /// 选中一项时表单的初始值：输入 = 当前 PVW（没有就第一路）、通道 1、输出 = 第一路合适的、总线 Master、开、切换、0.5 秒、Fade……
    static func defaults(for entry: ActionEntry, state: MixerState?) -> [String: FieldValue] {
        var v: [String: FieldValue] = [:]
        let firstInput = state.flatMap { s in s.preview != MixerState.noInput && s.input(s.preview) != nil ? s.preview : s.inputs.first?.number } ?? 1
        for f in entry.fields {
            switch f.type {
            case .input: if !f.optional { v[f.name] = .input(.number(firstInput)) }
            case .inputRef: v[f.name] = .input(.number(firstInput))
            case .overlayChannel: v[f.name] = .int(1)
            case .output(let kinds): if let o = state?.outputs.first(where: { kinds.isEmpty || kinds.contains($0.kind) }) { v[f.name] = .int(o.number) }
            case .outputKind(let kinds): if let k = kinds.first { v[f.name] = .string(k.rawValue) }
            case .bus: v[f.name] = .int(Bus.master.rawValue)
            case .onOff: v[f.name] = .bool(true)
            case .switchMode: v[f.name] = .string(SwitchMode.toggle.rawValue)
            case .durationTicks, .durationMs: v[f.name] = .seconds(f.name == "durationMs" ? 1 : 0.5)
            case .transitionType: v[f.name] = .string(TransitionType.fade.rawValue)
            case .fraction: v[f.name] = .double(0.5)
            case .decibels(let lo, let hi): v[f.name] = .double(f.name == "minDb" ? -60 : (f.name == "maxDb" ? min(12, hi) : max(lo, min(0, hi))))
            case .text: v[f.name] = .string("")
            case .choice(let options): if let first = options.first { v[f.name] = .string(first) }
            case .json: break
            }
        }
        if case .fader(.busGain) = entry.kind { v["bus"] = .int(Bus.master.rawValue) }
        return v
    }

    // MARK: JSON

    private static func jsonObject(_ fields: [CommandField], values: [String: FieldValue], frameRate: FrameRate) -> [String: Any]? {
        var body: [String: Any] = [:]
        for f in fields {
            guard let value = values[f.name] else {
                if f.optional { continue }
                return nil
            }
            guard let json = jsonValue(value, type: f.type, frameRate: frameRate) else { return nil }
            body[f.name] = json
        }
        return body
    }

    private static func jsonValue(_ value: FieldValue, type: CommandFieldType, frameRate: FrameRate) -> Any? {
        switch (value, type) {
        case (.seconds(let s), .durationTicks): return Int((max(0, s) * frameRate.framesPerSecond.doubleValue).rounded())
        case (.seconds(let s), .durationMs): return Int((max(0, s) * 1000).rounded())
        case (.input(.number(let n)), _): return n
        case (.input(.preview), .inputRef): return "preview"
        case (.input(.program), .inputRef): return "program"
        case (.input, _): return nil
        case (.int(let n), _): return n
        case (.double(let d), _): return d
        case (.bool(let b), _): return b
        case (.string(let s), _): return s
        case (.seconds(let s), _): return s
        }
    }

    private static func fieldValue(_ raw: Any, type: CommandFieldType, frameRate: FrameRate) -> FieldValue? {
        switch type {
        case .input, .inputRef:
            if let n = raw as? Int { return .input(.number(n)) }
            if let s = raw as? String { return s == "preview" ? .input(.preview) : (s == "program" ? .input(.program) : nil) }
            return nil
        case .durationTicks:
            guard let n = raw as? Int else { return nil }
            return .seconds(Double(n) / frameRate.framesPerSecond.doubleValue)
        case .durationMs:
            guard let n = raw as? Int else { return nil }
            return .seconds(Double(n) / 1000)
        case .onOff:
            return (raw as? Bool).map { .bool($0) }
        case .fraction, .decibels:
            return (raw as? Double).map { .double($0) } ?? (raw as? Int).map { .double(Double($0)) }
        case .overlayChannel, .output, .bus:
            return (raw as? Int).map { .int($0) }
        case .outputKind, .switchMode, .transitionType, .text, .choice:
            return (raw as? String).map { .string($0) }
        case .json:
            return nil
        }
    }

    private static func jsonBody<T: Encodable>(of value: T, key: String) -> [String: Any]? {
        guard let data = try? APIJSON.encoder.encode(value), let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return top[key] as? [String: Any]
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? APIJSON.decoder.decode(T.self, from: data)
    }
}

/// 选动作面板用在哪儿：快捷键、MIDI 音符（同一份动作）、MIDI CC（只有推杆类）。
enum ActionPickerContext: Sendable {
    case hotkey, midiNote, midiCC
}
