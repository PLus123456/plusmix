// 统计窗（W5-L，01a E5 / 02 N15 / 04 Q42、Q44）：底栏"统计"开的只读窗，现场排查"哪一路在掉帧"不用再看 API。
// 五节：每路输入（fps / 重复 / 丢帧 / 延迟）、渲染、每个输出（按 EncoderEntry.output 对上名字 / 类型 / 来源，帧数 / 跳帧 / 丢帧 / 码率 / 状态）、
// 显示（Stats.display[]）、音频。数字全读 session 的 1 Hz Stats（铁律 4：同一份进 stats.jsonl / API / 状态行），这里不另算。
// "重置"只在界面记一个基线、显示"累计 − 基线"（Q44）：Stats 的累计值单调不减，stats.jsonl 与 API 不受影响；换了 session（累计量变小）基线作废。
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
        var id: Int { number }
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
        var masterShortTermLUFS: Double?
    }

    @Published private(set) var inputRows: [InputRow] = []
    @Published private(set) var render: RenderRow?
    @Published private(set) var outputRows: [OutputRow] = []
    @Published private(set) var displayRows: [DisplayRow] = []
    @Published private(set) var audio: AudioRow?
    /// "重置"那一刻的 Stats（nil = 没重置过 / 换了 session 作废）。
    @Published private(set) var baseline: Stats?
    /// 最近一行。
    private(set) var latest: Stats?
    private var state = MixerState()

    init() {}

    /// 新的一行 Stats（1 Hz）+ 当时的快照（名字 / 类型 / 来源从快照对号）。
    func apply(stats: Stats, state: MixerState) {}

    /// 重置：记下最近一行当基线。
    func reset() {}
}

@MainActor
final class StatsWindowController: PanelWindowController {
    let model: StatsWindowModel

    init(model: StatsWindowModel) {
        self.model = model
        super.init(title: L("statsWindow.title"), size: NSSize(width: 760, height: 560), autosaveName: "StatsWindow", content: StatsWindowView(model: model))
    }
}

struct StatsWindowView: View {
    @ObservedObject var model: StatsWindowModel

    var body: some View {
        Text(L("statsWindow.waiting")).padding()
    }
}
