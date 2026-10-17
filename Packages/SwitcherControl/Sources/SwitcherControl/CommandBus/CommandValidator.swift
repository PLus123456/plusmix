import SwitcherContracts

// 结构性校验：reducer（W1-B）对非法命令是"原样返回、不出声"（契约 MixerReducing 的约定），API 用户会以为成功了。
// 总线在入口按同一套规则先查一遍，给出理由（HTTP 400）。只查"看一眼状态就能判定、且不随拍变化"的条件：
// 引用的输入 / 输出是否存在、输出 kind 是否匹配、叠加通道范围、负时长、编号重复、节目文件不变量。
// 不查随时间变的条件（转场进行中再 fade、FTB 目标已相同）——那些在应用那一拍才有定论，仍由 reducer 决定。
// CommandBusTests.testValidator_agreesWithReducer 保证：这里拒绝的，reducer 也一定原样返回。

/// 命令的结构性校验器。
public enum CommandValidator {
    /// 命令在当前状态下结构性非法的理由；nil = 放行（交给 reducer）。
    public static func reason(rejecting command: Command, in s: MixerState) -> String? {
        switch command {
        case .cut, .tbar, .ftb, .setAFV:
            return nil
        case .autoTransition:
            // 提案 029：空闲时要执行的当前那组是没选输入的 Stinger → 拒（空闲时它只随命令变）；进行中照旧交给 reducer
            //（进行中再发本来就忽略，完成或取消那一拍当前那组还可能按槽重拷）
            let t = s.transition
            guard !t.isActive, t.currentGroup.isStingerWithoutInput else { return nil }
            return t.currentSlot.map { "转场 \($0) 是 Stinger、还没选输入" } ?? "当前转场是 Stinger、还没选输入"
        case .fade(let d):
            return d < 0 ? "转场时长不能为负：\(d)" : nil
        case .setTransition(_, let d):
            return d < 0 ? "转场时长不能为负：\(d)" : nil
        case .setTransitionParams(_, let stinger):
            // 转场进行中被拒是随拍变的条件，留给 reducer；这里只查引用
            if let input = stinger.input, s.input(input) == nil { return "Stinger 用的输入 \(input) 不存在" }
            return nil
        case .setPreview(let input), .setProgram(let input):
            return inputReference(input, in: s)
        case .setTransitionSlot(let slot, let config):
            // 提案 020：槽号与 Stinger 引用入口就拒；"进行中"由 reducer 定（它进行中也收）
            if !TransitionSlot.indexRange.contains(slot) { return "转场槽必须是 1…\(TransitionSlot.count)：\(slot)" }
            if let input = config.stinger.input, s.input(input) == nil { return "Stinger 用的输入 \(input) 不存在" }
            return nil
        case .useTransitionSlot(let slot, let start):
            guard TransitionSlot.indexRange.contains(slot) else { return "转场槽必须是 1…\(TransitionSlot.count)：\(slot)" }
            // 提案 029：没选输入的 Stinger 槽不执行（只选中照常）；槽的配置只随命令变，入口就拒（reducer 同判）
            if start, slot - 1 < s.transition.slots.count, s.transition.slots[slot - 1].isStingerWithoutInput { return "转场 \(slot) 是 Stinger、还没选输入" }
            return nil
        case .setFTBDuration(let ticks):
            return ticks < 0 ? "FTB 时长不能为负：\(ticks)" : nil
        case .overlay(let channel, _, let input):
            if let r = overlayChannel(channel) { return r }
            if let input, s.input(input) == nil { return "输入 \(input) 不存在" }
            return nil
        case .setOverlay(let channel, _, _), .setOverlayDecoration(let channel, _, _, _):
            return overlayChannel(channel)
        case .audioGain(let input, _), .mute(let input, _), .setInputSettings(let input, _), .renameInput(let input, _),
             .removeInput(let input), .setInputSource(let input, _), .setInputAudio(let input, _, _, _), .setInputColor(let input, _):
            return s.input(input) == nil ? "输入 \(input) 不存在" : nil
        case .setPlayback(let input, _):
            return fileInputReference(input, in: s)
        case .seekPlayback(let input, let seconds):
            // 提案 021：只对文件输入；秒数负 / 非有限入口就拒
            if let r = fileInputReference(input, in: s) { return r }
            return seconds.isFinite && seconds >= 0 ? nil : "定位秒数必须是 ≥ 0 的有限数：\(seconds)"
        case .busGain(let bus, _), .busMute(let bus, _), .setBusEffects(let bus, _):
            return s.audio.buses.contains { $0.bus == bus } ? nil : "总线 \(bus) 不存在"
        case .setMonitorMode, .setMonitorSource:
            // 提案 026：四条总线都合法（headphones = 听耳机总线自己，P5-3 起；P5 时入口拒）
            return nil
        case .startRecord(let output), .stopRecord(let output):
            return outputReference(output, kind: .record, name: "录制", in: s)
        case .startStream(let output), .stopStream(let output):
            return outputReference(output, kind: .stream, name: "推流", in: s)
        case .addInput(let config):
            if config.number <= MixerState.noInput { return "输入编号必须 ≥ 1：\(config.number)" }
            if s.input(config.number) != nil { return "输入 \(config.number) 已存在" }
            return nil
        case .addOutput(let config):
            if config.number <= 0 { return "输出编号必须 ≥ 1：\(config.number)" }
            if s.output(config.number) != nil { return "输出 \(config.number) 已存在" }
            return nil
        case .removeOutput(let output), .setOutputSettings(let output, _), .renameOutput(let output, _):
            return s.output(output) == nil ? "输出 \(output) 不存在" : nil
        case .setOutputEnabled(let output, _):
            guard let o = s.output(output) else { return "输出 \(output) 不存在" }
            switch o.kind {
            case .record: return "输出 \(output)「\(o.name)」是录制输出，起停走 startRecord / stopRecord"
            case .stream: return "输出 \(output)「\(o.name)」是推流输出，起停走 startStream / stopStream"
            default: return nil
            }
        case .loadShow(let show):
            // 先搬迁再 validate（提案 020）：020 之前的节目没有 slots，裸状态 validate 不过；reducer 也是先搬迁，两边判得一致
            do { try show.migratingLegacyKeys().makeState().validate() } catch { return "节目文件不合法：\(error)" }
            return nil
        }
    }

    private static func fileInputReference(_ number: Int, in s: MixerState) -> String? {
        guard let input = s.input(number) else { return "输入 \(number) 不存在" }
        return input.kind == .file ? nil : "输入 \(number)「\(input.name)」不是文件输入（\(input.kind)）"
    }

    private static func inputReference(_ number: Int, in s: MixerState) -> String? {
        if number == MixerState.noInput { return nil }
        if number < 0 { return "输入编号不能为负：\(number)" }
        return s.input(number) == nil ? "输入 \(number) 不存在" : nil
    }

    private static func overlayChannel(_ channel: Int) -> String? {
        (1...MixerState.overlayCount).contains(channel) ? nil : "叠加通道必须是 1…\(MixerState.overlayCount)：\(channel)"
    }

    private static func outputReference(_ number: Int, kind: OutputKind, name: String, in s: MixerState) -> String? {
        guard let o = s.output(number) else { return "输出 \(number) 不存在" }
        return o.kind == kind ? nil : "输出 \(number)「\(o.name)」是 \(o.kind)，不是\(name)输出"
    }
}
