import SwitcherContracts

// 结构性校验：reducer（W1-B）对非法命令是"原样返回、不出声"（契约 MixerReducing 的约定），API 用户会以为成功了。
// 总线在入口按同一套规则先查一遍，给出理由（HTTP 400）。只查"看一眼状态就能判定、且不随拍变化"的条件：
// 引用的输入 / 输出是否存在、输出 kind 是否匹配、叠加通道范围、负时长、编号重复、节目文件不变量、文件速率 / 定位秒数的边界（提案 031：`FileSource.rateRange` /
// `PlaybackLimits.maxSeekSeconds`，与 `MixerState.validate()`、reducer、FileInput 的钳位同一组常量）、addInput 的编号范围（提案 032：`InputConfig.numberRange`，
// 与 `MixerState.validate()`、reducer 同一个常量；按编号取输入的命令遇到越界编号照旧"不存在"——越界的编号进不了状态）、
// 提案 034 的数值边界（时长 `DurationLimits.tickRange`、来源的帧率 / 尺寸 `InputSource.rangeError`、loadShow 的结构检查与"运行中不能换格式"）；`overlay(input: 0)` = 清空，放行。
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
        case .fade(let d), .setTransition(_, let d):
            // 提案 034 ④：负数与超上限同一句（原来只拒负数"转场时长不能为负"，Int.max 进了状态、FTB 反转在 reducer 上崩）
            return durationReason(d)
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
            // 提案 034 ④：超上限拒（负数照旧由 reducer 钳 0，不拒）
            return config.durationTicks > DurationLimits.maxTicks ? durationReason(config.durationTicks) : nil
        case .useTransitionSlot(let slot, let start):
            guard TransitionSlot.indexRange.contains(slot) else { return "转场槽必须是 1…\(TransitionSlot.count)：\(slot)" }
            // 提案 029：没选输入的 Stinger 槽不执行（只选中照常）；槽的配置只随命令变，入口就拒（reducer 同判）
            if start, slot - 1 < s.transition.slots.count, s.transition.slots[slot - 1].isStingerWithoutInput { return "转场 \(slot) 是 Stinger、还没选输入" }
            return nil
        case .setFTBDuration(let ticks):
            return durationReason(ticks)   // 034 ④：原来只拒负数"FTB 时长不能为负"
        case .overlay(let channel, _, let input):
            if let r = overlayChannel(channel) { return r }
            // 提案 034 ⑤：0 = 清空这一路的输入（叠加设置的"（无）"）；nil = 不换；负数 / 不存在的照旧拒
            if let input, input != MixerState.noInput, s.input(input) == nil { return "输入 \(input) 不存在" }
            return nil
        case .setOverlay(let channel, _, let animation):
            if let r = overlayChannel(channel) { return r }
            // 提案 034 ④：超上限拒（负数照旧由 reducer 钳 0，不拒）
            return animation.durationTicks > DurationLimits.maxTicks ? durationReason(animation.durationTicks) : nil
        case .setOverlayDecoration(let channel, _, _, _):
            return overlayChannel(channel)
        case .audioGain(let input, _), .mute(let input, _), .setInputSettings(let input, _), .renameInput(let input, _),
             .removeInput(let input), .setInputAudio(let input, _, _, _), .setInputColor(let input, _):
            return s.input(input) == nil ? "输入 \(input) 不存在" : nil
        case .setInputSource(let input, let source):
            if s.input(input) == nil { return "输入 \(input) 不存在" }
            return sourceReason(source, input: input)
        case .setPlayback(let input, _):
            return fileInputReference(input, in: s)
        case .seekPlayback(let input, let seconds):
            // 提案 021：只对文件输入；提案 031：秒数负 / 非有限 / 超过一周入口就拒（原来只查有限非负，1e300 在 FileInput 的 Int64 换算上崩进程）
            if let r = fileInputReference(input, in: s) { return r }
            return (0...PlaybackLimits.maxSeekSeconds).contains(seconds) ? nil : "定位秒数必须在 0–\(maxSeekText) 之间（一周）：\(seconds)"
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
            // 提案 032：编号不在 1…16 入口就拒（原来只查 ≥ 1：2^62 号进了状态，兼容层按编号分配的 TALLY / XML 崩或卡）
            if !InputConfig.numberRange.contains(config.number) { return "输入编号必须在 \(inputNumberRangeText) 之间：\(config.number)" }
            if s.input(config.number) != nil { return "输入 \(config.number) 已存在" }
            return sourceReason(config.source, input: config.number)
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
            // 先搬迁再 validate（提案 020）：020 之前的节目没有 slots，裸状态 validate 不过；reducer 也是先搬迁，两边判得一致。
            // 034 ③：结构检查在 makeState 之前（makeValidatedState）——叠加不是 4 个原来在 MixerState.init 的 precondition 上把进程弄崩；
            // ⑥：格式与当前不同拒（引擎时钟 / 渲染器 / App 的 session 在构造时定死，loadShow 只会换掉状态）
            let loaded: MixerState
            do { loaded = try show.migratingLegacyKeys().makeValidatedState() } catch { return "节目文件不合法：\(invariantText(error))" }
            guard loaded.format == s.format else {
                return "节目格式不同（\(formatText(s.format)) → \(formatText(loaded.format))）：运行中不能换格式，用打开节目 / 重启 headless"
            }
            return nil
        }
    }

    /// 来源里的数值越界 → 理由（判定是契约的 `InputSource.rangeError`，与 `MixerState.validate()` / reducer 同一个函数）：文件速率（031）、屏幕 / 合成源帧率、合成源宽高（034）。
    private static func sourceReason(_ source: InputSource, input number: Int) -> String? {
        guard let error = source.rangeError(input: number) else { return nil }
        switch (error, source) {
        case (.fileRate(_, let rate), _): return "播放速率必须在 \(fileRateRangeText) 之间：\(rate)"
        case (.inputFrameRate, .screen(_, let rate?, _)): return "帧率必须在 \(frameRateRangeText) 之间：\(rate)"
        case (.inputFrameRate, .synthetic(let settings)): return "帧率必须在 \(frameRateRangeText) 之间：\(settings.frameRate)"
        case (.inputSize, .synthetic(let settings)): return "画面尺寸必须在 \(sizeRangeText) 之间：\(settings.width)×\(settings.height)"
        default: return "输入来源不合法：\(error)"
        }
    }

    /// 时长（拍）不在 `DurationLimits.tickRange` → 理由（提案 034 ④；fade / setTransition / setFTBDuration 的负数也走这一句）。
    private static func durationReason(_ ticks: Int) -> String? {
        DurationLimits.tickRange.contains(ticks) ? nil : "时长必须在 \(durationRangeText) 拍之间：\(ticks)"
    }

    /// loadShow 不过时的说明：034 新加的几种给人话（与 addInput / fade 那几句同一组文字），别的不变量照旧打枚举。
    private static func invariantText(_ error: any Error) -> String {
        switch error as? MixerStateError {
        case .format(let f)?:
            guard FrameRate.programRange.contains(f.frameRate.framesPerSecond) else { return "帧率必须在 \(frameRateRangeText) 之间：\(f.frameRate)" }
            return "节目尺寸必须在 \(sizeRangeText) 之间：\(f.width)×\(f.height)"
        case .durationTicks(let ticks)?: return "时长必须在 \(durationRangeText) 拍之间：\(ticks)"
        case .inputFrameRate(let n)?: return "输入 \(n) 的帧率必须在 \(frameRateRangeText) 之间"
        case .inputSize(let n)?: return "输入 \(n) 的画面尺寸必须在 \(sizeRangeText) 之间"
        case .alignmentFrames(let frames)?: return "音频对齐帧数必须在 \(alignmentRangeText) 之间：\(frames)"
        default: return "\(error)"
        }
    }

    /// "1920×1080@60" / "1920×1080@59.94"。
    private static func formatText(_ f: ProgramFormat) -> String { "\(f.width)×\(f.height)@\(f.frameRate)" }

    /// 031 两个常量的文字（理由与命令目录共用）："0.1–8" / "604800"。
    static let fileRateRangeText = "\(plain(FileSource.rateRange.lowerBound))–\(plain(FileSource.rateRange.upperBound))"
    static let maxSeekText = plain(PlaybackLimits.maxSeekSeconds)
    /// 032 的输入编号范围的文字（理由与命令目录共用）："1–16"。
    static let inputNumberRangeText = "\(InputConfig.numberRange.lowerBound)–\(InputConfig.numberRange.upperBound)"
    /// 034 的几个范围的文字（理由与命令目录共用）："0–864000"（拍）/ "1–240"（fps）/ "16–8192"（像素）/ "0–24000"（48 kHz 帧）。
    static let durationRangeText = "\(DurationLimits.tickRange.lowerBound)–\(DurationLimits.tickRange.upperBound)"
    static let frameRateRangeText = "\(FrameRate.programRange.lowerBound)–\(FrameRate.programRange.upperBound)"
    static let sizeRangeText = "\(ProgramFormat.sizeRange.lowerBound)–\(ProgramFormat.sizeRange.upperBound)"
    static let alignmentRangeText = "\(AudioState.alignmentRange.lowerBound)–\(AudioState.alignmentRange.upperBound)"
    private static func plain(_ x: Double) -> String { x == x.rounded() && abs(x) < 1e15 ? String(Int64(x)) : String(x) }

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
