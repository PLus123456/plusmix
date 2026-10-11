// 推流 / 录制状态面板（W5-N，01a L11 / 02 V11 / 04 Q13 (a)）：底栏推流 ▴ 的"推流状态…"、录制 ▴ 的"录制状态…"、推流页 / 录制页的按钮都开它（一个窗，两页）。
// - 每个目的地 / 录制输出一行：名字 / 状态 / 码率 / 丢帧 / 重连 / 时长 / 断线 / 最后错误（录制页：时长 / 码率 / 帧数 / 丢帧 / 剩余空间 / 最后错误），
//   数全读 Stats.encoder（提案 022 的 uptime_s / disconnects / last_error / attempt；铁律 4：API、stats.jsonl、底栏读同一份），这里不另算。
//   最后错误原样显示 StreamOutput / Recorder / 运行表填的那一行（鉴权失败的三种文字已能区分，reports/w5-stream-auth.md §5 第 3 条）。
// - 下面带时间的事件记录（连接中 → 推流中 → 断开 → 重连中 → 重连上 / 已停止 / 失败）：由相邻两行 Stats 里同一路的状态变化推出，时间 = 那一行的 ts；
//   只做显示，不计数（次数看上面那几列）。1 Hz 采样，一秒内来回的变化看不到。窗口关着也照记（PanelCoordinator 每行 Stats 都喂），换 session 清空。
// - "显示日志…"= 帮助 › 打开诊断文件夹（推流 / 录制的日志在里面）。底部一行"视频延后 n ms"读 Stats 的 video_delay_ms（W1-B4，带效果的监听同步）。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class OutputStatusModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case stream, record
        var id: String { rawValue }
        var title: String { L("outputStatus.page.\(rawValue)") }
        var kind: OutputKind { self == .stream ? .stream : .record }
    }

    /// 一路的一行（全是显示用的字，数原样来自 Stats）。
    struct Row: Identifiable, Equatable {
        var number: Int
        var name: String
        var state: String
        var severity: OutputButtonSeverity
        var bitrate: String
        var dropped: String
        /// 推流：成功重连次数（reconnects）。
        var reconnects: String
        var uptime: String
        /// 推流：掉线次数（disconnects，022）。
        var disconnects: String
        var lastError: String
        /// 录制：写进文件的帧数。
        var frames: String
        /// 录制：所在卷剩余。
        var disk: String
        var id: Int { number }
    }

    struct Event: Identifiable, Equatable {
        let id: Int
        /// 那一行 Stats 的 ts（墙钟）。
        let time: Date
        let page: Page
        let output: Int
        /// "名字 · 状态"。
        let text: String
        var timeText: String { time.formatted(date: .omitted, time: .standard) }
    }

    @Published var page: Page = .stream
    @Published private(set) var streamRows: [Row] = []
    @Published private(set) var recordRows: [Row] = []
    @Published private(set) var events: [Event] = []
    /// "视频延后 n ms"（Stats.video_delay_ms > 0 时）。
    @Published private(set) var videoDelayText: String?
    /// 收到过 Stats（没收到时窗里写"等待统计…"）。
    @Published private(set) var hasStats = false
    /// "显示日志…"：打开诊断文件夹（测试换掉它，不真开 Finder）。
    var showLogs: (() -> Void)? = { DiagnosticsExport.revealFolder() }
    static var showLogsTitle: String { L("outputStatus.showLogs") }
    /// 事件最多留多少条（老的丢掉）。
    static let maxEvents = 500

    /// 每一路上一次看到的样子（推事件用）。
    private struct Seen {
        var text: String
        var state: String
        var enabled: Bool
        var frames: UInt64
        var lastError: String
    }
    private var seen: [Int: Seen] = [:]
    private var nextEventID = 0

    init() {}

    func events(for page: Page) -> [Event] { events.filter { $0.page == page } }

    /// 换 session / 新节目：清空（事件记录只属于这一场）。
    func reset() {
        streamRows = []
        recordRows = []
        events = []
        videoDelayText = nil
        hasStats = false
        seen = [:]
    }

    /// 新的一行 Stats（1 Hz）+ 当时的快照（名字 / 开关从快照对号，提案 019 的 output 编号）。
    func apply(stats: Stats, state: MixerState) {
        hasStats = true
        let time = Date(timeIntervalSince1970: stats.ts)
        var newEvents: [Event] = []
        var stream: [Row] = [], record: [Row] = []
        for o in state.outputs where o.kind == .stream || o.kind == .record {
            let page: Page = o.kind == .stream ? .stream : .record
            let entry = OutputRuntime.encoderEntry(stats.encoder, forOutput: o.number)
            let route = OutputRouteStatus(output: o, entry: entry)
            let s = OutputButtonSummary.routeState(route, kind: page == .stream ? .stream : .record)
            let row = Self.row(o, entry: entry, stateText: s.text, severity: s.severity)
            if page == .stream { stream.append(row) } else { record.append(row) }
            if let text = eventText(o, entry: entry, route: route, stateText: s.text) {
                newEvents.append(Event(id: nextEventID, time: time, page: page, output: o.number, text: L("outputStatus.event", o.name, text)))
                nextEventID += 1
            }
        }
        for n in seen.keys where state.output(n) == nil { seen.removeValue(forKey: n) }
        if stream != streamRows { streamRows = stream }
        if record != recordRows { recordRows = record }
        if !newEvents.isEmpty {
            var all = events + newEvents
            if all.count > Self.maxEvents { all.removeFirst(all.count - Self.maxEvents) }
            events = all
        }
        let delay = stats.videoDelayMs > 0 ? L("outputStatus.videoDelay", Int(stats.videoDelayMs.rounded())) : nil
        if delay != videoDelayText { videoDelayText = delay }
    }

    private static func row(_ o: OutputState, entry e: Stats.EncoderEntry?, stateText: String, severity: OutputButtonSeverity) -> Row {
        let dash = "—"
        let running = e.map { !["idle", "stopped", "failed", "unavailable"].contains($0.state) } ?? false
        return Row(number: o.number, name: o.name, state: stateText, severity: severity,
                   bitrate: running ? StatusLineFormatter.bitrateText(e!.bitrate) : dash,
                   dropped: e.map { "\($0.dropped)" } ?? dash,
                   reconnects: e.map { "\($0.reconnects)" } ?? dash,
                   uptime: running ? OutputButtonSummary.durationText(e!.uptimeS) : dash,
                   disconnects: e.map { "\($0.disconnects)" } ?? dash,
                   lastError: e?.lastError ?? "",
                   frames: e.map { "\($0.frames)" } ?? dash,
                   disk: e.flatMap { $0.diskFreeMb > 0 ? StatusLineFormatter.diskText(megabytes: $0.diskFreeMb) : nil } ?? dash)
    }

    /// 这一路这一行要不要记一条、记什么（相对上一次看到的样子）：状态文字变了才记；在推 → 连接 / 退避 = "断开（：原因）"，
    /// 连上过之后的连接 / 退避 → 在推 = "重连上"；在跑 → 关了 = "已停止"；失败带原因。第一次看到、又没在跑的不记。
    private func eventText(_ o: OutputState, entry: Stats.EncoderEntry?, route: OutputRouteStatus, stateText: String) -> String? {
        var now = Seen(text: stateText, state: entry?.state ?? "", enabled: o.enabled, frames: entry?.frames ?? 0, lastError: entry?.lastError ?? "")
        let before = seen[o.number]
        defer { seen[o.number] = now }
        let reconnectStates = ["connecting", "backoff"]
        guard let before else {
            return o.enabled ? stateText : nil
        }
        guard before.text != now.text || before.enabled != now.enabled else { return nil }
        if !now.enabled { return before.enabled ? L("outputStatus.event.stopped") : nil }
        if before.state == "publishing", reconnectStates.contains(now.state) {
            // 断开这一条代替了"重连中（第 n 次）"：记成没写过状态，下一行开始重连时那条照记
            now.text = ""
            return now.lastError.isEmpty ? L("outputStatus.event.disconnected") : L("outputStatus.event.disconnectedReason", now.lastError)
        }
        if reconnectStates.contains(before.state), before.frames > 0, now.state == "publishing" { return L("outputStatus.event.reconnected") }
        if now.state == "failed", !now.lastError.isEmpty { return L("outputStatus.event.failedReason", stateText, now.lastError) }
        return stateText
    }
}

