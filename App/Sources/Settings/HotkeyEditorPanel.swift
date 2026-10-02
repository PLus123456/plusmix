// 快捷键编辑器（W3-E 交付第 6 条）：编辑 W2-C 的 HotkeyTable（组合键 → 动作 + 备注），录键、冲突检查、恢复默认表，
// 保存到用户配置文件（~/Library/Application Support/PlusMix/hotkeys.json；测试宿主是临时目录）并立刻换给 HotkeyDispatcher。
// W5-B（01a N4，02 X10 / X41）："其他命令"只在这一行本来就是其他命令时才列出（原来任何一行都能选、行里没东西可填，保存时悄悄存成 Cut）；
// 显示改用 CommandCatalog 的说明 + 参数摘要（CommandText）；"编辑 JSON…"填一条命令、解得出来才写进这一行；保存前查"其他命令"有没有命令。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherControl

@MainActor
final class HotkeyEditorModel: ObservableObject {
    /// 动作种类（可绑定的动作；带参数的用 argument）。
    enum ActionKind: String, CaseIterable, Identifiable {
        case setPreview, setProgram, cut, autoTransition, fade, toggleFTB, toggleOverlay, toggleMute, toggleRecord, toggleStream, toggleAFV, other
        var id: String { rawValue }
        var title: String { L("hotkeys.action.\(rawValue)") }
        /// 参数的意思（nil = 没有参数）。
        var argumentLabel: String? {
            switch self {
            case .setPreview, .setProgram, .toggleMute: L("hotkeys.arg.input")
            case .fade: L("hotkeys.arg.ticks")
            case .toggleOverlay: L("hotkeys.arg.channel")
            case .toggleRecord, .toggleStream: L("hotkeys.arg.output")
            default: nil
            }
        }
    }

    struct Row: Identifiable, Hashable {
        let id: UUID
        var keyText: String
        var kind: ActionKind
        var argument: Int
        /// kind == .other 时保留原命令。
        var other: Command?
        var note: String

        init(keyText: String, action: ControlAction, note: String) {
            id = UUID()
            self.keyText = keyText
            self.note = note
            kind = .other
            argument = 0
            other = nil
            set(action: action)
        }

        mutating func set(action: ControlAction) {
            other = nil
            switch action {
            case .command(.setPreview(let n)): kind = .setPreview; argument = n
            case .command(.setProgram(let n)): kind = .setProgram; argument = n
            case .command(.cut): kind = .cut
            case .command(.autoTransition): kind = .autoTransition
            case .command(.fade(let d)): kind = .fade; argument = d
            case .command(let c): kind = .other; other = c
            case .toggleFTB: kind = .toggleFTB
            case .toggleOverlay(let ch): kind = .toggleOverlay; argument = ch
            case .toggleMute(let n): kind = .toggleMute; argument = n
            case .toggleRecord(let o): kind = .toggleRecord; argument = o
            case .toggleStream(let o): kind = .toggleStream; argument = o
            case .toggleAFV: kind = .toggleAFV
            }
        }

        /// 这一行绑的动作；"其他命令"却没有命令时为 nil（不兜底成 Cut，保存时报错）。
        var action: ControlAction? {
            switch kind {
            case .setPreview: .command(.setPreview(input: argument))
            case .setProgram: .command(.setProgram(input: argument))
            case .cut: .command(.cut)
            case .autoTransition: .command(.autoTransition)
            case .fade: .command(.fade(durationTicks: argument))
            case .toggleFTB: .toggleFTB
            case .toggleOverlay: .toggleOverlay(channel: argument)
            case .toggleMute: .toggleMute(input: argument)
            case .toggleRecord: .toggleRecord(output: argument)
            case .toggleStream: .toggleStream(output: argument)
            case .toggleAFV: .toggleAFV
            case .other: other.map { .command($0) }
            }
        }
    }

    enum EditorError: Error, CustomStringConvertible {
        case invalidKey(String)
        /// 第 n 行（从 1 起）是"其他命令"却没有命令。
        case otherWithoutCommand(row: Int)
        var description: String {
            switch self {
            case .invalidKey(let k): L("hotkeys.error.invalidKey", k)
            case .otherWithoutCommand(let row): L("hotkeys.error.otherWithoutCommand", row)
            }
        }
    }

    @Published var rows: [Row]
    @Published var errorMessage: String?
    @Published private(set) var recordingRow: UUID?
    let fileURL: URL
    /// 保存后换给派发器（AppController.applyHotkeyTable）。
    var apply: ((HotkeyTable) throws -> Void)?

