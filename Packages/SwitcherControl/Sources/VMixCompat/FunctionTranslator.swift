import Foundation
import SwitcherContracts

/// 一个函数调用翻译出来的计划：按顺序逐条走总线的命令。
public struct FunctionPlan: Hashable, Sendable {
    /// 规范写法的函数名（应答里回显）。
    public var name: String
    public var commands: [Command]
    public init(name: String, commands: [Command]) {
        self.name = name
        self.commands = commands
    }
}

/// 函数名 → 内部 Command 的映射表（纯函数，只看当前状态）。只做 Companion 的模块用到的子集；
/// 上游有但这里没做的抛 `.notImplemented`，完全不认识的抛 `.unknownFunction`，参数问题抛 `.badParameter` 等。
public enum FunctionTranslator {
    public static func plan(_ request: FunctionRequest, state: MixerState, frameRate: FrameRate,
                            configuration: VMixCompatConfiguration) throws(CompatError) -> FunctionPlan {
        let ctx = Context(request: request, state: state, frameRate: frameRate, configuration: configuration)
        let n = request.name.lowercased()

        // ---- 切换 ----
        switch n {
        case "cut":
            var commands: [Command] = []
            if let input = try ctx.optionalInput() { commands.append(.setPreview(input: input)) }
            commands.append(.cut)
            return FunctionPlan(name: "Cut", commands: commands)
        case "fade", "wipe", "zoom":
            let type: TransitionType = n == "fade" ? .fade : (n == "wipe" ? .wipe : .zoom)
            let ticks = try ctx.durationTicks(default: 500)
            var commands: [Command] = []
            if let input = try ctx.optionalInput() { commands.append(.setPreview(input: input)) }
            if type == .fade {
                commands.append(.fade(durationTicks: ticks))
            } else {
                commands.append(.setTransition(type: type, durationTicks: ticks))
                commands.append(.autoTransition)
            }
            return FunctionPlan(name: n.capitalized, commands: commands)
        case "stinger1":
            guard state.transition.stinger.input != nil else {
                throw CompatError(code: .notConfigured, message: "Stinger1: no stinger input is configured")
            }
            return FunctionPlan(name: "Stinger1", commands: [.setTransition(type: .stinger, durationTicks: state.transition.durationTicks), .autoTransition])
        case "transition1":
            return FunctionPlan(name: "Transition1", commands: [.autoTransition])
        case "settransitioneffect1":
            let value = try ctx.required("Value")
            guard let type = Self.transitionType(named: value) else {
                if FunctionCatalog.upstreamTransitionEffects.contains(where: { $0.lowercased() == value.lowercased() }) {
                    throw CompatError(code: .notImplemented, message: "SetTransitionEffect1: transition effect \(value) is not implemented (Cut, Fade, Wipe, Zoom, Stinger)")
                }
                throw CompatError(code: .badParameter, message: "SetTransitionEffect1: unknown effect \(value) (Cut, Fade, Wipe, Zoom, Stinger)")
            }
            return FunctionPlan(name: "SetTransitionEffect1", commands: [.setTransition(type: type, durationTicks: state.transition.durationTicks)])
        case "settransitionduration1":
            let ticks = try ctx.durationTicks(parameter: "Value")
            return FunctionPlan(name: "SetTransitionDuration1", commands: [.setTransition(type: state.transition.type, durationTicks: ticks)])
        case "setfader":
            let v = try ctx.double("Value", range: 0...255)
            return FunctionPlan(name: "SetFader", commands: [.tbar(progress: v / 255)])

        // ---- PVW / PGM ----
        case "previewinput", "setpreviewinput":
            return FunctionPlan(name: n == "previewinput" ? "PreviewInput" : "SetPreviewInput", commands: [.setPreview(input: try ctx.input())])
        case "activeinput", "cutdirect":
            return FunctionPlan(name: n == "activeinput" ? "ActiveInput" : "CutDirect", commands: [.setProgram(input: try ctx.input())])
        case "previewinputnext", "previewinputprevious":
            let numbers = state.inputs.map(\.number).sorted()
            guard !numbers.isEmpty else { throw CompatError(code: .notConfigured, message: "\(request.name): there are no inputs") }
            let index = numbers.firstIndex(of: state.preview) ?? -1
            let next = n == "previewinputnext" ? (index + 1) % numbers.count : (index <= 0 ? numbers.count - 1 : index - 1)
            return FunctionPlan(name: n == "previewinputnext" ? "PreviewInputNext" : "PreviewInputPrevious", commands: [.setPreview(input: numbers[next])])
        case "setinputname":
            let input = try ctx.input()
            let value = try ctx.required("Value")
            return FunctionPlan(name: "SetInputName", commands: [.renameInput(input: input, name: value)])

        // ---- 输出 ----
        case "startrecording", "stoprecording", "startstoprecording":
            let output = try ctx.recordOutput()
            let start: Bool
            switch n {
            case "startrecording": start = true
            case "stoprecording": start = false
            default: start = !output.enabled
            }
            return FunctionPlan(name: n == "startrecording" ? "StartRecording" : (n == "stoprecording" ? "StopRecording" : "StartStopRecording"),
                                commands: [start ? .startRecord(output: output.number) : .stopRecord(output: output.number)])
        case "startstreaming", "stopstreaming", "startstopstreaming":
            let output = try ctx.streamOutput()
            let start: Bool
            switch n {
            case "startstreaming": start = true
            case "stopstreaming": start = false
            default: start = !output.enabled
            }
            return FunctionPlan(name: n == "startstreaming" ? "StartStreaming" : (n == "stopstreaming" ? "StopStreaming" : "StartStopStreaming"),
                                commands: [start ? .startStream(output: output.number) : .stopStream(output: output.number)])
        case "fadetoblack":
            return FunctionPlan(name: "FadeToBlack", commands: [.ftb(on: !state.ftb.on)])

        // ---- 音频：总线 ----
        case "setmastervolume", "setbusavolume", "setbusbvolume", "setheadphonesvolume":
            let bus: Bus = n == "setmastervolume" ? .master : (n == "setbusavolume" ? .busA : (n == "setbusbvolume" ? .busB : .headphones))
            let fader = try ctx.double("Value", range: 0...100)
            let name = n == "setmastervolume" ? "SetMasterVolume" : (n == "setbusavolume" ? "SetBusAVolume" : (n == "setbusbvolume" ? "SetBusBVolume" : "SetHeadphonesVolume"))
            return FunctionPlan(name: name, commands: [.busGain(bus: bus, dB: VolumeScale.dB(fromFader: fader))])
        case "masteraudio", "masteraudioon", "masteraudiooff":
            return FunctionPlan(name: n == "masteraudio" ? "MasterAudio" : (n == "masteraudioon" ? "MasterAudioOn" : "MasterAudioOff"),
                                commands: [ctx.busMute(.master, mode: Self.toggleMode(suffixOf: n))])
        case "busaaudio", "busaaudioon", "busaaudiooff", "busbaudio", "busbaudioon", "busbaudiooff":
            let bus: Bus = n.hasPrefix("busa") ? .busA : .busB
            let base = bus == .busA ? "BusAAudio" : "BusBAudio"
            let mode = Self.toggleMode(suffixOf: n)
            return FunctionPlan(name: base + mode.suffix, commands: [ctx.busMute(bus, mode: mode)])
        case "busxaudio", "busxaudioon", "busxaudiooff":
            let bus = try ctx.busFromValue()
            let mode = Self.toggleMode(suffixOf: n)
            return FunctionPlan(name: "BusXAudio" + mode.suffix, commands: [ctx.busMute(bus, mode: mode)])

        // ---- 音频：输入 ----
        case "setvolume":
            let input = try ctx.input()
            let fader = try ctx.double("Value", range: 0...100)
            return FunctionPlan(name: "SetVolume", commands: [.audioGain(input: input, dB: VolumeScale.dB(fromFader: fader))])
        case "audio", "audioon", "audiooff":
            let input = try ctx.input()
            let muted = state.input(input)!.settings.audio.muted
            let mode = Self.toggleMode(suffixOf: n)
            let on: Bool = mode == .toggle ? !muted : (mode == .on ? false : true)
            return FunctionPlan(name: "Audio" + mode.suffix, commands: [.mute(input: input, on: on)])
        case "audiobus", "audiobuson", "audiobusoff":
            let input = try ctx.input()
            let value = try ctx.required("Value").uppercased()
            var settings = state.input(input)!.settings
            let mode = Self.toggleMode(suffixOf: n)
            func set(_ current: Bool) -> Bool { mode == .toggle ? !current : mode == .on }
            switch value {
            case "M": settings.audio.routing.master = set(settings.audio.routing.master)
            case "A": settings.audio.routing.busA = set(settings.audio.routing.busA)
            case "B": settings.audio.routing.busB = set(settings.audio.routing.busB)
            default: throw CompatError(code: .badParameter, message: "\(request.name): Value must be M, A or B (got \(value))")
            }
            return FunctionPlan(name: "AudioBus" + mode.suffix, commands: [.setInputSettings(input: input, settings: settings)])
        case "solo", "soloon", "solooff":
            let input = try ctx.input()
            var settings = state.input(input)!.settings
            let mode = Self.toggleMode(suffixOf: n)
            settings.audio.solo = mode == .toggle ? !settings.audio.solo : mode == .on
            return FunctionPlan(name: "Solo" + mode.suffix, commands: [.setInputSettings(input: input, settings: settings)])
        case "setbalance":
            let input = try ctx.input()
            let pan = try ctx.double("Value", range: -1...1)
            var settings = state.input(input)!.settings
            settings.audio.pan = pan
            return FunctionPlan(name: "SetBalance", commands: [.setInputSettings(input: input, settings: settings)])
        default:
            break
        }

        // ---- 叠加：OverlayInput<N>[In|Out|Off|Last|Zoom]、OverlayInputAllOff、PreviewOverlayInput<N> ----
        if n == "overlayinputalloff" {
            let commands = state.overlays.enumerated().filter { $0.element.on }.map { Command.overlay(channel: $0.offset + 1, on: false, input: nil) }
            return FunctionPlan(name: "OverlayInputAllOff", commands: commands)
        }
        if n.hasPrefix("previewoverlayinput") {
            throw CompatError(code: .notImplemented, message: "\(request.name): overlays have no preview state here")
        }
        if n.hasPrefix("overlayinput"), let (channel, suffix) = Self.overlayParts(n) {
            return try ctx.overlay(channel: channel, suffix: suffix)
        }

        if FunctionCatalog.isKnownUpstream(request.name) {
            throw CompatError(code: .notImplemented, message: "\(request.name) is an upstream function this compatibility layer does not implement")
        }
        throw CompatError(code: .unknownFunction, message: "unknown function \(request.name)")
    }

