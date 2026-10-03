// MIDI 页（W3-E 交付第 6 条的映射面板，带 learn；W5-J 起是设置窗"本机 › MIDI"一页）：编辑 W2-C 的 MIDIMapTable（触发 CC / 14-bit CC / Note → 动作），
// learn = 让 MIDIController 把下一条消息交给面板填触发（期间不派发），保存到用户配置文件（测试宿主是临时目录）并立刻换表。
// W5-J（01a N1 / N5）：动作位置是共用的"选动作"按钮——触发是 Note 时与快捷键同一份动作（含组合动作、界面动作），是 CC 时只有"推杆类"
// （T-bar / 输入增益 / 总线增益）；表上加搜索、复制行、每行"启用"勾；存之前查"动作合不合触发"（Note 不能接推杆、CC 不能接按钮动作——
// 映射器本来就不派发这种组合，存进去只会按了没反应）。换引擎时这一页不关，learn / 来源列表换到新 session 的 MIDIController（rebind）。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherControl

@MainActor
final class MIDIMappingModel: ObservableObject {
    enum TriggerKind: String, CaseIterable, Identifiable {
        case cc, cc14, note
        var id: String { rawValue }
        var title: String { L("midi.trigger.\(rawValue)") }
    }

    struct Row: Identifiable, Hashable {
        let id = UUID()
        var trigger: MIDITrigger?
        /// nil = 还没选（存不了）。
        var action: MIDIAction?
        var note: String
        var enabled = true

        var triggerKind: TriggerKind {
            switch trigger {
            case .cc14?: .cc14
            case .note?: .note
            default: .cc
            }
        }
        var channel: Int {
            switch trigger {
            case .cc(let ch, _)?, .cc14(let ch, _)?, .note(let ch, _)?: ch
            case nil: 1
            }
        }
        var number: Int {
            switch trigger {
            case .cc(_, let n)?, .cc14(_, let n)?, .note(_, let n)?: n
            case nil: 0
            }
        }
        /// 选动作面板用哪一种：Note = 按钮动作，CC = 推杆类。
        var pickerContext: ActionPickerContext { triggerKind == .note ? .midiNote : .midiCC }
        /// 动作合不合触发（Note ↔ 按钮动作，CC ↔ 推杆类）。
        var actionFitsTrigger: Bool {
            guard let action else { return true }
            if case .action = action { return triggerKind == .note }
            return triggerKind != .note
        }
    }

    enum EditorError: Error, CustomStringConvertible {
        case missingTrigger
        case missingAction(row: Int)
        case actionDoesNotFitTrigger(row: Int)
        var description: String {
            switch self {
            case .missingTrigger: L("midi.error.missingTrigger")
            case .missingAction(let row): L("midi.error.missingAction", row)
            case .actionDoesNotFitTrigger(let row): L("midi.error.actionDoesNotFit", row)
            }
        }
    }

    @Published var rows: [Row]
    @Published var errorMessage: String?
    @Published private(set) var learningRow: UUID?
    @Published private(set) var sources: [MIDISourceInfo] = []
    @Published var search = ""
    let fileURL: URL
    private var controller: MIDIController
    var apply: ((MIDIMapTable) throws -> Void)?
    /// 快照（摘要写输入名、选动作面板的下拉与预览）。
    var state: () -> MixerState? = { nil }
    /// 选动作面板"最近用过"存在哪（本机）。
    var defaults: UserDefaults = .standard
    /// 上次存（或读进来）的表。
    private(set) var savedTable: MIDIMapTable
    private var sourceTimer: Timer?

