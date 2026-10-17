import Foundation
import SwitcherContracts

/// ACTS（激活器）：`ACTS <名字> [输入号]` 的查询值，以及前后两个状态的差推出的事件。
/// 值永远是 0 / 1 或 0–1 的浮点（上游约定：布尔变 1/0，音量变幅度）。
/// 名字集合 = Companion 模块的激活器处理表里与本产品有对应的那些；别的报 UnknownActivator。
public enum Activators {
    /// 查询：返回 "ACTS OK " 后面的部分，例如 "Input 2 1"、"Recording 0"。
    public static func value(name rawName: String, input: Int?, state: MixerState) throws(CompatError) -> String {
        let name = canonical(rawName)
        switch name {
        case "Input", "InputPreview":
            let current = name == "Input" ? state.program : state.preview
            if let input {
                try requireInput(input, state)
                return "\(name) \(input) \(input == current ? 1 : 0)"
            }
            return "\(name) \(current) 1"
        case "Overlay1", "Overlay2", "Overlay3", "Overlay4":
            // 兼容层里不强制解包、不越界取（W2-C4 / D02 过了一遍）：名字是 canonical 过的四个之一，叠加恰好 4 个（validate 保证），这里仍按失败即返回写
            guard let channel = Int(name.dropFirst("Overlay".count)), state.overlays.indices.contains(channel - 1) else {
                throw CompatError(code: .unknownActivator, message: "unknown activator \(rawName)")
            }
            let o = state.overlays[channel - 1]
            let visible = o.isVisible ? o.input : nil
            if let input {
                try requireInput(input, state)
                return "\(name) \(input) \(visible == input ? 1 : 0)"
            }
            return "\(name) \(visible ?? 0) \(visible == nil ? 0 : 1)"
        case "Recording":
            return "Recording \(bit(state.outputs.contains { $0.kind == .record && $0.enabled }))"
        case "Streaming":
            return "Streaming \(bit(state.outputs.contains { $0.kind == .stream && $0.enabled }))"
        case "External":
            return "External \(bit(state.outputs.contains { $0.kind == .externalDisplay && $0.enabled }))"
        case "FadeToBlack":
            return "FadeToBlack \(bit(state.ftb.on))"
        case "MasterVolume", "MasterAudio", "MasterHeadphones", "BusAVolume", "BusAAudio", "BusBVolume", "BusBAudio":
            let bus: Bus = name.hasPrefix("BusA") ? .busA : (name.hasPrefix("BusB") ? .busB : (name == "MasterHeadphones" ? .headphones : .master))
            let b = state.audio.buses.first { $0.bus == bus }
            if name.hasSuffix("Audio") { return "\(name) \(bit(!(b?.muted ?? false)))" }
            return "\(name) \(VolumeScale.format(VolumeScale.amplitude(fromDb: b?.gainDb ?? 0), decimals: 4))"
        case "BusASolo", "BusBSolo", "BusCSolo", "BusDSolo", "BusESolo", "BusFSolo", "BusGSolo":
            return "\(name) 0"   // 没有总线独听
        case "InputAudio", "InputVolume", "InputSolo", "InputPlaying", "InputMasterAudio", "InputBusAAudio", "InputBusBAudio":
            guard let input else { throw CompatError(code: .badParameter, message: "ACTS \(name) needs an input number") }
            let a = try requireInput(input, state).settings.audio
            switch name {
            case "InputAudio": return "InputAudio \(input) \(bit(!a.muted))"
            case "InputVolume": return "InputVolume \(input) \(VolumeScale.format(VolumeScale.amplitude(fromDb: a.gainDb), decimals: 4))"
            case "InputSolo": return "InputSolo \(input) \(bit(a.solo))"
            case "InputPlaying": return "InputPlaying \(input) 1"
            case "InputMasterAudio": return "InputMasterAudio \(input) \(bit(a.routing.master))"
            case "InputBusAAudio": return "InputBusAAudio \(input) \(bit(a.routing.busA))"
            default: return "InputBusBAudio \(input) \(bit(a.routing.busB))"
            }
        default:
            throw CompatError(code: .unknownActivator, message: "unknown activator \(rawName)")
        }
    }

