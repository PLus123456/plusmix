// 统计窗（W5-L，01a E5 / 02 N15 / 04 Q42、Q44）：底栏"统计"开的只读窗，现场排查"哪一路在掉帧"不用再看 API。
// 五节：每路输入（fps / 重复 / 丢帧 / 延迟）、渲染、每个输出（按 EncoderEntry.output 对上名字 / 类型 / 来源，帧数 / 跳帧 / 丢帧 / 码率 / 状态）、
// 显示（Stats.display[]）、音频。数字全读 session 的 1 Hz Stats（铁律 4：同一份进 stats.jsonl / API / 状态行），这里不另算。
// "重置"只在界面记一个基线、显示"累计 − 基线"（Q44）：Stats 的累计值单调不减，stats.jsonl 与 API 不受影响。速率量（fps / 码率 / 渲染 ms / 延迟）原样显示。
// 换了 session（拍号或 missed_render 变小）基线作废；同一个 session 里某一路的计数从头来（删了又加回同号输入）只那一项按 0 当基线。
import AppKit
import SwiftUI
import SwitcherContracts

@MainActor
final class StatsWindowModel: ObservableObject {
    struct InputRow: Identifiable, Equatable {
        var number: Int
        var name: String
        var fps: Double
        var dup: UInt64
        var drop: UInt64
        var latencyMs: Double
        var latencyMaxMs: Double
        var id: Int { number }
    }

    struct RenderRow: Equatable {
        var renderMs: Double
        var missedRender: UInt64
        var jitterMs: Double
        var gpuPct: Double
        var cpuPct: Double
        var rssMb: Double
    }

    struct OutputRow: Identifiable, Equatable {
        var number: Int
        var name: String
        var kind: OutputKind?
        var source: String
        var state: String
        var frames: UInt64
        var skipped: UInt64
        var dropped: UInt64
        var bitrate: Double
        var reconnects: UInt64
        var connections: UInt64
        /// Stats.encoder 里的位置（编号 0 的项可能不止一个，靠它区分）。
        var index: Int
        var id: Int { index }
    }

    struct DisplayRow: Identifiable, Equatable {
        var output: Int
        var kind: String
        var name: String
        var state: String
        var frames: UInt64
        var dropped: UInt64
        var undelivered: UInt64
        var id: String { "\(kind)-\(output)" }
    }

    struct AudioRow: Equatable {
        var dropouts: UInt64
        var underruns: UInt64
        var discontinuities: UInt64
        /// Master 峰值（dBFS，左右大的那个）；没有表读数为 nil。
        var masterPeakDb: Double?
        /// Master 短期响度（LUFS）；没有表读数为 nil。
        var masterShortTermLUFS: Double?
    }

    @Published private(set) var inputRows: [InputRow] = []
    @Published private(set) var render: RenderRow?
    @Published private(set) var outputRows: [OutputRow] = []
    @Published private(set) var displayRows: [DisplayRow] = []
    @Published private(set) var audio: AudioRow?
    /// "重置"那一刻的 Stats（nil = 没重置过 / 换了 session 作废）。
    @Published private(set) var baseline: Stats?
    /// 重置的时刻（窗里写"自 … 起"）。
    @Published private(set) var baselineDate: Date?
    /// 最近一行。
    private(set) var latest: Stats?
    private var state = MixerState()

    init() {}

    /// 新的一行 Stats（1 Hz）+ 当时的快照（名字 / 类型 / 来源从快照对号）。
    func apply(stats: Stats, state: MixerState) {
        self.state = state
        if let base = baseline, stats.tick < base.tick || stats.missedRender < base.missedRender {
            baseline = nil
            baselineDate = nil
        }
        latest = stats
        rebuild()
    }

    /// 重置：记下最近一行当基线（只在这个窗里，Stats 不动）。
    func reset() {
        guard let latest else { return }
        baseline = latest
        baselineDate = Date()
        rebuild()
    }

    /// 累计量减基线；比基线还小（那一项从头来了）就原样给。
    private static func delta(_ value: UInt64, _ base: UInt64?) -> UInt64 {
        guard let base, value >= base else { return value }
        return value - base
    }

