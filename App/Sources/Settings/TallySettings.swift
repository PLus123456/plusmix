// 设置 › Tally（W5-L，01a P2 / 02 X32 / 04 Q46）：一个开关（默认关；打开 = App 起只读 tally 流、听局域网）、端口（默认 API 端口 + 1）、
// 只读地址 WS / HTTP 两行带"复制"、连接数（WS 订阅数）。即时生效：开 = 起 TallyServer、关 = 停、改端口 = 换端口重起，不用重起引擎。
// 地址按真在听的那个写：听 0.0.0.0 写本机局域网地址（主网卡排第一），听本机写 127.0.0.1；端口用实际绑上的（端口 0 = 系统分配时也对）。
// 页开着时每秒刷一次连接数与地址（换节目后新 session 的端口）。手机网页 tally 归后续方案 §5.3，不在这里。
import AppKit
import SwiftUI

@MainActor
final class TallySettingsModel: ObservableObject {
    @Published var enabled: Bool {
        didSet { if enabled != oldValue { commit(port: nil) } }
    }
    /// 端口（显示的是实际用的那个；改了 = 写进设置并换端口）。
    @Published var port: Int {
        didSet { if port != oldValue, !refreshing { commit(port: max(0, min(65535, port))) } }
    }
    /// 现在连着的 WS 客户端数。
    @Published private(set) var connections = 0
    /// 只读地址两行（没在听为空串）。
    @Published private(set) var wsAddress = ""
    @Published private(set) var httpAddress = ""
    /// 起不来的原因 / 没有局域网地址的说明（没有为空串）。
    @Published private(set) var note = ""
    private unowned let controller: AppController
    /// refresh 里改 port 时不当成用户改了端口。
    private var refreshing = false

    init(controller: AppController) {
        self.controller = controller
        enabled = controller.settings.tallyEnabled
        port = controller.settings.effectiveTallyPort
        refresh()
        // 每秒刷一次；设置窗关了模型跟着放掉，定时器下一次见 self 没了就自己停
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 即时生效：只写变了的那个键（开关 / 端口；--tally-port 带进来的端口关开关时不跟着存，W5-O），AppController 让跑着的 session 起 / 停 / 换端口。
    private func commit(port newPort: Int?) {
        let on = enabled
        controller.commitSettings { s in
            s.tallyEnabled = on
            if let newPort { s.tallyPort = newPort }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    }

    /// 连接数、地址、说明（每秒；开关之后马上也来一次）。
    func refresh() {
        let control = controller.session?.control
        let server = control?.tallyServer
        let newConnections = control?.tallyPublisher?.counters.subscribers ?? 0
        if connections != newConnections { connections = newConnections }
        var ws = "", http = "", text = ""
        if let server, let bound = server.boundPort {
            if let host = NetworkAddresses.reachableHosts(listenHost: server.configuration.host).first {
                ws = "ws://\(host):\(bound)/tally"
                http = "http://\(host):\(bound)/tally"
            } else {
                text = L("prefs.remote.noLAN")
            }
            if bound != port, controller.settings.tallyPort == nil || controller.settings.tallyPort == 0 {
                refreshing = true
                port = bound
                refreshing = false
            }
        } else if enabled, let error = control?.tallyError {
            text = error
        }
        if wsAddress != ws { wsAddress = ws }
        if httpAddress != http { httpAddress = http }
        if note != text { note = text }
    }
}

struct TallySettingsSection: View {
    @ObservedObject var model: TallySettingsModel

    var body: some View {
        Section(L("prefs.tally.title")) {
            Toggle(L("prefs.tally.enabled"), isOn: $model.enabled)
            TextField(L("prefs.tally.port"), value: $model.port, format: PreferencesModel.plainInteger)
            if !model.wsAddress.isEmpty {
                AddressRow(label: L("prefs.tally.ws"), address: model.wsAddress)
                AddressRow(label: L("prefs.tally.http"), address: model.httpAddress)
                LabeledContent(L("prefs.tally.connections")) { Text(verbatim: "\(model.connections)") }
            }
            if !model.note.isEmpty { Text(model.note).font(.caption).foregroundStyle(.yellow) }
            Text(L("prefs.tally.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