    init(table: MIDIMapTable, controller: MIDIController, fileURL: URL) {
        rows = Self.rows(of: table)
        savedTable = table
        self.controller = controller
        self.fileURL = fileURL
        refreshSources()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshSources() } }
        RunLoop.main.add(t, forMode: .common)
        sourceTimer = t
    }

    private static func rows(of table: MIDIMapTable) -> [Row] {
        table.mappings.map { Row(trigger: $0.trigger, action: $0.action, note: $0.note ?? "", enabled: $0.enabled) }
    }

    /// 关页 / 关窗时停掉来源刷新（Timer 在非隔离的 deinit 里碰不得）。
    func stopRefreshing() {
        sourceTimer?.invalidate()
        sourceTimer = nil
    }

    /// 换了 session：learn 与来源列表换到新的 MIDIController（行不动，没存的改动也留着）。
    func rebind(controller: MIDIController) {
        if learningRow != nil { cancelLearn() }
        self.controller = controller
        refreshSources()
    }

    func refreshSources() {
        let s = controller.sources
        if s != sources { sources = s }
    }

    var isRunning: Bool { controller.isRunning }

    var isDirty: Bool { (try? table()) != savedTable }

    var visibleRows: [Row] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { r in [r.trigger.map { "\($0)" } ?? "", summary(of: r), r.note].contains { $0.lowercased().contains(q) } }
    }

    func summary(of row: Row) -> String {
        row.action.map { ActionText.summary($0, state: state()) } ?? L("hotkeys.pickAction")
    }

    func picker(for id: UUID) -> ActionPickerModel {
        let row = rows.first { $0.id == id }
        return ActionPickerModel(context: row?.pickerContext ?? .midiNote, current: row?.actionFitsTrigger == true ? row?.action : nil, state: state, defaults: defaults)
    }

    func addRow(trigger: MIDITrigger? = nil, action: MIDIAction? = nil) {
        rows.append(Row(trigger: trigger, action: action, note: ""))
    }

    /// 复制一行（触发空着，免得冲突；动作、备注、启用照抄）。
    @discardableResult
    func duplicateRow(_ id: UUID) -> UUID? {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = Row(trigger: nil, action: rows[i].action, note: rows[i].note, enabled: rows[i].enabled)
        rows.insert(copy, at: i + 1)
        return copy.id
    }

    func removeRow(_ id: UUID) {
        if learningRow == id { cancelLearn() }
        rows.removeAll { $0.id == id }
    }

    func setAction(_ id: UUID, _ action: MIDIAction?) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].action = action
    }

    func setTrigger(_ id: UUID, _ trigger: MIDITrigger?) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].trigger = trigger
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].enabled = on
    }

    func setNote(_ id: UUID, _ note: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].note = note
    }

    /// 触发编辑的三个分量。
    func setTriggerParts(_ id: UUID, kind: TriggerKind? = nil, channel: Int? = nil, number: Int? = nil) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let r = rows[i]
        let k = kind ?? r.triggerKind
        let ch = channel ?? r.channel
        let n = number ?? r.number
        rows[i].trigger = switch k {
        case .cc: .cc(channel: ch, controller: n)
        case .cc14: .cc14(channel: ch, controller: n)
        case .note: .note(channel: ch, note: n)
        }
    }

    /// learn：下一条消息（CoreMIDI 线程）→ 主线程填进这一行。
    func learn(row id: UUID) {
        learningRow = id
        controller.startLearn { [weak self] message in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.learned(message.trigger) } }
        }
    }

    private func learned(_ trigger: MIDITrigger) {
        guard let id = learningRow else { return }
        setTrigger(id, trigger)
        learningRow = nil
    }

    func cancelLearn() {
        controller.cancelLearn()
        learningRow = nil
    }

    func table() throws -> MIDIMapTable {
        var mappings: [MIDIMapping] = []
        for (i, r) in rows.enumerated() {
            guard let t = r.trigger else { throw EditorError.missingTrigger }
            guard t.isValid else { throw MIDIMapTableError.invalidTrigger(t) }
            guard let action = r.action else { throw EditorError.missingAction(row: i + 1) }
            guard r.actionFitsTrigger else { throw EditorError.actionDoesNotFitTrigger(row: i + 1) }
            mappings.append(MIDIMapping(trigger: t, action: action, note: r.note.isEmpty ? nil : r.note, enabled: r.enabled))
        }
        return MIDIMapTable(mappings: mappings)
    }

    @discardableResult
    func save() -> Bool {
        do {
            let t = try table()
            let c = t.conflicts()
            guard c.isEmpty else { throw MIDIMapTableError.conflicts(c) }
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
        if learningRow != nil { cancelLearn() }
        rows = Self.rows(of: savedTable)
        errorMessage = nil
        jsonError = nil
    }

    /// 表在别处换了（导入设置 / 恢复默认）：读进来当作"已存"。
    func reload(from table: MIDIMapTable) {
        savedTable = table
        revert()
    }

    /// "编辑 JSON…"上一次解不出来的原因。
    @Published var jsonError: String?

    /// 编辑框的初始文字（这一行是一条命令就给它的 JSON）。
    func jsonText(for id: UUID) -> String {
        guard let row = rows.first(where: { $0.id == id }), case .action(.command(let c))? = row.action else { return "" }
        return CommandText.json(c)
    }

    /// 把一条命令的 JSON 写进这一行（动作 = 这条命令）；解不出来记原因、这一行不动。
    @discardableResult
    func applyJSON(_ id: UUID, _ text: String) -> Bool {
        guard rows.contains(where: { $0.id == id }) else { return false }
        do {
            setAction(id, .action(.command(try CommandText.parse(text))))
            jsonError = nil
            return true
        } catch {
            jsonError = "\(error)"
            return false
        }
    }

    static func describe(_ action: MIDIAction) -> String { ActionText.summary(action) }

    static let sampleActions: [MIDIAction] = [.tbar, .inputGain(input: 1, minDb: -60, maxDb: 12), .busGain(bus: .master, minDb: -60, maxDb: 12), .action(.toggleFTB),
                                              .action(.previewAndTransition(input: 2)), .action(.ui(name: UIAction.toggleMultiviewWindow.rawValue))]
}

