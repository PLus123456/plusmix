// 转场参数（W3-E2 交付第 2 条）：Wipe 方向（五向）/ 软边（0–0.3）、Stinger 输入 / 换底拍。
// W5-M（prompt 100）起按槽编辑：每个转场槽 ▾ 里的"参数…"打开这一个槽的参数，发 setTransitionSlot（提案 020）——只改这个槽，别的字段不碰，
// 转场进行中也收（只是改配置：进行中的那一次按开始时的参数走完，改的若是当前槽，做完那一拍起当前那组按槽重拷），叠加进出动画 / FTB 渐变照常。
// 原来改的是当前那组（setTransitionParams，进行中被拒，所以要先挂着等转场结束再发）；槽落地后不用等了。
// 发出去到快照回来之间面板先显示新值（pending）；1 秒还没进快照（输入刚被删、校验器拒）就放弃，回到快照的值。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class TransitionParamsModel: ObservableObject {
    @Published private(set) var state = MixerState()
    /// 编辑的是哪个槽（1–4）。换槽时丢掉还没进快照的那份。
    @Published var slot = 1 {
        didSet {
            guard slot != oldValue else { return }
            pending = nil
            sentAt = nil
        }
    }
    /// 还没进快照的配置（面板上先显示它）。
    @Published private(set) var pending: TransitionSlot?
    var send: ((Command) -> Void)?
    /// 发出去的时刻（等太久就放弃，面板回到快照的值）。
    private var sentAt: Date?

    /// 软边的合法范围（占画面比例）。
    static let softnessRange = 0.0...0.3
    static let directions: [WipeDirection] = [.leftToRight, .rightToLeft, .topToBottom, .bottomToTop, .diagonal]

    /// 快照里这个槽现在的配置（槽号不对时退回当前那组，免得面板崩）。
    var stored: TransitionSlot {
        let slots = state.transition.slots
        return TransitionSlot.indexRange.contains(slot) && slot - 1 < slots.count ? slots[slot - 1] : state.transition.currentGroup
    }
    /// 面板上显示的配置。
    var config: TransitionSlot { pending ?? stored }
    var wipe: WipeParams { config.wipe }
    var stinger: StingerParams { config.stinger }
    var isPending: Bool { pending != nil }

    func apply(state: MixerState) {
        self.state = state
        guard let p = pending else { return }
        if stored == p {
            pending = nil
            sentAt = nil
        } else if let t = sentAt, Date().timeIntervalSince(t) > 1 {
            pending = nil   // 被拒（stinger 用的输入刚被删）/ 被别处又改了：放弃，显示快照的值
            sentAt = nil
        }
    }

    func setWipeDirection(_ d: WipeDirection) { update { $0.wipe.direction = d } }
    func setWipeSoftness(_ s: Double) { update { $0.wipe.softness = min(max(s, Self.softnessRange.lowerBound), Self.softnessRange.upperBound) } }
    func setStingerInput(_ n: Int?) { update { $0.stinger.input = n } }
    /// 换底拍钳到 0…这个槽的时长（≥ 时长 = 完成时换，StingerParams.cutAtTick 的口径）。
    func setStingerCutTick(_ t: Int) { update { $0.stinger.cutAtTick = min(max(t, 0), max(0, $0.durationTicks)) } }

    private func update(_ body: (inout TransitionSlot) -> Void) {
        var c = config
        body(&c)
        guard c != config else { return }
        pending = c
        sentAt = Date()
        send?(.setTransitionSlot(slot: slot, config: c))
    }
}

/// 弹出面板的内容（一个槽的参数）。
struct TransitionParamsView: View {
    @ObservedObject var model: TransitionParamsModel

    var body: some View {
        Form {
            Section {
                Text(L("transition.params.slotTitle", model.slot, SlotText.description(model.config, rate: model.state.format.frameRate)))
                    .font(.headline)
            }
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
                Stepper(value: Binding(get: { model.stinger.cutAtTick }, set: { model.setStingerCutTick($0) }), in: 0...max(0, model.config.durationTicks)) {
                    Text(L("transition.stinger.cutAtTick", model.stinger.cutAtTick, model.config.durationTicks))
                }
                Text(L("transition.stinger.hint")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.isPending { Text(L("transition.params.pending")).font(.caption).foregroundStyle(.orange) }
                Text(L("transition.params.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340, height: 460)
    }
}
