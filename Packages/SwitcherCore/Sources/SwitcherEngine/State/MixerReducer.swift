import Foundation
import SwitcherContracts

// 状态机的纯函数部分（CONTRACTS.md §2.6 MixerReducing；设计方案 §5 转场、§9.1）。
//
// reduce：一条命令 → 新状态。纯函数、不看时钟；非法命令（不存在的输入 / 输出、通道越界、kind 不符、负时长）原样返回。
// advance：把状态推进到某一拍。所有随时间变化的量（转场 progress、FTB level、叠加 animProgress）都由
// (startTick, durationTicks, 目标) 与 tick 直接算出，不依赖"上一拍"，所以对同一个 (state, tick) 永远得到同一结果，
// 逐拍推进与一步到位等价。中途反转目标（FTB / 叠加开关）时，reduce 把 startTick 回拨到"当前电平对应的起点"，
// 让电平从当前值继续走而不跳变。
//
// 进度口径（契约）：auto 转场第 s 拍应用，第 s + k 拍 progress = k / durationTicks；k ≥ durationTicks 时对调 program /
// preview 并回到空闲。Cut 是原子换号，没有中间态。T-bar：progress = 推杆位置，≥ 1 提交。

/// `MixerReducing` 的实现。
public struct MixerReducer: MixerReducing {
    public init() {}

    // MARK: advance

    public func advance(_ state: MixerState, to tick: Tick) -> MixerState {
        var s = state
        // 转场（只有 auto 模式随拍推进）
        if let start = s.transition.startTick, s.transition.source == .auto {
            let d = s.transition.durationTicks
            let k = tick - start
            if d <= 0 || k >= Int64(d) {
                Self.completeTransition(&s)
            } else {
                s.transition.progress = k <= 0 ? 0 : Double(k) / Double(d)
            }
        }
        // FTB
        if let start = s.ftb.startTick {
            let (level, done) = Self.ramp(from: start, duration: s.ftb.durationTicks, at: tick, rising: s.ftb.on)
            s.ftb.level = level
            if done { s.ftb.startTick = nil }
        }
        // 叠加进出动画
        for i in s.overlays.indices {
            guard let start = s.overlays[i].startTick else { continue }
            let (level, done) = Self.ramp(from: start, duration: s.overlays[i].animation.durationTicks, at: tick, rising: s.overlays[i].on)
            s.overlays[i].animProgress = level
            if done { s.overlays[i].startTick = nil }
        }
        return s
    }

    /// 从 start 起用 duration 拍从 0 走到 1（rising）或从 1 走到 0；返回 (当前值, 是否到位)。
    private static func ramp(from start: Tick, duration: Int, at tick: Tick, rising: Bool) -> (Double, Bool) {
        if duration <= 0 { return (rising ? 1 : 0, true) }
        let k = tick - start
        if k <= 0 { return (rising ? 0 : 1, false) }
        if k >= Int64(duration) { return (rising ? 1 : 0, true) }
        let x = Double(k) / Double(duration)
        return (rising ? x : 1 - x, false)
    }

    /// 反转目标时算等效起点：让 advance 在 tick 得到 currentLevel（按拍取整）。
    private static func equivalentStart(currentLevel: Double, duration: Int, at tick: Tick, rising: Bool) -> Tick {
        let progressed = rising ? currentLevel : 1 - currentLevel
        let k = Int((progressed * Double(duration)).rounded())
        return tick - k
    }

    static func completeTransition(_ s: inout MixerState) {
        swap(&s.program, &s.preview)
        s.transition.progress = 0
        s.transition.startTick = nil
        s.transition.source = .auto
    }

    // MARK: reduce

