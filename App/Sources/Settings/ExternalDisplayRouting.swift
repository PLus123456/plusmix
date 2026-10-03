// 外部显示"每块屏单选一个源"（W5-I，prompt 95 第 4 条；01a M2 / M5，04 Q28）：输出设置 › 外部显示页与底栏 / 工具条的外部显示菜单（W5-F，prompt 92）
// 读写的是同一份数据——快照里 kind = externalDisplay 的输出，规则也相同：
// - 每块屏的"那一路" = 这块屏上开着的那一路，没有开着的就取编号最小的（老节目里同屏可能有好几路）；displayID 为 nil 的老输出算主屏的；
// - 选一个源：这块屏已有那一路 = 换源（setOutputSettings，窗口不重开）并打开，同屏别的开着的路关掉；没有 = addOutput 一路新的（名字"显示器 · 源"）；
// - 选"关闭"：这块屏开着的路都关掉（setOutputEnabled false），配置留着。
// 这里只给命令，不碰界面；G7 合并 92 时菜单的同名静态函数可以改成调这里（报告 §5）。
import Foundation
import SwitcherContracts
import SwitcherExternal

@MainActor
enum ExternalDisplayRouting {
    /// 某块屏上的外部显示输出（按编号）。displayID 为 nil 的老输出算在主屏上。
    static func outputs(on display: DisplayInfo, in state: MixerState) -> [OutputState] {
        state.outputs.filter { o in
            guard o.kind == .externalDisplay else { return false }
            let id = ExternalDisplaySpec(settings: o.settings).displayID
            return id == display.id || (id == nil && display.isMain)
        }
    }

    /// 这块屏的"那一路"：开着的优先，否则编号最小的。
    static func primaryOutput(on display: DisplayInfo, in state: MixerState) -> OutputState? {
        let list = outputs(on: display, in: state)
        return list.first(where: \.enabled) ?? list.first
    }

    /// 这块屏现在送的源；关着 / 没配 = nil（"关闭"）。
    static func currentSource(on display: DisplayInfo, in state: MixerState) -> OutputSource? {
        guard let p = primaryOutput(on: display, in: state), p.enabled else { return nil }
        return p.settings.source
    }

    /// 菜单 / 页起的名字："显示器 · 源"。
    static func autoName(displayName: String, source: OutputSource, in state: MixerState) -> String {
        L("externalMenu.outputName", displayName, source.title(in: state))
    }

    /// 可选的源：PGM / PVW / 多画面 / 各输入。
    static func sources(in state: MixerState) -> [OutputSource] {
        [.program, .preview, .multiview] + state.inputs.map { .input(number: $0.number) }
    }

    /// 选源（nil = 关闭）要发的命令。
    static func pick(display: DisplayInfo, source: OutputSource?, in state: MixerState) -> [Command] {
        let onScreen = outputs(on: display, in: state)
        guard let source else {
            return onScreen.filter(\.enabled).map { .setOutputEnabled(output: $0.number, on: false) }
        }
        guard let primary = primaryOutput(on: display, in: state) else {
            let number = (state.outputs.map(\.number).max() ?? 0) + 1
            let spec = ExternalDisplaySpec(displayID: display.id, source: source, fallbackToMain: false)
            let output = OutputState(number: number, kind: .externalDisplay, name: autoName(displayName: display.name, source: source, in: state),
                                     enabled: true, settings: spec.outputSettings)
            return [.addOutput(config: output)]
        }
        var out: [Command] = []
        if primary.settings.source != source {
            var settings = primary.settings
            settings.source = source
            out.append(.setOutputSettings(output: primary.number, settings: settings))
            // 名字还是自动起的"显示器 · 旧源"就跟着换（用户改过的名字不动）
            if primary.name == autoName(displayName: display.name, source: primary.settings.source, in: state) {
                out.append(.renameOutput(output: primary.number, name: autoName(displayName: display.name, source: source, in: state)))
            }
        }
        if !primary.enabled { out.append(.setOutputEnabled(output: primary.number, on: true)) }
        for o in onScreen where o.number != primary.number && o.enabled { out.append(.setOutputEnabled(output: o.number, on: false)) }
        return out
    }
}
