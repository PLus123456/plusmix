// 快捷键页（W3-E 交付第 6 条的编辑器；W5-J 起是设置窗"本机 › 快捷键"一页）：编辑 W2-C 的 HotkeyTable（组合键 → 动作 + 备注），录键、冲突检查、
// 恢复默认表，保存到用户配置文件（~/Library/Application Support/PlusMix/hotkeys.json；测试宿主是临时目录）并立刻换给 HotkeyDispatcher。
// W5-B（01a N4，02 X10）："其他命令"不再悄悄存成 Cut。W5-J（01a N1 / N5，04 Q51–Q53）：每行的动作位置是"选动作"按钮（一句话摘要，点开共用的
// ActionPicker），整条替换类在面板的"高级：手写 JSON"里；表上加搜索、复制行、每行"启用"勾；新加的行没有动作，存之前要选（不兜底成任何命令）。
// 表要整张校验（冲突、键）才能存，所以这一页保留"保存"：有未存的改动时关窗或切页先问 保存 / 放弃 / 取消（SettingsModel，X29）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherControl

@MainActor
final class HotkeyEditorModel: ObservableObject {
    struct Row: Identifiable, Hashable {
        let id: UUID
        var keyText: String
        /// 这一行绑的动作；nil = 还没选（存不了）。
        var action: ControlAction?
        var note: String
        /// 启用（停用的行留在表里，不派发、不参与冲突检查）。
        var enabled: Bool

        init(keyText: String, action: ControlAction?, note: String, enabled: Bool = true) {
            id = UUID()
            self.keyText = keyText
            self.action = action
            self.note = note
            self.enabled = enabled
        }
    }

    enum EditorError: Error, CustomStringConvertible {
        case invalidKey(String)
        /// 第 n 行（从 1 起）还没选动作。
        case missingAction(row: Int)
        var description: String {
            switch self {
            case .invalidKey(let k): L("hotkeys.error.invalidKey", k)
            case .missingAction(let row): L("hotkeys.error.missingAction", row)
            }
        }
    }

    @Published var rows: [Row]
    @Published var errorMessage: String?
    @Published private(set) var recordingRow: UUID?
    /// 表上的搜索框（键 / 动作摘要 / 备注）。
    @Published var search = ""
    let fileURL: URL
    /// 保存后换给派发器（AppController.applyHotkeyTable）。
    var apply: ((HotkeyTable) throws -> Void)?
    /// 快照（行上的摘要写输入名、选动作面板的下拉与预览）。
    var state: () -> MixerState? = { nil }
    /// 选动作面板"最近用过"存在哪（本机）。
    var defaults: UserDefaults = .standard
    /// 上次存（或读进来）的表：有没有未存的改动按它比。
    private(set) var savedTable: HotkeyTable

    init(table: HotkeyTable, fileURL: URL) {
        rows = Self.rows(of: table)
        savedTable = table
        self.fileURL = fileURL
    }

    private static func rows(of table: HotkeyTable) -> [Row] {
        table.bindings.map { Row(keyText: $0.key.description, action: $0.action, note: $0.note ?? "", enabled: $0.enabled) }
    }

    /// 有没存的改动（表跟上次存的不一样，或者有行还没填好）。
    var isDirty: Bool { (try? table()) != savedTable }

    /// 同一组合键绑了多次（只看启用的、认得出的键）。
    var conflicts: [HotkeyTable.Conflict] {
        HotkeyTable(bindings: rows.compactMap { r in
            guard let combo = KeyCombo(r.keyText), let action = r.action else { return nil }
            return HotkeyBinding(key: combo, action: action, note: r.note.isEmpty ? nil : r.note, enabled: r.enabled)
        }).conflicts()
    }

