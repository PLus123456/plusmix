// 叠加设置独立窗（W5-K，prompt 97 交付 3，01a I1–I3 / 02 X21 / 04 Q40）。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class OverlaySettingsModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case fullscreen, pictureInPicture
        var id: String { rawValue }
    }
    static let quickDurations: [Double] = [0.5, 1, 2]
    @Published private(set) var state: MixerState
    @Published var channel = 1
    var send: ((Command) -> Void)?

    init(state: MixerState, channel: Int = 1) {
        self.state = state
        self.channel = channel
    }

    func apply(state: MixerState) { self.state = state }
    func setInput(channel: Int, input: Int?) {}
    func setDurationSeconds(channel: Int, _ seconds: Double) {}
    func durationSeconds(channel: Int) -> Double { 0 }
    func setMode(channel: Int, _ mode: Mode) {}
    func mode(channel: Int) -> Mode { .fullscreen }
}

struct OverlaySettingsView: View {
    @ObservedObject var model: OverlaySettingsModel
    var body: some View { Text(L("overlay.windowTitle")) }
}

@MainActor
final class OverlaySettingsWindowController: PanelWindowController {
    let model: OverlaySettingsModel
    init(model: OverlaySettingsModel) {
        self.model = model
        super.init(title: L("overlay.windowTitle"), size: NSSize(width: 420, height: 560), autosaveName: "OverlaySettings", content: OverlaySettingsView(model: model))
    }
    func apply(state: MixerState) { model.apply(state: state) }
}