@MainActor
final class OutputStatusWindowController: PanelWindowController {
    let model: OutputStatusModel

    init(model: OutputStatusModel) {
        self.model = model
        super.init(title: L("outputStatus.title"), size: NSSize(width: 900, height: 540), autosaveName: "OutputStatusWindow",
                   content: OutputStatusView(model: model), minSize: NSSize(width: 640, height: 360))
    }
}

struct OutputStatusView: View {
    @ObservedObject var model: OutputStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("outputStatus.pagePicker"), selection: $model.page) {
                ForEach(OutputStatusModel.Page.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            if !model.hasStats {
                Text(L("outputStatus.waiting")).foregroundStyle(.secondary)
            }
            table
            Divider()
            Text(L("outputStatus.events")).font(.headline)
            let events = model.events(for: model.page)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if events.isEmpty { Text(L("outputStatus.noEvents")).foregroundStyle(.secondary) }
                    ForEach(events.reversed()) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(e.timeText).monospacedDigit().foregroundStyle(.secondary)
                            Text(e.text).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
            HStack {
                if let delay = model.videoDelayText { Text(delay).font(.caption).foregroundStyle(.secondary) }
                Text(L("outputStatus.hint")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("outputStatus.showLogs")) { model.showLogs?() }
                    .help(L("outputStatus.showLogsTip"))
            }
        }
        .padding(12)
    }

    private func header(_ titles: [String]) -> some View {
        GridRow { ForEach(titles, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
    }

    private func cell(_ text: String) -> some View { Text(verbatim: text).monospacedDigit().lineLimit(1) }

    private func stateCell(_ row: OutputStatusModel.Row) -> some View {
        Text(row.state).lineLimit(1).foregroundStyle(row.severity >= .warning ? Color(nsColor: row.severity == .error ? .systemRed : .systemOrange) : .primary)
    }

    @ViewBuilder
    private var table: some View {
        let rows = model.page == .stream ? model.streamRows : model.recordRows
        if rows.isEmpty {
            Text(model.page == .stream ? L("outputStatus.noStreams") : L("outputStatus.noRecords")).foregroundStyle(.secondary)
        } else if model.page == .stream {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                header(["name", "state", "bitrate", "dropped", "reconnects", "uptime", "disconnects", "lastError"].map { L("outputStatus.col.\($0)") })
                ForEach(rows) { r in
                    GridRow {
                        Text(r.name).lineLimit(1)
                        stateCell(r)
                        cell(r.bitrate)
                        cell(r.dropped)
                        cell(r.reconnects)
                        cell(r.uptime)
                        cell(r.disconnects)
                        Text(r.lastError.isEmpty ? "—" : r.lastError).lineLimit(2).textSelection(.enabled).help(r.lastError)
                    }
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                header(["name", "state", "uptime", "bitrate", "frames", "dropped", "disk", "lastError"].map { L("outputStatus.col.\($0)") })
                ForEach(rows) { r in
                    GridRow {
                        Text(r.name).lineLimit(1)
                        stateCell(r)
                        cell(r.uptime)
                        cell(r.bitrate)
                        cell(r.frames)
                        cell(r.dropped)
                        cell(r.disk)
                        Text(r.lastError.isEmpty ? "—" : r.lastError).lineLimit(2).textSelection(.enabled).help(r.lastError)
                    }
                }
            }
        }
    }
}
