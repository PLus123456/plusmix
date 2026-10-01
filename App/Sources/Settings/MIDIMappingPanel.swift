// MIDI 映射面板（W3-E 交付第 6 条，带 learn）：编辑 W2-C 的 MIDIMapTable（触发 CC / 14-bit CC / Note → T-bar / 输入增益 / 总线增益 / 动作），
// learn = 让 MIDIController 把下一条消息交给面板填触发（期间不派发），保存到用户配置文件（测试宿主是临时目录）并立刻换表。
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
    enum ActionKind: String, CaseIterable, Identifiable {
        case tbar, inputGain, busGain, action
        var id: String { rawValue }
        var title: String { L("midi.action.\(rawValue)") }
    }

    struct Row: Identifiable, Hashable {
        let id = UUID()
        var trigger: MIDITrigger?
        var action: MIDIAction
        var note: String

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
        var actionKind: ActionKind {
            switch action {
            case .tbar: .tbar
            case .inputGain: .inputGain
            case .busGain: .busGain
            case .action: .action
            }
        }
    }

    enum EditorError: Error, CustomStringConvertible {
        case missingTrigger
        var description: String { L("midi.error.missingTrigger") }
    }

    @Published var rows: [Row]
    @Published var errorMessage: String?
    @Published private(set) var learningRow: UUID?
    @Published private(set) var sources: [MIDISourceInfo] = []
    let fileURL: URL
    private let controller: MIDIController
    var apply: ((MIDIMapTable) throws -> Void)?
    private var sourceTimer: Timer?

    init(table: MIDIMapTable, controller: MIDIController, fileURL: URL) {
        rows = table.mappings.map { Row(trigger: $0.trigger, action: $0.action, note: $0.note ?? "") }
        self.controller = controller
        self.fileURL = fileURL
        refreshSources()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshSources() } }
        RunLoop.main.add(t, forMode: .common)
        sourceTimer = t
    }

    /// 窗口关掉时停掉来源刷新（Timer 在非隔离的 deinit 里碰不得）。
    func stopRefreshing() {
        sourceTimer?.invalidate()
        sourceTimer = nil
    }

    func refreshSources() {
        let s = controller.sources
        if s != sources { sources = s }
    }

    var isRunning: Bool { controller.isRunning }

    func addRow(trigger: MIDITrigger? = nil, action: MIDIAction = .action(.command(.cut))) {
        rows.append(Row(trigger: trigger, action: action, note: ""))
    }

    func removeRow(_ id: UUID) {
        if learningRow == id { cancelLearn() }
        rows.removeAll { $0.id == id }
    }

    func setAction(_ id: UUID, _ action: MIDIAction) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].action = action
    }

    func setTrigger(_ id: UUID, _ trigger: MIDITrigger?) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].trigger = trigger
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
        for r in rows {
            guard let t = r.trigger else { throw EditorError.missingTrigger }
            guard t.isValid else { throw MIDIMapTableError.invalidTrigger(t) }
            mappings.append(MIDIMapping(trigger: t, action: r.action, note: r.note.isEmpty ? nil : r.note))
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
            errorMessage = nil
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    static func actionChoices(for row: Row) -> [HotkeyEditorModel.ActionKind] { HotkeyEditorModel.ActionKind.allCases.filter { $0 != .other } }
    func applyJSON(_ id: UUID, _ text: String) -> Bool { false }

    static func describe(_ action: MIDIAction) -> String {
        switch action {
        case .tbar: L("midi.action.tbar")
        case .inputGain(let n, let lo, let hi): L("midi.action.inputGainDesc", n, lo, hi)
        case .busGain(let b, let lo, let hi): L("midi.action.busGainDesc", L("bus.\(b.name)"), lo, hi)
        case .action(let a): HotkeyEditorModel.describe(a)
        }
    }

    static let sampleActions: [MIDIAction] = [.tbar, .inputGain(input: 1, minDb: -60, maxDb: 12), .busGain(bus: .master, minDb: -60, maxDb: 12), .action(.toggleFTB)]
}