    /// 前后状态的差 → 事件（"ACTS OK " 后面的部分），顺序固定：PGM / PVW → 叠加 → 输出 / FTB → 每路输入音频 → 总线。
    public static func events(from old: MixerState, to new: MixerState) -> [String] {
        var out: [String] = []
        if old.program != new.program {
            if old.program != MixerState.noInput { out.append("Input \(old.program) 0") }
            if new.program != MixerState.noInput { out.append("Input \(new.program) 1") }
        }
        if old.preview != new.preview {
            if old.preview != MixerState.noInput { out.append("InputPreview \(old.preview) 0") }
            if new.preview != MixerState.noInput { out.append("InputPreview \(new.preview) 1") }
        }
        for i in 0..<min(old.overlays.count, new.overlays.count) {
            let a = old.overlays[i].isVisible ? old.overlays[i].input : nil
            let b = new.overlays[i].isVisible ? new.overlays[i].input : nil
            guard a != b else { continue }
            if let a { out.append("Overlay\(i + 1) \(a) 0") }
            if let b { out.append("Overlay\(i + 1) \(b) 1") }
        }
        let flags: [(String, (MixerState) -> Bool)] = [
            ("Recording", { $0.outputs.contains { $0.kind == .record && $0.enabled } }),
            ("Streaming", { $0.outputs.contains { $0.kind == .stream && $0.enabled } }),
            ("External", { $0.outputs.contains { $0.kind == .externalDisplay && $0.enabled } }),
            ("FadeToBlack", { $0.ftb.on }),
        ]
        for (name, f) in flags where f(old) != f(new) { out.append("\(name) \(bit(f(new)))") }
        for input in new.inputs.sorted(by: { $0.number < $1.number }) {
            guard let before = old.input(input.number) else { continue }
            let a = before.settings.audio, b = input.settings.audio
            if a.muted != b.muted { out.append("InputAudio \(input.number) \(bit(!b.muted))") }
            if a.gainDb != b.gainDb { out.append("InputVolume \(input.number) \(VolumeScale.format(VolumeScale.amplitude(fromDb: b.gainDb), decimals: 4))") }
            if a.solo != b.solo { out.append("InputSolo \(input.number) \(bit(b.solo))") }
            if a.routing.master != b.routing.master { out.append("InputMasterAudio \(input.number) \(bit(b.routing.master))") }
            if a.routing.busA != b.routing.busA { out.append("InputBusAAudio \(input.number) \(bit(b.routing.busA))") }
            if a.routing.busB != b.routing.busB { out.append("InputBusBAudio \(input.number) \(bit(b.routing.busB))") }
        }
        let busNames: [(Bus, String, String)] = [(.master, "MasterVolume", "MasterAudio"), (.busA, "BusAVolume", "BusAAudio"), (.busB, "BusBVolume", "BusBAudio")]
        for (bus, volumeName, audioName) in busNames {
            guard let a = old.audio.buses.first(where: { $0.bus == bus }), let b = new.audio.buses.first(where: { $0.bus == bus }) else { continue }
            if a.gainDb != b.gainDb { out.append("\(volumeName) \(VolumeScale.format(VolumeScale.amplitude(fromDb: b.gainDb), decimals: 4))") }
            if a.muted != b.muted { out.append("\(audioName) \(bit(!b.muted))") }
        }
        if let a = old.audio.buses.first(where: { $0.bus == .headphones }), let b = new.audio.buses.first(where: { $0.bus == .headphones }), a.gainDb != b.gainDb {
            out.append("MasterHeadphones \(VolumeScale.format(VolumeScale.amplitude(fromDb: b.gainDb), decimals: 4))")
        }
        return out
    }

    static let knownNames = [
        "Input", "InputPreview", "Overlay1", "Overlay2", "Overlay3", "Overlay4", "Recording", "Streaming", "External", "FadeToBlack",
        "MasterVolume", "MasterAudio", "MasterHeadphones", "BusAVolume", "BusAAudio", "BusBVolume", "BusBAudio",
        "BusASolo", "BusBSolo", "BusCSolo", "BusDSolo", "BusESolo", "BusFSolo", "BusGSolo",
        "InputAudio", "InputVolume", "InputSolo", "InputPlaying", "InputMasterAudio", "InputBusAAudio", "InputBusBAudio",
    ]

    /// 不分大小写地对到规范写法；不认识原样返回。
    static func canonical(_ name: String) -> String {
        knownNames.first { $0.lowercased() == name.lowercased() } ?? name
    }

    /// 这一路的配置；不在抛 inputNotFound。
    @discardableResult
    static func requireInput(_ number: Int, _ state: MixerState) throws(CompatError) -> InputConfig {
        guard let config = state.input(number) else { throw CompatError(code: .inputNotFound, message: "input \(number) does not exist") }
        return config
    }

    static func bit(_ b: Bool) -> String { b ? "1" : "0" }
}