struct MIDIMappingView: View {
    @ObservedObject var model: MIDIMappingModel
    /// 正在用"编辑 JSON…"改的那一行。
    @State private var jsonRow: JSONEditTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.isRunning ? L("midi.sources", model.sources.count) : L("midi.notRunning")).font(.caption)
                Text(model.sources.map { $0.name + ($0.connected ? "" : " (" + L("midi.disconnected") + ")") }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                TextField(L("hotkeys.search"), text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .accessibilityLabel(L("hotkeys.search"))
            }
            .padding(10)
            Divider()
            List {
                ForEach(model.visibleRows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Toggle(L("hotkeys.enabled"), isOn: Binding(get: { row.enabled }, set: { model.setEnabled(row.id, $0) }))
                                .labelsHidden().toggleStyle(.checkbox).help(L("hotkeys.enabled"))
                            Picker(L("midi.triggerKind"), selection: Binding(get: { row.triggerKind }, set: { model.setTriggerParts(row.id, kind: $0) })) {
                                ForEach(MIDIMappingModel.TriggerKind.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 110)
                            TextField(L("midi.channel"), value: Binding(get: { row.channel }, set: { model.setTriggerParts(row.id, channel: $0) }),
                                      format: .number.grouping(.never)).frame(width: 50)
                            TextField(L("midi.number"), value: Binding(get: { row.number }, set: { model.setTriggerParts(row.id, number: $0) }),
                                      format: .number.grouping(.never)).frame(width: 50)
                            Button(model.learningRow == row.id ? L("midi.learning") : L("midi.learn")) {
                                if model.learningRow == row.id { model.cancelLearn() } else { model.learn(row: row.id) }
                            }
                            .controlSize(.small)
                            Text(row.trigger.map { "\($0)" } ?? L("midi.noTrigger")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("hotkeys.duplicate")) { model.duplicateRow(row.id) }.controlSize(.small)
                            Button(L("common.remove")) { model.removeRow(row.id) }.controlSize(.small)
                        }
                        HStack(spacing: 6) {
                            ActionButton(summary: model.summary(of: row), context: row.pickerContext, makeModel: { model.picker(for: row.id) },
                                         onPick: { picker in if let a = picker.builtMIDIAction { model.setAction(row.id, a) } })
                                .frame(minWidth: 220)
                            if !row.actionFitsTrigger {
                                Text(L("midi.actionDoesNotFitHint")).font(.caption).foregroundStyle(.orange)
                            }
                            if row.triggerKind == .note {
                                Button(L("hotkeys.editJSON")) { jsonRow = JSONEditTarget(id: row.id, text: model.jsonText(for: row.id)) }.controlSize(.small)
                            }
                            TextField(L("hotkeys.note"), text: Binding(get: { row.note }, set: { model.setNote(row.id, $0) }))
                        }
                    }
                    .padding(.vertical, 2)
                    .opacity(row.enabled ? 1 : 0.55)
                }
            }
            Divider()
            HStack {
                Button(L("midi.add")) { model.addRow() }
                Spacer()
                Text(model.errorMessage ?? "").foregroundStyle(.red).lineLimit(1)
                Button(L("common.save")) { model.save() }.disabled(!model.isDirty)
            }
            .padding(10)
            Text(L("midi.fileHint", model.fileURL.path)).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }
        .sheet(item: $jsonRow) { target in
            CommandJSONSheet(text: target.text, error: model.jsonError, apply: { text in model.applyJSON(target.id, text) }, close: { jsonRow = nil })
        }
    }
}
