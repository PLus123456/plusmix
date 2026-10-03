// 设置的页（W5-J，01a F1 / F2，04 Q04 (a)）：侧栏两组——"本节目"（节目格式、输出各页、节目音频：随节目文件保存）与
// "本机"（常规、音频设备、远程控制、Tally、快捷键、MIDI、性能与电源、更新与诊断、高级：存在这台 Mac 上，所有节目共用）。
// ⌘, / 工具条"设置▾" / 各 ⚙ / 菜单里的设置页都走 PanelCoordinator.showSettings(page:)，打开同一个设置窗的对应页；
// ⌘, 与工具条"设置"主体回到上次那一页（没开过 = 常规）。上次那一页记在本机（UserDefaults）。
import Foundation

enum SettingsPage: Hashable, Sendable {
    // 本节目
    case showFormat
    case output(OutputSettingsModel.Tab)
    case showAudio
    // 本机
    case general, audioDevice, remoteControl, tally, hotkeys, midi, performance, updates, advanced

    enum Group: String, CaseIterable, Sendable {
        /// 随节目文件保存。
        case show
        /// 存在本机，所有节目共用。
        case machine
    }

    var group: Group {
        switch self {
        case .showFormat, .output, .showAudio: .show
        case .general, .audioDevice, .remoteControl, .tally, .hotkeys, .midi, .performance, .updates, .advanced: .machine
        }
    }

    /// 侧栏顺序（输出各页按 OutputSettingsModel.Tab.allCases：输出设置页加了页这里自动跟上）。
    static func pages(in group: Group) -> [SettingsPage] {
        switch group {
        case .show: [.showFormat] + OutputSettingsModel.Tab.allCases.map { .output($0) } + [.showAudio]
        case .machine: [.general, .audioDevice, .remoteControl, .tally, .hotkeys, .midi, .performance, .updates, .advanced]
        }
    }

    static var all: [SettingsPage] { Group.allCases.flatMap(pages(in:)) }

    /// 存档 / 菜单项 representedObject 用的名字："general"、"output.stream"……
    var id: String {
        switch self {
        case .showFormat: "showFormat"
        case .output(let tab): "output." + tab.rawValue
        case .showAudio: "showAudio"
        case .general: "general"
        case .audioDevice: "audioDevice"
        case .remoteControl: "remoteControl"
        case .tally: "tally"
        case .hotkeys: "hotkeys"
        case .midi: "midi"
        case .performance: "performance"
        case .updates: "updates"
        case .advanced: "advanced"
        }
    }

    init?(id: String) {
        guard let page = Self.all.first(where: { $0.id == id }) else { return nil }
        self = page
    }

    /// 改了要关窗 / 切页先问 保存 / 放弃 / 取消 的页（表要整张校验再存，01a F4）。
    var hasExplicitSave: Bool { self == .hotkeys || self == .midi }
}