    init(table: HotkeyTable, fileURL: URL) {
        rows = table.bindings.map { Row(keyText: $0.key.description, action: $0.action, note: $0.note ?? "") }
        self.fileURL = fileURL
    }

    /// 同一组合键绑了多次（认不出的键不算）。
    var conflicts: [HotkeyTable.Conflict] {
        HotkeyTable(bindings: rows.compactMap { r in
            guard let combo = KeyCombo(r.keyText), let action = r.action else { return nil }
            return HotkeyBinding(key: combo, action: action, note: r.note.isEmpty ? nil : r.note)
        }).conflicts()
    }

    /// 这一行的动作下拉列哪些："其他命令"只在这一行本来就是其他命令（手里有一条命令）时才列（X10）。
    static func actionChoices(for row: Row) -> [ActionKind] {
        ActionKind.allCases.filter { $0 != .other || row.other != nil }
    }

    /// "编辑 JSON…"上一次解不出来的原因（解出来了清掉）。
    @Published var jsonError: String?

    /// 编辑框里的初始文字：这一行是一条命令就给它的 JSON，其余（FTB 开关之类不是命令的动作）为空。
    func jsonText(for id: UUID) -> String {
        guard let row = rows.first(where: { $0.id == id }), case .command(let c)? = row.action else { return "" }
        return CommandText.json(c)
    }

