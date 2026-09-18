import Foundation
import SwitcherContracts

// W2-E 引擎侧：音频跟随视频（设计方案 §7 AFV）与音频参数的"事件口径"。
//
// 音频包（SwitcherAudioIntegration）看不到拍，只认这里的事件：每件事都带拍点换算好的 host time（铁律 5），
// 音频侧在同一 host 时基上定位交叉淡变的起点、长度、FTB 的斜坡。事件由 `AudioStateBridge` 从状态机推导，
// 引擎不依赖任何音频实现（依赖方向：Engine 只见 Contracts）。

/// 音频侧需要从状态机知道的事。
public enum AudioControlEvent: Sendable, Hashable {
    /// 输入表变了：新增的配置、删除的编号。音频侧据此挂 / 摘槽位（环由组装方另行注册）。
    case inputsChanged(added: [InputConfig], removed: [Int])
    /// 某路输入的音频参数（路由 / 增益 / 静音 / 独听 / 声像 / 延迟补偿）变了。
    case inputAudioSettings(input: Int, settings: InputAudioSettings)
    /// 总线增益 / 静音变了（恰好 4 条，顺序 = Bus.allCases）。
    case buses([BusState])
    /// 耳机监听方式变了。
    case monitorMode(MonitorMode)
    /// AFV 开关翻转。音频侧按当前 PGM / PVW / 转场进度重新门控（`AudioProgramGate.gains(for:)`）。
    case afv(on: Bool)
    /// 瞬时切换（Cut / setProgram / 时长 0 的 auto）：PGM from → to，在第 tick 拍（拍点 at）生效。
    case cut(from: Int, to: Int, tick: Tick, at: HostTime)
    /// 转场开始：from（PGM）→ to（PVW）。auto：起点 = 第 tick 拍的拍点 at、长度 = durationTicks 拍 = duration；
    /// tbar：进度由 `tbarProgress` 逐条给出，at / duration 只是信息。
    case transitionStarted(from: Int, to: Int, type: TransitionType, source: TransitionSource, tick: Tick, at: HostTime,
                           durationTicks: Int, duration: HostDuration)
    /// T-bar 推杆位置（source = tbar 的转场每次变化一条）。
    case tbarProgress(from: Int, to: Int, progress: Double)
    /// 转场结束：completed = 对调已发生（program / preview 是对调后的）；false = 被取消（例如中途 removeInput）。
    case transitionEnded(program: Int, preview: Int, tick: Tick, at: HostTime, completed: Bool)
    /// FTB 目标翻转：向 on 走。斜坡起点 = 第 startTick 拍的拍点 at（反转时状态机已把起点回拨到"当前电平对应的等效起点"），
    /// 时长 durationTicks 拍 = duration；duration 为 0 = 立即到位。
    case fadeToBlack(on: Bool, startTick: Tick, at: HostTime, durationTicks: Int, duration: HostDuration)
}

/// 事件接收方。转场类事件在**状态机线程**上同步到达（`prepare` / `apply` 返回前），实现必须立即返回、不阻塞、不进 actor；
/// 快照 diff 类事件在调用 `AudioStateBridge.pollSnapshot()` 的线程（音频控制线程）上到达。
public protocol AudioControlEventSink: AnyObject, Sendable {
    func audioControl(_ event: AudioControlEvent)
}

/// AFV 门控与 FTB 斜坡的纯函数（音频侧和测试共用一份口径）。
public enum AudioProgramGate {
    /// 每路输入应有的"跟随视频"增益（0…1）：
    /// - AFV 关：全部 1（音频不跟随，各路只受自己的推子 / 静音 / 路由控制）。
    /// - AFV 开：PGM 输入 1；转场进行中 PVW 输入按等幅曲线 sin(p·π/2)、PGM 输入 cos(p·π/2)（p = 进度，新画面盖住旧画面的比例）；
    ///   其余 0。编号 0（黑场）没有音频。叠加通道不影响门控（W2-E 口径，见报告 §4）。
    public static func gains(for state: MixerState) -> [Int: Float] {
        var out: [Int: Float] = [:]
        let afv = state.audio.afv
        let p = state.transition.isActive ? min(max(state.transition.progress, 0), 1) : 0
        let inTransition = state.transition.isActive
        for input in state.inputs {
            let n = input.number
            if !afv { out[n] = 1; continue }
            var g: Float = 0
            if n == state.program {
                g = inTransition ? Float(cos(p * Double.pi / 2)) : 1
            } else if inTransition && n == state.preview {
                g = Float(sin(p * Double.pi / 2))
            }
            out[n] = g
        }
        return out
    }

    /// FTB 在时刻 `at` 的黑比例：从 `start` 起用 `duration` 线性走到目标（on：0 → 1，off：1 → 0）；duration 为 0 立即到位；
    /// `start` 之前是起点值。与状态机 `MixerReducer.advance` 的斜坡同一口径（那边按拍，这边按 host time；反转时状态机已把
    /// startTick 回拨到"当前电平对应的等效起点"，所以这里永远是整段斜坡）。
    public static func fadeToBlackLevel(at: HostTime, on: Bool, start: HostTime, duration: HostDuration) -> Double {
        let target: Double = on ? 1 : 0
        guard duration.ticks > 0 else { return target }
        if at <= start { return 1 - target }
        let x = Double((at - start).ticks) / Double(duration.ticks)
        if x >= 1 { return target }
        return on ? x : 1 - x
    }
}