    // MARK: 辅助

    enum ToggleMode {
        case toggle, on, off
        var suffix: String {
            switch self {
            case .toggle: ""
            case .on: "On"
            case .off: "Off"
            }
        }
    }

    static func toggleMode(suffixOf lowered: String) -> ToggleMode {
        if lowered.hasSuffix("off") { return .off }
        if lowered.hasSuffix("on") { return .on }
        return .toggle
    }

    static func transitionType(named value: String) -> TransitionType? {
        switch value.lowercased() {
        case "cut": .cut
        case "fade": .fade
        case "wipe": .wipe
        case "zoom": .zoom
        case "stinger", "stinger1": .stinger
        default: nil
        }
    }

    /// "overlayinput3off" → (3, "off")；数字后面的后缀可以为空。数字不合法给 nil（交给上层判 unknown / notImplemented）。
    static func overlayParts(_ lowered: String) -> (Int, String)? {
        let rest = lowered.dropFirst("overlayinput".count)
        let digits = rest.prefix { $0.isNumber }
        guard let channel = Int(digits) else { return nil }
        return (channel, String(rest.dropFirst(digits.count)))
    }

    /// 一次翻译的上下文：参数取值与校验。
    struct Context {
        let request: FunctionRequest
        let state: MixerState
        let frameRate: FrameRate
        let configuration: VMixCompatConfiguration

