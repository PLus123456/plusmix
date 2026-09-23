// 转场参数（W3-E2 交付第 2 条）：Wipe 方向（五向）/ 软边（0–0.3）、Stinger 输入 / 换底拍，落 `TransitionState.wipe` / `.stinger`。
// 发 setTransitionParams（提案 016，用户 2026-09-23 批）：只整体替换这两组，别的字段不碰，叠加进出动画 / FTB 渐变进行中照发、不打断它们
// （之前没有这条命令，走 loadShow 整体替换：会盖掉别的来源的改动，还得等所有动画空闲）。
// reducer 在转场进行中（含 T-bar 推到一半）拒绝，所以转场中改的先在面板上显示（pending），等转场结束再发。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class TransitionParamsModel: ObservableObject {
    @Published private(set) var state = MixerState()
    /// 还没进快照的参数（面板上先显示它）。
    @Published private(set) var pending: (wipe: WipeParams, stinger: StingerParams)?
    var send: ((Command) -> Void)?
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
            if state.transition.isActive {
                sentAt = nil   // 发出后别的来源先起了转场：reducer 会拒，转场结束再发
            } else if Date().timeIntervalSince(t) > 1 {
                pending = nil; sentAt = nil   // 被拒（stinger 用的输入刚被删）/ 被忽略：放弃，显示快照的值
            }
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

    private func flushIfIdle() {
        guard let p = pending, sentAt == nil, !state.transition.isActive else { return }
        sentAt = Date()
        send?(.setTransitionParams(wipe: p.wipe, stinger: p.stinger))
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