    public func reduce(_ state: MixerState, _ command: Command, at tick: Tick) -> MixerState {
        var s = state
        switch command {
        // 切换
        case .cut:
            Self.completeTransition(&s)
        case .fade(let d):
            guard !s.transition.isActive, d >= 0 else { return state }
            s.transition.type = .fade
            s.transition.durationTicks = d
            Self.startAuto(&s, at: tick)
        case .setTransition(let type, let d):
            guard !s.transition.isActive, d >= 0 else { return state }
            s.transition.type = type
            s.transition.durationTicks = d
        case .autoTransition:
            guard !s.transition.isActive else { return state }
            Self.startAuto(&s, at: tick)
        case .setPreview(let input):
            guard Self.isValidReference(input, in: s) else { return state }
            s.preview = input
        case .setProgram(let input):
            guard Self.isValidReference(input, in: s) else { return state }
            s.program = input
        case .tbar(let progress):
            let p = min(max(progress, 0), 1)
            if p >= 1 {
                Self.completeTransition(&s)
            } else {
                s.transition.source = .tbar
                s.transition.progress = p
                s.transition.startTick = nil
            }
        case .ftb(let on):
            guard on != s.ftb.on else { return state }
            s.ftb.on = on
            if s.ftb.durationTicks <= 0 {
                s.ftb.level = on ? 1 : 0
                s.ftb.startTick = nil
            } else {
                s.ftb.startTick = Self.equivalentStart(currentLevel: s.ftb.level, duration: s.ftb.durationTicks, at: tick, rising: on)
                s = advance(s, to: tick)
            }

        // 叠加
        case .overlay(let channel, let on, let input):
            guard let i = Self.overlayIndex(channel) else { return state }
            if let input {
                guard Self.inputExists(input, in: s) else { return state }
                s.overlays[i].input = input
            }
            if on != s.overlays[i].on {
                s.overlays[i].on = on
                let d = s.overlays[i].animation.durationTicks
                if d <= 0 {
                    s.overlays[i].animProgress = on ? 1 : 0
                    s.overlays[i].startTick = nil
                } else {
                    s.overlays[i].startTick = Self.equivalentStart(currentLevel: s.overlays[i].animProgress, duration: d, at: tick, rising: on)
                    s = advance(s, to: tick)
                }
            }
        case .setOverlay(let channel, let rect, let animation):
            guard let i = Self.overlayIndex(channel) else { return state }
            s.overlays[i].rect = rect
            var a = animation
            a.durationTicks = max(a.durationTicks, 0)
            s.overlays[i].animation = a

        // 音频
        case .audioGain(let input, let dB):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].settings.audio.gainDb = Self.clampGain(dB)
        case .mute(let input, let on):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].settings.audio.muted = on
        case .busGain(let bus, let dB):
            guard let i = Self.busIndex(bus, in: s) else { return state }
            s.audio.buses[i].gainDb = Self.clampGain(dB)
        case .busMute(let bus, let on):
            guard let i = Self.busIndex(bus, in: s) else { return state }
            s.audio.buses[i].muted = on
        case .setAFV(let on):
            s.audio.afv = on

        // 输出
        case .startRecord(let output):
            guard let i = Self.outputIndex(output, kind: .record, in: s) else { return state }
            s.outputs[i].enabled = true
        case .stopRecord(let output):
            guard let i = Self.outputIndex(output, kind: .record, in: s) else { return state }
            s.outputs[i].enabled = false
        case .startStream(let output):
            guard let i = Self.outputIndex(output, kind: .stream, in: s) else { return state }
            s.outputs[i].enabled = true
        case .stopStream(let output):
            guard let i = Self.outputIndex(output, kind: .stream, in: s) else { return state }
            s.outputs[i].enabled = false

        // 输入表
        case .setInputSettings(let input, let settings):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].settings = settings.clamped()
        case .renameInput(let input, let name):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].name = name
        case .addInput(let config):
            guard config.number > MixerState.noInput, !Self.inputExists(config.number, in: s) else { return state }
            var c = config
            c.settings = c.settings.clamped()
            let at = s.inputs.firstIndex { $0.number > c.number } ?? s.inputs.count
            s.inputs.insert(c, at: at)
        case .removeInput(let input):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs.remove(at: i)
            if s.program == input { s.program = MixerState.noInput }
            if s.preview == input { s.preview = MixerState.noInput }
            for k in s.overlays.indices where s.overlays[k].input == input { s.overlays[k].input = nil }

        // 输出表
        case .addOutput(let config):
            guard config.number > 0, s.output(config.number) == nil else { return state }
            let at = s.outputs.firstIndex { $0.number > config.number } ?? s.outputs.count
            s.outputs.insert(config, at: at)
        case .removeOutput(let output):
            guard let i = s.outputs.firstIndex(where: { $0.number == output }) else { return state }
            s.outputs.remove(at: i)
        case .setOutputSettings(let output, let settings):
            guard let i = s.outputs.firstIndex(where: { $0.number == output }) else { return state }
            s.outputs[i].settings = settings

        // 节目
        case .loadShow(let show):
            let loaded = show.makeState()
            guard (try? loaded.validate()) != nil else { return state }
            s = loaded
        }
        return s
    }

    // MARK: 辅助

    private static func startAuto(_ s: inout MixerState, at tick: Tick) {
        if s.transition.type == .cut || s.transition.durationTicks <= 0 {
            completeTransition(&s)
        } else {
            s.transition.source = .auto
            s.transition.progress = 0
            s.transition.startTick = tick
        }
    }

    private static func clampGain(_ dB: Double) -> Double {
        min(max(dB, InputAudioSettings.gainRangeDb.lowerBound), InputAudioSettings.gainRangeDb.upperBound)
    }
    private static func overlayIndex(_ channel: Int) -> Int? {
        (1...MixerState.overlayCount).contains(channel) ? channel - 1 : nil
    }
    private static func inputExists(_ number: Int, in s: MixerState) -> Bool { s.input(number) != nil }
    private static func isValidReference(_ number: Int, in s: MixerState) -> Bool { number == MixerState.noInput || inputExists(number, in: s) }
    private static func inputIndex(_ number: Int, in s: MixerState) -> Int? { s.inputs.firstIndex { $0.number == number } }
    private static func busIndex(_ bus: Bus, in s: MixerState) -> Int? { s.audio.buses.firstIndex { $0.bus == bus } }
    private static func outputIndex(_ number: Int, kind: OutputKind, in s: MixerState) -> Int? {
        guard let i = s.outputs.firstIndex(where: { $0.number == number }), s.outputs[i].kind == kind else { return nil }
        return i
    }
}
