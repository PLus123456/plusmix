import Foundation
import SwitcherContracts

/// XML 状态文档。节点集合按 Companion 模块解析代码的硬性要求来（少一个它就崩）：
/// version、edition、inputs、overlays、preview、active、fadeToBlack、transitions、recording、external、streaming、playList、multiCorder、fullscreen、audio。
/// 根元素名是上游协议规定的（客户端按它识别文档，没法改）。
public enum StatusXML {
    /// 根元素名（上游协议规定；docs/contract-changes/011 记录了这个字面量存在的原因，lint 只放行带标记的这一行）。
    public static let rootElement = "vmix"   // lint:allow-protocol-literal

    /// 生成文档。表读数来自 Stats（铁律 4：兼容层不另算），没有就写 0。
    public static func document(state: MixerState, frameRate: FrameRate, stats: Stats?, configuration: VMixCompatConfiguration) -> String {
        var out = ""
        out.reserveCapacity(2048 + state.inputs.count * 320)
        out += "<\(rootElement)>\n"
        out += "<version>\(escape(configuration.reportedVersion))</version>\n"
        out += "<edition>\(escape(configuration.edition))</edition>\n"

        // 输入：位置 = 编号（Companion 用 inputs[number − 1] 找输入），缺的编号补 Blank 占位
        out += "<inputs>\n"
        let byNumber = Dictionary(uniqueKeysWithValues: state.inputs.map { ($0.number, $0) })
        let maxNumber = state.inputs.map(\.number).max() ?? 0
        if maxNumber >= 1 {
            for number in 1...maxNumber {
                if let input = byNumber[number] {
                    out += inputElement(input, meter: stats?.audio.meters.inputs[number]?.peakDb)
                } else {
                    out += "<input key=\"\(InputReference.key(forInput: number))\" number=\"\(number)\" type=\"Blank\" title=\"\" shortTitle=\"\" state=\"Paused\" position=\"0\" duration=\"0\" loop=\"False\" muted=\"True\" volume=\"0\" balance=\"0\" solo=\"False\" audiobusses=\"\" meterF1=\"0\" meterF2=\"0\"></input>\n"
                }
            }
        }
        out += "</inputs>\n"

        // 叠加通道：可见（开着或退出动画未完）的写输入编号
        out += "<overlays>\n"
        for (i, o) in state.overlays.enumerated() {
            if o.isVisible, let input = o.input {
                out += "<overlay number=\"\(i + 1)\">\(input)</overlay>\n"
            } else {
                out += "<overlay number=\"\(i + 1)\" />\n"
            }
        }
        out += "</overlays>\n"

        out += "<preview>\(state.preview)</preview>\n"
        out += "<active>\(state.program)</active>\n"
        out += "<fadeToBlack>\(bool(state.ftb.on))</fadeToBlack>\n"
        // 转场槽 1–4 各一项（W5-M：Transition1–4 / SetTransitionEffect1–4 按槽号对应）；万一没有槽（没经搬迁的裸状态）只写当前那组
        out += "<transitions>\n"
        let slots = state.transition.slots.isEmpty ? [state.transition.currentGroup] : state.transition.slots
        for (i, slot) in slots.enumerated() {
            let ms = Int((Double(slot.durationTicks) * 1000 / frameRate.framesPerSecond.doubleValue).rounded())
            out += "<transition number=\"\(i + 1)\" effect=\"\(effectName(slot.type))\" duration=\"\(ms)\" />\n"
        }
        out += "</transitions>\n"

        let records = state.outputs.filter { $0.kind == .record }
        let streams = state.outputs.filter { $0.kind == .stream }.sorted { $0.number < $1.number }
        let externals = state.outputs.filter { $0.kind == .externalDisplay }
        out += "<recording>\(bool(records.contains { $0.enabled }))</recording>\n"
        out += "<external>\(bool(externals.contains { $0.enabled }))</external>\n"
        if streams.isEmpty {
            out += "<streaming>False</streaming>\n"
        } else {
            let attrs = streams.enumerated().map { " channel\($0.offset + 1)=\"\(bool($0.element.enabled))\"" }.joined()
            out += "<streaming\(attrs)>\(bool(streams.contains { $0.enabled }))</streaming>\n"
        }
        out += "<playList>False</playList>\n<multiCorder>False</multiCorder>\n<fullscreen>False</fullscreen>\n"

        // 音频总线
        out += "<audio>\n"
        let headphones = state.audio.buses.first { $0.bus == .headphones }
        for bus in [Bus.master, .busA, .busB] {
            guard let b = state.audio.buses.first(where: { $0.bus == bus }) else { continue }
            let meter = stats?.audio.meters.buses.first { $0.bus == bus.name }?.peakDb
            var attrs = " volume=\"\(VolumeScale.format(VolumeScale.amplitudePercent(fromDb: b.gainDb)))\" muted=\"\(bool(b.muted))\""
            attrs += " meterF1=\"\(meterText(meter, 0))\" meterF2=\"\(meterText(meter, 1))\""
            if bus == .master {
                attrs += " headphonesVolume=\"\(VolumeScale.format(VolumeScale.amplitudePercent(fromDb: headphones?.gainDb ?? 0)))\""
            }
            out += "<\(bus.name)\(attrs) />\n"
        }
        out += "</audio>\n"
        out += "</\(rootElement)>"
        return out
    }

    static func inputElement(_ input: InputConfig, meter: [Double]?) -> String {
        let a = input.settings.audio
        var buses: [String] = []
        if a.routing.master { buses.append("M") }
        if a.routing.busA { buses.append("A") }
        if a.routing.busB { buses.append("B") }
        let title = escape(input.name)
        var s = "<input key=\"\(InputReference.key(forInput: input.number))\" number=\"\(input.number)\" type=\"\(typeName(input.kind))\""
        s += " title=\"\(title)\" shortTitle=\"\(title)\" state=\"Running\" position=\"0\" duration=\"0\" loop=\"False\""
        s += " muted=\"\(bool(a.muted))\" volume=\"\(VolumeScale.format(VolumeScale.amplitudePercent(fromDb: a.gainDb)))\""
        s += " balance=\"\(VolumeScale.format(a.pan))\" solo=\"\(bool(a.solo))\" audiobusses=\"\(buses.joined(separator: ","))\""
        s += " meterF1=\"\(meterText(meter, 0))\" meterF2=\"\(meterText(meter, 1))\">\(title)</input>\n"
        return s
    }

    /// 输入类型 → 上游的类型名（Companion 只对 Replay / GT / VideoCall 三种做特殊处理，这里永远不会输出它们）。
    static func typeName(_ kind: InputKind) -> String {
        switch kind {
        case .camera, .decklink: "Capture"
        case .screen: "Desktop"
        case .file: "Video"
        case .image: "Image"
        case .ndi: "NDI"
        case .audio: "Audio"
        case .synthetic: "Colour"
        }
    }

    static func effectName(_ type: TransitionType) -> String {
        switch type {
        case .cut: "Cut"
        case .fade: "Fade"
        case .wipe: "Wipe"
        case .zoom: "Zoom"
        case .stinger: "Stinger"
        }
    }

    static func bool(_ b: Bool) -> String { b ? "True" : "False" }

    /// dBFS 峰值 → 0–1 幅度文本；没有读数写 0。
    static func meterText(_ peakDb: [Double]?, _ channel: Int) -> String {
        guard let peakDb, channel < peakDb.count else { return "0" }
        return VolumeScale.format(VolumeScale.amplitude(fromDb: peakDb[channel]), decimals: 4)
    }

    /// XML 转义（属性和文本都用它）。
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