    /// 搜索框筛过的行（键、动作摘要、备注里含这个词）。
    var visibleRows: [Row] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { r in
            [r.keyText, KeyCombo(r.keyText).map(HotkeyText.display) ?? "", summary(of: r), r.note].contains { $0.lowercased().contains(q) }
        }
    }

    /// 行上动作按钮的字。
    func summary(of row: Row) -> String {
        row.action.map { ActionText.summary($0, state: state()) } ?? L("hotkeys.pickAction")
    }

    /// 这一行的选动作面板（定位到现在的动作）。
    func picker(for id: UUID) -> ActionPickerModel {
        ActionPickerModel(context: .hotkey, current: rows.first { $0.id == id }?.action, state: state, defaults: defaults)
    }

    /// "编辑 JSON…"上一次解不出来的原因（解出来了清掉）。
    @Published var jsonError: String?

    /// 编辑框里的初始文字：这一行是一条命令就给它的 JSON，其余为空。
    func jsonText(for id: UUID) -> String {
        guard let row = rows.first(where: { $0.id == id }), case .command(let c)? = row.action else { return "" }
        return CommandText.json(c)
    }

    /// 把一条命令的 JSON 写进这一行：解得出来才写，解不出来记原因、这一行不动。
    @discardableResult
    func applyJSON(_ id: UUID, _ text: String) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        do {
            rows[i].action = .command(try CommandText.parse(text))
            jsonError = nil
            return true
        } catch {
            jsonError = "\(error)"
            return false
        }
    }

    /// 加一行（默认没有动作：要在选动作面板里选，W5-J）。
    func addRow(key: String = "", action: ControlAction? = nil) {
        rows.append(Row(keyText: key, action: action, note: ""))
    }

    /// 复制一行（键空着，免得和原来那行冲突；动作、备注、启用照抄）。
    @discardableResult
    func duplicateRow(_ id: UUID) -> UUID? {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = Row(keyText: "", action: rows[i].action, note: rows[i].note, enabled: rows[i].enabled)
        rows.insert(copy, at: i + 1)
        return copy.id
    }

    func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if recordingRow == id { recordingRow = nil }
    }

    func setAction(_ id: UUID, _ action: ControlAction?) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].action = action
    }

    func setKey(_ id: UUID, _ text: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].keyText = text
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].enabled = on
    }

    func setNote(_ id: UUID, _ note: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].note = note
    }

    /// 行 → 表；键认不出、动作没选就抛。
    func table() throws -> HotkeyTable {
        var bindings: [HotkeyBinding] = []
        for (i, r) in rows.enumerated() {
            guard let combo = KeyCombo(r.keyText) else { throw EditorError.invalidKey(r.keyText) }
            guard let action = r.action else { throw EditorError.missingAction(row: i + 1) }
            bindings.append(HotkeyBinding(key: combo, action: action, note: r.note.isEmpty ? nil : r.note, enabled: r.enabled))
        }
        return HotkeyTable(bindings: bindings)
    }

    /// 存文件 + 换表；有冲突 / 键不合法 / 动作没选 / 写不进去返回 false，原因在 errorMessage。
    @discardableResult
    func save() -> Bool {
        do {
            let t = try table()
            let c = t.conflicts()
            guard c.isEmpty else { throw HotkeyTableError.conflicts(c) }
            try t.save(to: fileURL)
            try apply?(t)
            savedTable = t
            errorMessage = nil
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    /// 放弃改动：回到上次存的表。
    func revert() {
        rows = Self.rows(of: savedTable)
        errorMessage = nil
        jsonError = nil
        recordingRow = nil
    }

    /// 表在别处换了（导入设置 / 恢复默认）：读进来当作"已存"。
    func reload(from table: HotkeyTable) {
        savedTable = table
        revert()
    }

    func resetToDefault() {
        rows = Self.rows(of: .default)
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

    /// 给人看的动作描述（不带快照：输入只写编号）。
    static func describe(_ action: ControlAction) -> String { ActionText.summary(action) }

    /// 每种动作一个样本（测试来回转换用）。
    static let sampleActions: [ControlAction] = [
        .command(.setPreview(input: 3)), .command(.setProgram(input: 4)), .command(.cut), .command(.autoTransition), .command(.fade(durationTicks: 45)),
        .toggleFTB, .toggleOverlay(channel: 2), .toggleMute(input: 5), .toggleRecord(output: 1), .toggleStream(output: 2), .toggleAFV,
        .command(.setTransition(type: .wipe, durationTicks: 30)), .fadeMs(durationMs: 1000), .previewAndTransition(input: .preview),
        .overlayInput(channel: 1, input: 2), .overlaysOff, .outputSwitch(output: 3, mode: .toggle), .outputKindSwitch(kind: .externalDisplay, mode: .on),
        .recordAll(mode: .toggle), .recordISO(mode: .on), .streamAll(mode: .off), .inputAFV(input: 1, mode: .toggle),
        .busRoute(input: 1, bus: .busA, mode: .on), .solo(input: .program, mode: .toggle), .busMuteSwitch(bus: .master, mode: .toggle),
        .ui(name: UIAction.toggleMixer.rawValue), .command(.setInputSettings(input: 1, settings: InputSettings())),
    ]
}

struct HotkeyEditorView: View {
    @ObservedObject var model: HotkeyEditorModel
    /// 正在用"编辑 JSON…"改的那一行。
    @State private var jsonRow: JSONEditTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L("hotkeys.search"), text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .accessibilityLabel(L("hotkeys.search"))
                Spacer()
                Text(L("hotkeys.systemKeysHint")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(10)
            List {
                ForEach(model.visibleRows) { row in
                    HStack(spacing: 6) {
                        Toggle(L("hotkeys.enabled"), isOn: Binding(get: { row.enabled }, set: { model.setEnabled(row.id, $0) }))
                            .labelsHidden().toggleStyle(.checkbox).help(L("hotkeys.enabled"))
                        TextField(L("hotkeys.key"), text: Binding(get: { row.keyText }, set: { model.setKey(row.id, $0) })).frame(width: 110)
                        Button(model.recordingRow == row.id ? L("hotkeys.recording") : L("hotkeys.record")) {
                            if model.recordingRow == row.id { model.cancelRecording() } else { model.beginRecording(row.id) }
                        }
                        .controlSize(.small)
                        ActionButton(summary: model.summary(of: row), context: .hotkey, makeModel: { model.picker(for: row.id) },
                                     onPick: { picker in if let a = picker.builtAction { model.setAction(row.id, a) } })
                            .frame(minWidth: 180)
                        TextField(L("hotkeys.note"), text: Binding(get: { row.note }, set: { model.setNote(row.id, $0) })).frame(width: 140)
                        Button(L("hotkeys.editJSON")) { jsonRow = JSONEditTarget(id: row.id, text: model.jsonText(for: row.id)) }.controlSize(.small)
                        Button(L("hotkeys.duplicate")) { model.duplicateRow(row.id) }.controlSize(.small)
                        Button(L("common.remove")) { model.removeRow(row.id) }.controlSize(.small)
                    }
                    .opacity(row.enabled ? 1 : 0.55)
                }
            }
            Divider()
            HStack {
                Button(L("hotkeys.add")) { model.addRow() }
                Button(L("hotkeys.resetDefault")) { model.resetToDefault() }
                Spacer()
                Text(model.errorMessage ?? (model.conflicts.isEmpty ? "" : L("hotkeys.conflicts", model.conflicts.count)))
                    .foregroundStyle(.red).lineLimit(1)
                Button(L("common.save")) { model.save() }.disabled(!model.isDirty)
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

/// 一条命令的 JSON 编辑框（快捷键 / MIDI 映射共用；W5-B）：多行框、"应用"时校验，解不出来显示原因、不关。
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