    private func rebuild() {
        guard let s = latest else { return }
        let base = baseline
        inputRows = s.perInput.keys.sorted().map { n in
            let p = s.perInput[n]!
            let b = base?.perInput[n]
            return InputRow(number: n, name: state.input(n)?.name ?? L("statsWindow.inputGone", n), fps: p.fps,
                            dup: Self.delta(p.dup, b?.dup), drop: Self.delta(p.drop, b?.drop), latencyMs: p.latencyMs, latencyMaxMs: p.latencyMaxMs)
        }
        render = RenderRow(renderMs: s.renderMs, missedRender: Self.delta(s.missedRender, base?.missedRender), jitterMs: s.jitterMs,
                           gpuPct: s.gpuPct, cpuPct: s.cpuPct, rssMb: s.rssMb)
        outputRows = s.encoder.enumerated().map { index, e in
            let output = e.output == 0 ? nil : state.output(e.output)
            let b = base.flatMap { Self.matching(e, at: index, in: s.encoder, from: $0.encoder) }
            let name = output?.name ?? (e.output == 0 ? L("statsWindow.outputUnlisted") : L("statsWindow.outputGone", e.output))
            return OutputRow(number: e.output, name: name, kind: output?.kind, source: output.map { $0.settings.source.title(in: state) } ?? "—",
                             state: Self.stateText(e, output: output), frames: Self.delta(e.frames, b?.frames), skipped: Self.delta(e.skipped, b?.skipped),
                             dropped: Self.delta(e.dropped, b?.dropped), bitrate: e.bitrate, reconnects: Self.delta(e.reconnects, b?.reconnects),
                             connections: e.connections, index: index)
        }
        displayRows = s.display.map { d in
            let b = base?.display.first { $0.kind == d.kind && $0.output == d.output }
            return DisplayRow(output: d.output, kind: d.kind, name: displayName(d), state: OutputStatusText.displayState(d.state),
                              frames: Self.delta(d.frames, b?.frames), dropped: Self.delta(d.dropped, b?.dropped),
                              undelivered: Self.delta(d.undelivered, b?.undelivered))
        }
        let master = s.audio.meters.buses.first { $0.bus == Bus.master.name }
        audio = AudioRow(dropouts: Self.delta(s.audio.dropouts, base?.audio.dropouts), underruns: Self.delta(s.audio.underruns, base?.audio.underruns),
                         discontinuities: Self.delta(s.audio.discontinuities, base?.audio.discontinuities),
                         masterPeakDb: master?.peakDb.max(), masterShortTermLUFS: master?.lufsS)
    }

    /// 基线里对应的那一项：有编号按编号；编号 0（不在输出表里，如 ISO 音轨）按"第几个编号 0"对。
    private static func matching(_ e: Stats.EncoderEntry, at index: Int, in current: [Stats.EncoderEntry], from base: [Stats.EncoderEntry]) -> Stats.EncoderEntry? {
        if e.output != 0 { return base.first { $0.output == e.output } }
        let nth = current.prefix(index).filter { $0.output == 0 }.count
        let zeros = base.filter { $0.output == 0 }
        return nth < zeros.count ? zeros[nth] : nil
    }

    /// 输出的状态文案：录制 / 推流与底栏 ▴ 同一套（OutputButtonSummary.routeState），其余按显示类的状态表。
    private static func stateText(_ e: Stats.EncoderEntry, output: OutputState?) -> String {
        if let output, output.kind == .record || output.kind == .stream {
            let route = OutputRouteStatus(number: output.number, name: output.name, enabled: output.enabled, state: e.state, frames: e.frames)
            return OutputButtonSummary.routeState(route, kind: output.kind == .record ? .record : .stream).text
        }
        return e.state == "unavailable" ? L("statsWindow.state.unavailable") : OutputStatusText.displayState(e.state)
    }

    /// 显示项的名字：主界面监视器 / 多画面窗口（编号 0）用固定名，外部显示 / 虚拟摄像头按编号查输出表。
    private func displayName(_ d: Stats.DisplayEntry) -> String {
        if d.output == 0 { return L("statsWindow.display.\(d.kind)") }
        return state.output(d.output)?.name ?? L("statsWindow.outputGone", d.output)
    }
}

@MainActor
final class StatsWindowController: PanelWindowController {
    let model: StatsWindowModel

    init(model: StatsWindowModel) {
        self.model = model
        super.init(title: L("statsWindow.title"), size: NSSize(width: 820, height: 600), autosaveName: "StatsWindow", content: StatsWindowView(model: model),
                   minSize: NSSize(width: 560, height: 360))
    }
}

