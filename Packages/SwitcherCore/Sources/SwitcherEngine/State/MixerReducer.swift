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
//
// 转场进行中（`TransitionState.isActive` = progress > 0 || startTick != nil：auto 从应用命令那一拍到对调前一拍，T-bar 推杆在 (0, 1)，
// 拉回 0 = 取消、不算）拒收 fade / setTransition / setTransitionParams / autoTransition / setPreview / setProgram / useTransitionSlot，原样返回（回执 applied = false）；
// cut（立即完成）与 tbar（接管）照收；setTransitionSlot 进行中也收（只改槽）。setPreview / setProgram 是 W5-E 按 Q66 (a) 加的：渲染器转场中按当前的 program 画底、按当前的
// preview 画切进来的画面，中途换掉就是 PGM 上的跳变。
//
// 转场槽（提案 020，P5-2）：`completeTransition` 在 currentSlot 非 nil 时总是把当前那组按槽重拷（幂等）——进行中改了当前槽的，完成那一拍生效；
// fade / setTransition / setTransitionParams 执行后 currentSlot = 当前那组仍对得上的槽（优先原来那个），对不上任何槽 → nil。
// 文件播放（提案 021）：reducer 只记状态（paused / 一次定位请求 (seekTick, seekSeconds)），真正的 pause / seek 由组装方交给 FileInput；
// 新 PGM 那一路若 restartOnProgram，四处换人（cut / auto 完成 / T-bar 提交 / setProgram）在同一拍写定位 0，与手发 seekPlayback(0) 同一条路。

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
                // 完成拍 = 开始拍 + 时长（不是 advance 的目标拍）：逐拍推进与一步到位得到同一个 seekTick（021）
                Self.completeTransition(&s, at: d <= 0 ? start : start + d)
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

    static func completeTransition(_ s: inout MixerState, at tick: Tick) {
        let previousProgram = s.program
        swap(&s.program, &s.preview)
        s.transition.progress = 0
        s.transition.startTick = nil
        s.transition.source = .auto
        // 020：当前那组对应某个槽时按槽重拷（进行中改了当前槽的在这里生效；相同时无感，幂等）
        if let slot = s.transition.currentSlot { s.transition.select(slot: slot) }
        // 021：新 PGM 那一路"切上 PGM 时从头播"
        if s.program != previousProgram { Self.restartIfNeeded(&s, input: s.program, at: tick) }
    }

    /// 021：这一路是文件输入且 restartOnProgram → 写一次定位 0（seekTick = 这一拍）。别的 kind 照存不读，不碰。
    private static func restartIfNeeded(_ s: inout MixerState, input: Int, at tick: Tick) {
        guard let i = inputIndex(input, in: s), s.inputs[i].kind == .file, s.inputs[i].settings.playback.restartOnProgram else { return }
        s.inputs[i].settings.playback.seekSeconds = 0
        s.inputs[i].settings.playback.seekTick = tick
    }

    /// 020：老命令改了当前那组之后，currentSlot = 仍对得上的槽（优先原来那个），对不上 → nil。
    private static func refreshCurrentSlot(_ s: inout MixerState) {
        s.transition.currentSlot = s.transition.slotIndexMatchingCurrentGroup(preferring: s.transition.currentSlot)
    }

    // MARK: reduce

    public func reduce(_ state: MixerState, _ command: Command, at tick: Tick) -> MixerState {
        var s = state
        switch command {
        // 切换
        case .cut:
            Self.completeTransition(&s, at: tick)
        case .fade(let d):
            guard !s.transition.isActive, d >= 0 else { return state }
            s.transition.type = .fade
            s.transition.durationTicks = d
            Self.refreshCurrentSlot(&s)
            Self.startAuto(&s, at: tick)
        case .setTransition(let type, let d):
            guard !s.transition.isActive, d >= 0 else { return state }
            s.transition.type = type
            s.transition.durationTicks = d
            Self.refreshCurrentSlot(&s)
        case .setTransitionParams(var wipe, var stinger):
            guard !s.transition.isActive else { return state }
            if let input = stinger.input, !Self.inputExists(input, in: s) { return state }
            wipe.softness = min(max(wipe.softness, 0), 1)
            stinger.cutAtTick = max(stinger.cutAtTick, 0)
            s.transition.wipe = wipe
            s.transition.stinger = stinger
            Self.refreshCurrentSlot(&s)
        case .setTransitionSlot(let slot, var config):
            // 020：只改槽，转场进行中也收；钳位与 016 同口径；改的是当前槽且空闲 → 当前那组同时重拷（进行中的在完成那一拍重拷）
            guard TransitionSlot.indexRange.contains(slot), slot - 1 < s.transition.slots.count else { return state }
            if let input = config.stinger.input, !Self.inputExists(input, in: s) { return state }
            config.durationTicks = max(config.durationTicks, 0)
            config.wipe.softness = min(max(config.wipe.softness, 0), 1)
            config.stinger.cutAtTick = max(config.stinger.cutAtTick, 0)
            guard s.transition.slots[slot - 1] != config else { return state }
            s.transition.slots[slot - 1] = config
            if s.transition.currentSlot == slot, !s.transition.isActive { s.transition.currentGroup = config }
        case .useTransitionSlot(let slot, let start):
            // 020：转场进行中被拒（与 setTransition / autoTransition 同口径）；只选中且已是当前槽、当前那组相同 → 原样
            guard !s.transition.isActive, TransitionSlot.indexRange.contains(slot), slot - 1 < s.transition.slots.count else { return state }
            if !start, s.transition.currentSlot == slot, s.transition.currentGroup == s.transition.slots[slot - 1] { return state }
            s.transition.select(slot: slot)
            if start { Self.startAuto(&s, at: tick) }
        case .setFTBDuration(let ticks):
            // 020：渐变进行中按当前电平对应的起点回拨，电平从当前值按新时长继续走；0 = 立即到位
            guard ticks >= 0, ticks != s.ftb.durationTicks else { return state }
            s.ftb.durationTicks = ticks
            if s.ftb.startTick != nil {
                if ticks <= 0 {
                    s.ftb.level = s.ftb.on ? 1 : 0
                    s.ftb.startTick = nil
                } else {
                    s.ftb.startTick = Self.equivalentStart(currentLevel: s.ftb.level, duration: ticks, at: tick, rising: s.ftb.on)
                    s = advance(s, to: tick)
                }
            }
        case .autoTransition:
            guard !s.transition.isActive else { return state }
            Self.startAuto(&s, at: tick)
        case .setPreview(let input):
            guard !s.transition.isActive, Self.isValidReference(input, in: s) else { return state }
            s.preview = input
        case .setProgram(let input):
            guard !s.transition.isActive, Self.isValidReference(input, in: s) else { return state }
            let previous = s.program
            s.program = input
            if input != previous { Self.restartIfNeeded(&s, input: input, at: tick) }   // 021
        case .tbar(let progress):
            let p = min(max(progress, 0), 1)
            if p >= 1 {
                Self.completeTransition(&s, at: tick)
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
        case .setOverlayDecoration(let channel, let border, let anchor, let previewOn):
            guard let i = Self.overlayIndex(channel) else { return state }
            s.overlays[i].border = border
            s.overlays[i].anchor = anchor
            s.overlays[i].previewOn = previewOn

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
        case .setMonitorMode(let mode):
            s.audio.monitorMode = mode
        case .setMonitorSource(let bus):
            // 提案 026：耳机听哪条总线；headphones = 听耳机总线自己（P5-3 起合法）；相同值状态不变
            s.audio.monitorSource = bus
        case .setBusEffects(let bus, let effects):
            guard let i = Self.busIndex(bus, in: s) else { return state }
            s.audio.buses[i].effects = effects
        case .setInputAudio(let input, let solo, let afv, let routing):
            // 023 五：nil = 不动；全 nil 或全与现状相同 → 状态不变（回执 applied = false）
            guard let i = Self.inputIndex(input, in: s) else { return state }
            if let solo { s.inputs[i].settings.audio.solo = solo }
            if let afv { s.inputs[i].settings.audio.afv = afv }
            if let routing { s.inputs[i].settings.audio.routing = routing }

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
        case .setOutputEnabled(let output, let on):
            // record / stream 走 startRecord / startStream（语义与起止拍绑定），这里拒绝
            guard let i = s.outputs.firstIndex(where: { $0.number == output }),
                  s.outputs[i].kind != .record, s.outputs[i].kind != .stream else { return state }
            s.outputs[i].enabled = on
        case .renameOutput(let output, let name):
            guard let i = s.outputs.firstIndex(where: { $0.number == output }) else { return state }
            s.outputs[i].name = name

        // 输入表
        // 输入表（进来的设置剥掉过渡做法的 "border" 效果格，019 D：Show.load / loadShow / addOutput / setOutputSettings 都搬迁清死数据，这两条是最后一个入口；没有叠加通道的上下文所以直接清）
        case .setInputSettings(let input, let settings):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].settings = Self.strippingLegacyBorder(settings.clamped())
        case .renameInput(let input, let name):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].name = name
        case .addInput(let config):
            guard config.number > MixerState.noInput, !Self.inputExists(config.number, in: s) else { return state }
            var c = config
            c.settings = Self.strippingLegacyBorder(c.settings.clamped())
            let at = s.inputs.firstIndex { $0.number > c.number } ?? s.inputs.count
            s.inputs.insert(c, at: at)
        case .removeInput(let input):
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs.remove(at: i)
            if s.program == input { s.program = MixerState.noInput }
            if s.preview == input { s.preview = MixerState.noInput }
            for k in s.overlays.indices where s.overlays[k].input == input { s.overlays[k].input = nil }
            // Stinger 引用与叠加同口径（P4）：留着悬空的话，带着它的 setTransitionParams（App 改 Wipe 参数也带）会被整条拒掉
            if s.transition.stinger.input == input { s.transition.stinger.input = nil }
            // 020：四个槽里的 Stinger 引用同样清
            for k in s.transition.slots.indices where s.transition.slots[k].stinger.input == input { s.transition.slots[k].stinger.input = nil }
        case .setInputSource(let input, let source):
            // 编号 / 名字 / 设置 / PGM / PVW / 叠加引用全部保留；kind 由 source 推出，不另存
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].source = source
        case .setPlayback(let input, let paused):
            // 021：只对文件输入；相同值状态不变
            guard let i = Self.inputIndex(input, in: s), s.inputs[i].kind == .file else { return state }
            s.inputs[i].settings.playback.paused = paused
        case .seekPlayback(let input, let seconds):
            // 021：一次定位请求 = (seekTick, seekSeconds)；负数 / 非有限与校验器同判、原样返回（setInputSettings 整体带进来的负值才钳 0）；同一拍同一位置再发状态不变
            guard let i = Self.inputIndex(input, in: s), s.inputs[i].kind == .file, seconds.isFinite, seconds >= 0 else { return state }
            s.inputs[i].settings.playback.seekSeconds = seconds
            s.inputs[i].settings.playback.seekTick = tick
        case .setInputColor(let input, let color):
            // 023 四：分类颜色；相同值状态不变
            guard let i = Self.inputIndex(input, in: s) else { return state }
            s.inputs[i].color = color

        // 输出表（进来的设置先按 Show.load 同一套规则搬过渡键（P4）：API 客户端直接带 extra["layout"] 的不会静默变成默认布局）
        case .addOutput(let config):
            guard config.number > 0, s.output(config.number) == nil else { return state }
            var c = config
            c.settings = c.settings.migratingLegacyKeys()
            let at = s.outputs.firstIndex { $0.number > c.number } ?? s.outputs.count
            s.outputs.insert(c, at: at)
        case .removeOutput(let output):
            guard let i = s.outputs.firstIndex(where: { $0.number == output }) else { return state }
            s.outputs.remove(at: i)
        case .setOutputSettings(let output, let settings):
            guard let i = s.outputs.firstIndex(where: { $0.number == output }) else { return state }
            s.outputs[i].settings = settings.migratingLegacyKeys()

        // 节目（整份先搬迁，与 Show.load 读文件同一结果；搬迁不碰 validate 查的结构，所以与命令校验器的判定一致）
        case .loadShow(let show):
            let loaded = show.migratingLegacyKeys().makeState()
            guard (try? loaded.validate()) != nil else { return state }
            s = loaded
        }
        return s
    }

    // MARK: 辅助

    private static func startAuto(_ s: inout MixerState, at tick: Tick) {
        if s.transition.type == .cut || s.transition.durationTicks <= 0 {
            completeTransition(&s, at: tick)
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

extension MixerReducer {
    /// 019 D：效果链里 id = "border" 的格一律去掉（`OverlayBorder.legacyEffectID`，`Show.migratingLegacyKeys()` 同一口径），别的格原样、顺序不变。
    static func strippingLegacyBorder(_ settings: InputSettings) -> InputSettings {
        guard settings.effects.contains(where: { $0.id == OverlayBorder.legacyEffectID }) else { return settings }
        var s = settings
        s.effects.removeAll { $0.id == OverlayBorder.legacyEffectID }
        return s
    }
}