        func required(_ key: String) throws(CompatError) -> String {
            guard let v = request.parameter(key), !v.isEmpty else {
                throw CompatError(code: .badParameter, message: "\(request.name): missing parameter \(key)")
            }
            return v
        }

        func double(_ key: String, range: ClosedRange<Double>) throws(CompatError) -> Double {
            let text = try required(key)
            guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite else {
                throw CompatError(code: .badParameter, message: "\(request.name): \(key) must be a number (got \(text))")
            }
            guard range.contains(v) else {
                throw CompatError(code: .badParameter, message: "\(request.name): \(key) must be within \(VolumeScale.format(range.lowerBound))…\(VolumeScale.format(range.upperBound)) (got \(text))")
            }
            return v
        }

        /// Input 参数（必填）。
        func input() throws(CompatError) -> Int {
            guard let n = try optionalInput() else { throw CompatError(code: .badParameter, message: "\(request.name): missing parameter Input") }
            return n
        }

        /// Input 参数（可选）。
        func optionalInput() throws(CompatError) -> Int? {
            guard let text = request.parameter("Input"), !text.isEmpty else { return nil }
            return try InputReference.resolve(text, in: state)
        }

        /// 毫秒 → 拍（四舍五入）。
        func durationTicks(parameter key: String = "Duration", default defaultMs: Double? = nil) throws(CompatError) -> Int {
            let ms: Double
            if let text = request.parameter(key), !text.isEmpty {
                guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite, v >= 0 else {
                    throw CompatError(code: .badParameter, message: "\(request.name): \(key) must be a non-negative number of milliseconds (got \(text))")
                }
                ms = v
            } else if let defaultMs {
                ms = defaultMs
            } else {
                throw CompatError(code: .badParameter, message: "\(request.name): missing parameter \(key)")
            }
            return Int((ms / 1000 * frameRate.framesPerSecond.doubleValue).rounded())
        }

