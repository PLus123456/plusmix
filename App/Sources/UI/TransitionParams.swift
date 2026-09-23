// 转场参数（W3-E2 交付第 2 条）：Wipe 方向（五向）/ 软边（0–0.3）、Stinger 输入 / 换底拍，落 `TransitionState.wipe` / `.stinger`。
// 契约没有改这两组参数的命令（只有 setTransition(type:durationTicks:)），所以按 prompt 先用 loadShow 整体替换：拿最新快照、只换这两项、发 loadShow。
// 整体替换的代价写清楚（reports/w3-app-3.md §3、提案 016）：
// - loadShow 会 resetTransientState：转场 / 叠加进出动画 / FTB 渐变进行中发，会把它们直接打到终点（转场是作废、不对调）。
//   所以动画进行中只在面板上先显示新值（pending），等全部空闲再发。
// - 替换用的是 App 手里的快照：从快照到命令进状态机之间（≤ 1/60 s + 命令队列）别的来源（API / MIDI / 快捷键）改的东西会被盖回去。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class TransitionParamsModel: ObservableObject {
    @Published private(set) var state = MixerState()
    /// 还没进快照的参数（面板上先显示它）。
    @Published private(set) var pending: (wipe: WipeParams, stinger: StingerParams)?
    var send: ((Command) -> Void)?
    /// loadShow 用的节目名（状态机不看它，只是让命令日志好认）。
    var showName = ""
    /// 已经发出去、等快照回来的时刻（等太久就放弃，面板回到快照的值）。
    private var sentAt: Date?

    /// 软边的合法范围（占画面比例）。
    static let softnessRange = 0.0...0.3
    static let directions: [WipeDirection] = [.leftToRight, .rightToLeft, .topToBottom, .bottomToTop, .diagonal]

    var wipe: WipeParams { pending?.wipe ?? state.transition.wipe }
    var stinger: StingerParams { pending?.stinger ?? state.transition.stinger }
    var isPending: Bool { pending != nil }

    func apply(state: MixerState) {
        self.state = state
        guard let p = pending else { return }
        if state.transition.wipe == p.wipe && state.transition.stinger == p.stinger {
            pending = nil
            sentAt = nil
        } else if let t = sentAt {
            if Date().timeIntervalSince(t) > 1 { pending = nil; sentAt = nil }   // 被拒 / 被忽略：放弃，显示快照的值
        } else {
            flushIfIdle()
        }
    }

    func setWipeDirection(_ d: WipeDirection) { update { $0.wipe.direction = d } }
    func setWipeSoftness(_ s: Double) { update { $0.wipe.softness = min(max(s, Self.softnessRange.lowerBound), Self.softnessRange.upperBound) } }
    func setStingerInput(_ n: Int?) { update { $0.stinger.input = n } }
    /// 换底拍钳到 0…时长（≥ 时长 = 完成时换，StingerParams.cutAtTick 的口径）。
    func setStingerCutTick(_ t: Int) { update { $0.stinger.cutAtTick = min(max(t, 0), max(0, state.transition.durationTicks)) } }

    private func update(_ body: (inout (wipe: WipeParams, stinger: StingerParams)) -> Void) {
        var p = (wipe: wipe, stinger: stinger)
        body(&p)
        guard p.wipe != wipe || p.stinger != stinger else { return }
        pending = p
        sentAt = nil
        flushIfIdle()
    }

    /// 转场、叠加进出动画、FTB 渐变都空闲（loadShow 的 resetTransientState 打断不到任何东西）。
    static func isIdle(_ s: MixerState) -> Bool {
        !s.transition.isActive && s.ftb.startTick == nil && s.overlays.allSatisfy { $0.startTick == nil }
    }

    private func flushIfIdle() {
        guard let p = pending, sentAt == nil, Self.isIdle(state) else { return }
        var s = state
        s.transition.wipe = p.wipe
        s.transition.stinger = p.stinger
        sentAt = Date()
        send?(.loadShow(show: Show(name: showName, state: s)))
    }
}

/// 弹出面板的内容。
struct TransitionParamsView: View {
    @ObservedObject var model: TransitionParamsModel

    var body: some View {
        Form {
            Section(L("transition.wipe.title")) {
                Picker(L("transition.wipe.direction"), selection: Binding(get: { model.wipe.direction }, set: { model.setWipeDirection($0) })) {
                    ForEach(TransitionParamsModel.directions, id: \.self) { Text(L("transition.wipe.direction.\($0.rawValue)")).tag($0) }
                }
                Slider(value: Binding(get: { model.wipe.softness }, set: { model.setWipeSoftness($0) }), in: TransitionParamsModel.softnessRange) {
                    Text(L("transition.wipe.softness", model.wipe.softness))
                }
            }
            Section(L("transition.stinger.title")) {
                Picker(L("transition.stinger.input"), selection: Binding(get: { model.stinger.input ?? 0 }, set: { model.setStingerInput($0 == 0 ? nil : $0) })) {
                    Text(L("transition.stinger.noInput")).tag(0)
                    ForEach(model.state.inputs) { Text(L("source.input", $0.number, $0.name)).tag($0.number) }
                }
                Stepper(value: Binding(get: { model.stinger.cutAtTick }, set: { model.setStingerCutTick($0) }), in: 0...max(0, model.state.transition.durationTicks)) {
                    Text(L("transition.stinger.cutAtTick", model.stinger.cutAtTick, model.state.transition.durationTicks))
                }
                Text(L("transition.stinger.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.isPending { Text(L("transition.params.pending")).font(.caption).foregroundStyle(.orange) }
                Text(L("transition.params.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340, height: 420)
    }
}
