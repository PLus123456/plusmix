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
        case .cut, .autoTransition, .tbar, .ftb, .setAFV:
            return nil
        case .fade(let d):
            return d < 0 ? "转场时长不能为负：\(d)" : nil
        case .setTransition(_, let d):
            return d < 0 ? "转场时长不能为负：\(d)" : nil
        case .setPreview(let input), .setProgram(let input):
            return inputReference(input, in: s)
        case .overlay(let channel, _, let input):
            if let r = overlayChannel(channel) { return r }
            if let input, s.input(input) == nil { return "输入 \(input) 不存在" }
            return nil
        case .setOverlay(let channel, _, _):
            return overlayChannel(channel)
        case .audioGain(let input, _), .mute(let input, _), .setInputSettings(let input, _), .renameInput(let input, _), .removeInput(let input):
            return s.input(input) == nil ? "输入 \(input) 不存在" : nil
        case .busGain(let bus, _), .busMute(let bus, _):
            return s.audio.buses.contains { $0.bus == bus } ? nil : "总线 \(bus) 不存在"
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
        case .removeOutput(let output), .setOutputSettings(let output, _):
            return s.output(output) == nil ? "输出 \(output) 不存在" : nil
        case .loadShow(let show):
            do { try show.makeState().validate() } catch { return "节目文件不合法：\(error)" }
            return nil
        }
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