        func recordOutput() throws(CompatError) -> OutputState {
            if let n = configuration.recordOutput {
                guard let o = state.output(n), o.kind == .record else {
                    throw CompatError(code: .outputNotFound, message: "\(request.name): configured record output \(n) does not exist or is not a record output")
                }
                return o
            }
            guard let first = state.outputs.filter({ $0.kind == .record }).min(by: { $0.number < $1.number }) else {
                throw CompatError(code: .notConfigured, message: "\(request.name): no record output is configured")
            }
            return first
        }

        func streamOutput() throws(CompatError) -> OutputState {
            let streams = state.outputs.filter { $0.kind == .stream }.sorted { $0.number < $1.number }
            if let text = request.parameter("Value"), !text.isEmpty {
                guard let k = Int(text.trimmingCharacters(in: .whitespaces)), k >= 0 else {
                    throw CompatError(code: .badParameter, message: "\(request.name): Value must be the stream index from 0 (got \(text))")
                }
                guard k < streams.count else {
                    throw CompatError(code: .outputNotFound, message: "\(request.name): there is no stream output with index \(k) (have \(streams.count))")
                }
                return streams[k]
            }
            if let n = configuration.streamOutput {
                guard let o = state.output(n), o.kind == .stream else {
                    throw CompatError(code: .outputNotFound, message: "\(request.name): configured stream output \(n) does not exist or is not a stream output")
                }
                return o
            }
            guard let first = streams.first else {
                throw CompatError(code: .notConfigured, message: "\(request.name): no stream output is configured")
            }
            return first
        }

        func busFromValue() throws(CompatError) -> Bus {
            let v = try required("Value").uppercased()
            switch v {
            case "A", "BUSA": return .busA
            case "B", "BUSB": return .busB
            case "MASTER", "M": return .master
            default: throw CompatError(code: .badParameter, message: "\(request.name): Value must be A or B (got \(v))")
            }
        }

        func busMute(_ bus: Bus, mode: ToggleMode) -> Command {
            let muted = state.audio.buses.first { $0.bus == bus }?.muted ?? false
            let on: Bool = mode == .toggle ? !muted : (mode == .on ? false : true)
            return .busMute(bus: bus, on: on)
        }

        /// OverlayInput<N>[后缀]。
        func overlay(channel: Int, suffix: String) throws(CompatError) -> FunctionPlan {
            guard (1...MixerState.overlayCount).contains(channel) else {
                throw CompatError(code: .badParameter, message: "\(request.name): overlay channel must be 1…\(MixerState.overlayCount)")
            }
            let current = state.overlays[channel - 1]
            let base = "OverlayInput\(channel)"
            let given = try optionalInput()
            switch suffix {
            case "":
                // 开关：给了 Input 且同一路已开着 → 关；否则开（并换成给的输入）
                if let given {
                    if current.on && current.input == given {
                        return FunctionPlan(name: base, commands: [.overlay(channel: channel, on: false, input: nil)])
                    }
                    return FunctionPlan(name: base, commands: [.overlay(channel: channel, on: true, input: given)])
                }
                guard current.input != nil else {
                    throw CompatError(code: .notConfigured, message: "\(base): overlay \(channel) has no input; pass Input=")
                }
                return FunctionPlan(name: base, commands: [.overlay(channel: channel, on: !current.on, input: nil)])
            case "last":
                guard current.input != nil else {
                    throw CompatError(code: .notConfigured, message: "\(base)Last: overlay \(channel) has no last input")
                }
                return FunctionPlan(name: base + "Last", commands: [.overlay(channel: channel, on: !current.on, input: nil)])
            case "in":
                if given == nil && current.input == nil {
                    throw CompatError(code: .notConfigured, message: "\(base)In: overlay \(channel) has no input; pass Input=")
                }
                return FunctionPlan(name: base + "In", commands: [.overlay(channel: channel, on: true, input: given)])
            case "out":
                return FunctionPlan(name: base + "Out", commands: [.overlay(channel: channel, on: false, input: nil)])
            case "off":
                return FunctionPlan(name: base + "Off", commands: [.overlay(channel: channel, on: false, input: nil)])
            case "zoom":
                throw CompatError(code: .notImplemented, message: "\(base)Zoom: zooming an overlay to fullscreen is not implemented")
            default:
                throw CompatError(code: .unknownFunction, message: "unknown function \(request.name)")
            }
        }
    }
}