    /// 把一条命令的 JSON 写进这一行：解得出来才写（认得出的命令回到对应的动作，其余成为"其他命令"），解不出来记原因、这一行不动。
    @discardableResult
    func applyJSON(_ id: UUID, _ text: String) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        do {
            let command = try CommandText.parse(text)
            rows[i].set(action: .command(command))
            jsonError = nil
            return true
        } catch {
            jsonError = "\(error)"
            return false
        }
    }

    func addRow(key: String = "", action: ControlAction = .command(.cut)) {
        rows.append(Row(keyText: key, action: action, note: ""))
    }

    func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if recordingRow == id { recordingRow = nil }
    }

    func setAction(_ id: UUID, _ action: ControlAction) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].set(action: action)
    }

    func setKey(_ id: UUID, _ text: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].keyText = text
    }

    /// 行 → 表；键认不出就抛。
    func table() throws -> HotkeyTable {
        var bindings: [HotkeyBinding] = []
        for (i, r) in rows.enumerated() {
            guard let combo = KeyCombo(r.keyText) else { throw EditorError.invalidKey(r.keyText) }
            guard let action = r.action else { throw EditorError.otherWithoutCommand(row: i + 1) }
            bindings.append(HotkeyBinding(key: combo, action: action, note: r.note.isEmpty ? nil : r.note))
        }
        return HotkeyTable(bindings: bindings)
    }

    /// 存文件 + 换表；有冲突 / 键不合法 / 写不进去返回 false，原因在 errorMessage。
    @discardableResult
    func save() -> Bool {
        do {
            let t = try table()
            let c = t.conflicts()
            guard c.isEmpty else { throw HotkeyTableError.conflicts(c) }
            try t.save(to: fileURL)
            try apply?(t)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    func resetToDefault() {
        rows = HotkeyTable.default.bindings.map { Row(keyText: $0.key.description, action: $0.action, note: $0.note ?? "") }
        errorMessage = nil
    }

    func beginRecording(_ id: UUID) { recordingRow = id }
    func cancelRecording() { recordingRow = nil }

    /// 录到的组合键写进正在录的那一行，然后退出录键。
    func recorded(_ combo: KeyCombo) {
        guard let id = recordingRow else { return }
        setKey(id, combo.description)
        recordingRow = nil
    }

    /// 给人看的动作描述（其他命令 = CommandCatalog 的说明 + 参数摘要，W5-B）。
    static func describe(_ action: ControlAction) -> String {
        let row = Row(keyText: "", action: action, note: "")
        if row.kind == .other, let c = row.other { return CommandText.summary(c) }
        if let label = row.kind.argumentLabel { return "\(row.kind.title) \(label) \(row.argument)" }
        return row.kind.title
    }

    /// 每种动作一个样本（测试来回转换用）。
    static let sampleActions: [ControlAction] = [
        .command(.setPreview(input: 3)), .command(.setProgram(input: 4)), .command(.cut), .command(.autoTransition), .command(.fade(durationTicks: 45)),
        .toggleFTB, .toggleOverlay(channel: 2), .toggleMute(input: 5), .toggleRecord(output: 1), .toggleStream(output: 2), .toggleAFV,
        .command(.setTransition(type: .wipe, durationTicks: 30)),
    ]
}

struct HotkeyEditorView: View {
    @ObservedObject var model: HotkeyEditorModel
    /// 正在用"编辑 JSON…"改的那一行。
    @State private var jsonRow: JSONEditTarget?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach($model.rows) { $row in
                    HStack(spacing: 6) {
                        TextField(L("hotkeys.key"), text: $row.keyText).frame(width: 120)
                        Button(model.recordingRow == row.id ? L("hotkeys.recording") : L("hotkeys.record")) {
                            if model.recordingRow == row.id { model.cancelRecording() } else { model.beginRecording(row.id) }
                        }
                        .controlSize(.small)
                        Picker(L("hotkeys.actionKind"), selection: $row.kind) {
                            ForEach(HotkeyEditorModel.actionChoices(for: row)) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                        if let label = row.kind.argumentLabel {
                            TextField(label, value: $row.argument, format: .number).frame(width: 60)
                        } else if row.kind == .other, let c = row.other {
                            Text(CommandText.summary(c)).font(.caption).lineLimit(1).frame(width: 160, alignment: .leading)
                                .help(CommandText.summary(c))
                        }
                        Button(L("hotkeys.editJSON")) { jsonRow = JSONEditTarget(id: row.id, text: model.jsonText(for: row.id)) }
                            .controlSize(.small)
                        TextField(L("hotkeys.note"), text: $row.note)
                        Button(L("common.remove")) { model.removeRow(row.id) }.controlSize(.small)
                    }
                }
            }
            Divider()
            HStack {
                Button(L("hotkeys.add")) { model.addRow() }
                Button(L("hotkeys.resetDefault")) { model.resetToDefault() }
                Spacer()
                Text(model.errorMessage ?? (model.conflicts.isEmpty ? "" : L("hotkeys.conflicts", model.conflicts.count)))
                    .foregroundStyle(.red).lineLimit(1)
                Button(L("common.save")) { model.save() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Text(L("hotkeys.fileHint", model.fileURL.path)).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }
        .sheet(item: $jsonRow) { target in
            CommandJSONSheet(text: target.text, error: model.jsonError, apply: { text in model.applyJSON(target.id, text) }, close: { jsonRow = nil })
        }
    }
}

/// "编辑 JSON…"在改哪一行、从什么文字开始。
struct JSONEditTarget: Identifiable {
    let id: UUID
    let text: String
}

/// 一条命令的 JSON 编辑框（快捷键编辑器 / MIDI 映射共用；W5-B）：多行框、"应用"时校验，解不出来显示原因、不关。
struct CommandJSONSheet: View {
    @State var text: String
    let error: String?
    /// 写进那一行；解出来了返回 true（关掉），否则留着改。
    let apply: (String) -> Bool
    let close: () -> Void
    @State private var failed = false

    init(text: String, error: String?, apply: @escaping (String) -> Bool, close: @escaping () -> Void) {
        _text = State(initialValue: text)
        self.error = error
        self.apply = apply
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("hotkeys.json.title")).font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 160)
                .accessibilityLabel(L("hotkeys.json.editor"))
            Text(L("hotkeys.json.hint")).font(.caption).foregroundStyle(.secondary)
            if failed, let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { close() }.keyboardShortcut(.cancelAction)
                Button(L("hotkeys.json.apply")) {
                    if apply(text) { close() } else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 480, height: 320)
    }
}

@MainActor
final class HotkeyEditorWindowController: PanelWindowController {
    let model: HotkeyEditorModel

    init(model: HotkeyEditorModel) {
        self.model = model
        super.init(title: L("hotkeys.windowTitle"), size: NSSize(width: 760, height: 520), autosaveName: "HotkeyEditor", content: HotkeyEditorView(model: model))
        (window as? PanelWindow)?.keyHandler = { [weak self] event in self?.handleRecordingKey(event) ?? false }
    }

    /// 录键中：把按键写进那一行并吃掉事件。
    @discardableResult
    func handleRecordingKey(_ event: NSEvent) -> Bool {
        guard model.recordingRow != nil, event.type == .keyDown, !event.isARepeat, let combo = KeyCombo(event: event) else { return false }
        model.recorded(combo)
        return true
    }
}
