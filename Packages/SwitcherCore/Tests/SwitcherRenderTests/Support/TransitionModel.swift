// W1-B MixerReducer 转场部分的复刻（Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift 的 advance / cut / startAuto / tbar）。
// SwitcherRenderTests 不能依赖 SwitcherEngine（Engine 与 Render 互不依赖，且本会话不许改 Package.swift），
// 所以 V6 / V7 在渲染侧用这个替身按同一口径推进度：第 s 拍应用命令 → progress 0、startTick = s；第 s + k 拍 progress = k / d；
// k ≥ d 时对调 program / preview 回到空闲。每拍先 advance 再 reduce。口径变了这里要跟着改（契约 TransitionState 的注释是权威）。
import SwitcherContracts

struct TransitionModel {
    var state: MixerState

    init(state: MixerState) { self.state = state }

    /// = MixerReducer.advance 的转场部分（FTB / 叠加动画这里用不着）。
    mutating func advance(to tick: Tick) {
        guard let start = state.transition.startTick, state.transition.source == .auto else { return }
        let d = state.transition.durationTicks
        let k = tick - start
        if d <= 0 || k >= Int64(d) {
            complete()
        } else {
            state.transition.progress = k <= 0 ? 0 : Double(k) / Double(d)
        }
    }

    /// = Command.cut。
    mutating func cut() { complete() }

    /// = Command.autoTransition（类型 / 时长已在 state.transition 里选好）。
    mutating func startAuto(at tick: Tick) {
        guard !state.transition.isActive else { return }
        if state.transition.type == .cut || state.transition.durationTicks <= 0 {
            complete()
        } else {
            state.transition.source = .auto
            state.transition.progress = 0
            state.transition.startTick = tick
        }
    }

    /// = Command.tbar。
    mutating func tbar(_ progress: Double) {
        let p = min(max(progress, 0), 1)
        if p >= 1 {
            complete()
        } else {
            state.transition.source = .tbar
            state.transition.progress = p
            state.transition.startTick = nil
        }
    }

    private mutating func complete() {
        swap(&state.program, &state.preview)
        state.transition.progress = 0
        state.transition.startTick = nil
        state.transition.source = .auto
    }
}
