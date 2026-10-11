// W5-N 桩（红）。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class OutputStatusModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable { case stream, record; var id: String { rawValue } }
    struct Row: Identifiable, Equatable {
        var number: Int
        var name = ""
        var state = ""
        var bitrate = ""
        var dropped = ""
        var reconnects = ""
        var uptime = ""
        var disconnects = ""
        var lastError = ""
        var frames = ""
        var disk = ""
        var id: Int { number }
    }
    struct Event: Identifiable, Equatable {
        let id: Int
        let time: Date
        let page: Page
        let output: Int
        let text: String
    }
    @Published var page: Page = .stream
    @Published private(set) var streamRows: [Row] = []
    @Published private(set) var recordRows: [Row] = []
    @Published private(set) var events: [Event] = []
    @Published private(set) var videoDelayText: String?
    var showLogs: (() -> Void)?
    static let showLogsTitle = ""
    func events(for page: Page) -> [Event] { events.filter { $0.page == page } }
    func apply(stats: Stats, state: MixerState) {}
}

@MainActor
final class OutputStatusWindowController: PanelWindowController {}
