// 音频设置窗（W5-K，prompt 97 交付 4，01a J2–J7 / 02 X12）：每条总线 / 每路输入一扇独立窗。
import AppKit
import SwiftUI
import SwitcherContracts

/// 调音台上的一条：总线或输入。
enum AudioStrip: Hashable {
    case bus(Bus)
    case input(Int)
}

enum AudioSettingsPage: String, CaseIterable, Identifiable {
    case general, eq, compressor, limiter
    var id: String { rawValue }
}

@MainActor
final class AudioSettingsModel: ObservableObject {
    let strip: AudioStrip
    @Published var page: AudioSettingsPage = .general
    @Published private(set) var state: MixerState
    var send: ((Command) -> Void)?

    init(strip: AudioStrip, state: MixerState) {
        self.strip = strip
        self.state = state
    }

    var pages: [AudioSettingsPage] { [] }
    func apply(state: MixerState) { self.state = state }
}

struct AudioSettingsView: View {
    @ObservedObject var model: AudioSettingsModel
    var body: some View { Text(L("audioSettings.windowTitle.master")) }
}

@MainActor
final class AudioSettingsWindowController: PanelWindowController {
    let model: AudioSettingsModel
    init(model: AudioSettingsModel) {
        self.model = model
        super.init(title: "", size: NSSize(width: 560, height: 480), autosaveName: "AudioSettings", content: AudioSettingsView(model: model))
    }
    func apply(state: MixerState) { model.apply(state: state) }
}