struct MIDIMappingView: View {
    @ObservedObject var model: MIDIMappingModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.isRunning ? L("midi.sources", model.sources.count) : L("midi.notRunning")).font(.caption)
                Text(model.sources.map { $0.name + ($0.connected ? "" : " (" + L("midi.disconnected") + ")") }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(10)
            Divider()
            List {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Picker(L("midi.triggerKind"), selection: Binding(get: { row.triggerKind }, set: { model.setTriggerParts(row.id, kind: $0) })) {
                                ForEach(MIDIMappingModel.TriggerKind.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 110)
                            TextField(L("midi.channel"), value: Binding(get: { row.channel }, set: { model.setTriggerParts(row.id, channel: $0) }), format: .number).frame(width: 60)
                            TextField(L("midi.number"), value: Binding(get: { row.number }, set: { model.setTriggerParts(row.id, number: $0) }), format: .number).frame(width: 60)
                            Button(model.learningRow == row.id ? L("midi.learning") : L("midi.learn")) {
                                if model.learningRow == row.id { model.cancelLearn() } else { model.learn(row: row.id) }
                            }
                            .controlSize(.small)
                            Text(row.trigger.map { "\($0)" } ?? L("midi.noTrigger")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("common.remove")) { model.removeRow(row.id) }.controlSize(.small)
                        }
                        HStack(spacing: 6) {
                            Picker(L("midi.actionKind"), selection: Binding(get: { row.actionKind }, set: { kind in
                                switch kind {
                                case .tbar: model.setAction(row.id, .tbar)
                                case .inputGain: model.setAction(row.id, .inputGain(input: 1, minDb: -60, maxDb: 12))
                                case .busGain: model.setAction(row.id, .busGain(bus: .master, minDb: -60, maxDb: 12))
                                case .action: model.setAction(row.id, .action(.command(.cut)))
                                }
                            })) {
                                ForEach(MIDIMappingModel.ActionKind.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 110)
                            actionEditor(row)
                            TextField(L("hotkeys.note"), text: Binding(get: { row.note }, set: { v in
                                if let i = model.rows.firstIndex(where: { $0.id == row.id }) { model.rows[i].note = v }
                            }))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Button(L("midi.add")) { model.addRow() }
                Spacer()
                Text(model.errorMessage ?? "").foregroundStyle(.red).lineLimit(1)
                Button(L("common.save")) { model.save() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Text(L("midi.fileHint", model.fileURL.path)).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func actionEditor(_ row: MIDIMappingModel.Row) -> some View {
        switch row.action {
        case .tbar:
            Text(L("midi.tbarHint")).font(.caption).foregroundStyle(.secondary)
        case .inputGain(let input, let lo, let hi):
            TextField(L("hotkeys.arg.input"), value: Binding(get: { input }, set: { model.setAction(row.id, .inputGain(input: $0, minDb: lo, maxDb: hi)) }), format: .number).frame(width: 60)
            TextField(L("midi.minDb"), value: Binding(get: { lo }, set: { model.setAction(row.id, .inputGain(input: input, minDb: $0, maxDb: hi)) }), format: .number).frame(width: 60)
            TextField(L("midi.maxDb"), value: Binding(get: { hi }, set: { model.setAction(row.id, .inputGain(input: input, minDb: lo, maxDb: $0)) }), format: .number).frame(width: 60)
        case .busGain(let bus, let lo, let hi):
            Picker(L("midi.bus"), selection: Binding(get: { bus }, set: { model.setAction(row.id, .busGain(bus: $0, minDb: lo, maxDb: hi)) })) {
                ForEach(Bus.allCases) { Text(L("bus.\($0.name)")).tag($0) }
            }
            .labelsHidden().frame(width: 110)
            TextField(L("midi.minDb"), value: Binding(get: { lo }, set: { model.setAction(row.id, .busGain(bus: bus, minDb: $0, maxDb: hi)) }), format: .number).frame(width: 60)
            TextField(L("midi.maxDb"), value: Binding(get: { hi }, set: { model.setAction(row.id, .busGain(bus: bus, minDb: lo, maxDb: $0)) }), format: .number).frame(width: 60)
        case .action(let a):
            let hotkeyRow = HotkeyEditorModel.Row(keyText: "", action: a, note: "")
            Picker(L("hotkeys.actionKind"), selection: Binding(get: { hotkeyRow.kind }, set: { kind in
                var r = hotkeyRow
                r.kind = kind
                model.setAction(row.id, .action(r.action ?? .command(.cut)))
            })) {
                ForEach(HotkeyEditorModel.ActionKind.allCases.filter { $0 != .other }) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 140)
            if let label = hotkeyRow.kind.argumentLabel {
                TextField(label, value: Binding(get: { hotkeyRow.argument }, set: { v in
                    var r = hotkeyRow
                    r.argument = v
                    model.setAction(row.id, .action(r.action ?? .command(.cut)))
                }), format: .number).frame(width: 60)
            }
        }
    }
}

@MainActor
final class MIDIMappingWindowController: PanelWindowController {
    let model: MIDIMappingModel

    init(model: MIDIMappingModel) {
        self.model = model
        super.init(title: L("midi.windowTitle"), size: NSSize(width: 820, height: 520), autosaveName: "MIDIMapping", content: MIDIMappingView(model: model))
    }

    override func windowWillClose(_ notification: Notification) {
        model.stopRefreshing()
        if model.learningRow != nil { model.cancelLearn() }
        super.windowWillClose(notification)
    }
}