struct StatsWindowView: View {
    @ObservedObject var model: StatsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L("statsWindow.reset")) { model.reset() }
                if let date = model.baselineDate {
                    Text(L("statsWindow.since", date.formatted(date: .omitted, time: .standard))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(L("statsWindow.resetHint")).font(.caption).foregroundStyle(.secondary)
            }
            if model.render == nil {
                Text(L("statsWindow.waiting")).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        inputs
                        renderSection
                        outputs
                        displays
                        audioSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
    }

    private func header(_ titles: [String]) -> some View {
        GridRow { ForEach(titles, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
    }

    private func cell(_ text: String) -> some View { Text(verbatim: text).font(.system(.body, design: .monospaced)).lineLimit(1) }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }

    private var inputs: some View {
        section(L("statsWindow.section.inputs")) {
            if model.inputRows.isEmpty {
                Text(L("statsWindow.none")).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    header([L("statsWindow.col.number"), L("statsWindow.col.name"), L("statsWindow.col.fps"), L("statsWindow.col.dup"),
                            L("statsWindow.col.drop"), L("statsWindow.col.latency"), L("statsWindow.col.latencyMax")])
                    ForEach(model.inputRows) { r in
                        GridRow {
                            cell("\(r.number)")
                            Text(r.name).lineLimit(1)
                            cell(String(format: "%.1f", r.fps))
                            cell("\(r.dup)")
                            cell("\(r.drop)")
                            cell(String(format: "%.2f ms", r.latencyMs))
                            cell(String(format: "%.2f ms", r.latencyMaxMs))
                        }
                    }
                }
            }
        }
    }

    private var renderSection: some View {
        section(L("statsWindow.section.render")) {
            if let r = model.render {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    header([L("statsWindow.col.renderMs"), L("statsWindow.col.missed"), L("statsWindow.col.jitter"), L("status.gpu"), L("status.cpu"),
                            L("statsWindow.col.rss")])
                    GridRow {
                        cell(String(format: "%.2f ms", r.renderMs))
                        cell("\(r.missedRender)")
                        cell(String(format: "%.2f ms", r.jitterMs))
                        cell(String(format: "%.0f%%", r.gpuPct))
                        cell(String(format: "%.0f%%", r.cpuPct))
                        cell(String(format: "%.0f MB", r.rssMb))
                    }
                }
            }
        }
    }

    private var outputs: some View {
        section(L("statsWindow.section.outputs")) {
            if model.outputRows.isEmpty {
                Text(L("statsWindow.none")).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    header([L("statsWindow.col.name"), L("statsWindow.col.kind"), L("statsWindow.col.source"), L("statsWindow.col.state"),
                            L("statsWindow.col.frames"), L("statsWindow.col.skipped"), L("statsWindow.col.dropped"), L("statsWindow.col.bitrate"),
                            L("statsWindow.col.reconnects")])
                    ForEach(model.outputRows) { r in
                        GridRow {
                            Text(r.number == 0 ? r.name : L("statsWindow.outputName", r.number, r.name)).lineLimit(1)
                            Text(r.kind.map { L("statsWindow.kind.\($0.rawValue)") } ?? "—").lineLimit(1)
                            Text(r.source).lineLimit(1)
                            Text(r.state).lineLimit(1)
                            cell("\(r.frames)")
                            cell("\(r.skipped)")
                            cell("\(r.dropped)")
                            cell(StatusLineFormatter.bitrateText(r.bitrate))
                            cell("\(r.reconnects)")
                        }
                    }
                }
            }
        }
    }

    private var displays: some View {
        section(L("statsWindow.section.displays")) {
            if model.displayRows.isEmpty {
                Text(L("statsWindow.none")).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    header([L("statsWindow.col.name"), L("statsWindow.col.state"), L("statsWindow.col.frames"), L("statsWindow.col.dropped"),
                            L("statsWindow.col.undelivered")])
                    ForEach(model.displayRows) { r in
                        GridRow {
                            Text(r.name).lineLimit(1)
                            Text(r.state).lineLimit(1)
                            cell("\(r.frames)")
                            cell("\(r.dropped)")
                            cell("\(r.undelivered)")
                        }
                    }
                }
            }
        }
    }

    private var audioSection: some View {
        section(L("statsWindow.section.audio")) {
            if let a = model.audio {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    header([L("statsWindow.col.dropouts"), L("statsWindow.col.underruns"), L("statsWindow.col.discontinuities"),
                            L("statsWindow.col.masterPeak"), L("statsWindow.col.masterLUFS")])
                    GridRow {
                        cell("\(a.dropouts)")
                        cell("\(a.underruns)")
                        cell("\(a.discontinuities)")
                        cell(a.masterPeakDb.map { String(format: "%.1f dBFS", $0) } ?? "—")
                        cell(a.masterShortTermLUFS.map { String(format: "%.1f LUFS", $0) } ?? "—")
                    }
                }
            }
        }
    }
}
