// 底栏录制 / 推流主体按钮的文案、颜色与提示（W5-B：02 X02 / X11，01a L4 / L13 / K11）。纯函数，测试直接喂。
// 输入是每一路的：目标开关（快照里的 enabled）、Stats.encoder 里那一项的 state / frames（铁律 4，同一行 Stats）、起不来的原因（OutputRuntime 的 failed 表）、
// 推流正在第几次连接（StreamOutput 的状态机——Stats.encoder 只有成功重连次数 reconnects，没有尝试次数，见报告 §4）。
// 汇总口径：
//   - 没有一路开着 → "推流" / "录制"；
//   - 有一路起不来 / 失败（红）或在重连、首连已失败过（橙）→ 只有一路开着时直接写它的状态（"推流 · 重连中（第 2 次）"），多路写"推流 · k 路异常"，
//     颜色按最差的那一路；提示里逐路列状态与原因；
//   - 否则有在推的 → "● 推流中"（只有一个目的地）/ "● 推流中 n/m"（n = 在推的路数，m = 目的地总数）；录制 → "● 录制中" / "● 录制中（n 路）"；
//   - 其余（刚开、首连第 1 次、封口中）→ "推流 · 连接中" 之类，颜色同"开着"。
// state 一律查本地化表（"推流 · idle"这类原样英文不再出现）；首次连接叫"连接中"，连上过之后才叫"重连中"，次数是真实的尝试次数。
import AppKit

/// 一路录制 / 推流在按钮眼里的样子。
struct OutputRouteStatus: Equatable {
    var number: Int
    var name: String
    /// 目标开关（快照里的 enabled）。
    var enabled: Bool
    /// Stats.encoder 里这一路的 state（还没有这一项为 nil）。
    var state: String?
    /// Stats.encoder 里这一路的 frames（推流：交给网络的帧数，> 0 = 连上过）。
    var frames: UInt64 = 0
    /// 推流：正在 / 即将进行第几次连接（从 1 起，StreamOutput 的 connecting / backoff；不在连为 nil）。
    var attempt: Int? = nil
    /// 起不来的原因（没有地址 / 地址不认 / 建不起来 / 录制起不来……）；nil = 没有。
    var failure: String? = nil
}

/// 有多糟：off（没开）< live（在推 / 在录）< pending（刚开、首连、封口中）< warning（重连中、首连已失败过）< error（起不来 / 失败）。
enum OutputButtonSeverity: Int, Comparable, Sendable {
    case off, live, pending, warning, error
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// 底栏 ▴ 菜单里一路的勾（W5-F）：在录 / 在推 = ✓；开着但还没录上 / 推上（连接中、起不来、封口中）= 横杠；没开 = 空。
    func menuState(enabled: Bool) -> NSControl.StateValue {
        guard enabled else { return .off }
        return self == .live ? .on : .mixed
    }
}

/// 一个主体按钮显示什么。
struct OutputButtonSummary: Equatable {
    var title: String
    var toolTip: String?
    var severity: OutputButtonSeverity

    /// 高亮色：开着（在推 / 在录 / 准备中）= 原来的录制红；重连 = 橙；起不来 = 深红。没开不高亮。
    @MainActor var color: NSColor {
        switch severity {
        case .off, .live, .pending: Theme.recording
        case .warning: Theme.outputWarning
        case .error: Theme.outputError
        }
    }
    var highlighted: Bool { severity != .off }

    enum Kind { case record, stream }

    static func durationText(_ seconds: Double) -> String { "" }

    static func stream(_ routes: [OutputRouteStatus]) -> OutputButtonSummary { summarize(routes, kind: .stream) }
    static func record(_ routes: [OutputRouteStatus]) -> OutputButtonSummary { summarize(routes, kind: .record) }

    /// 一路的状态文字与严重程度（按钮、提示、推流页那一段的状态行共用）。
    static func routeState(_ r: OutputRouteStatus, kind: Kind) -> (text: String, severity: OutputButtonSeverity) {
        guard r.enabled else { return (L("output.state.off"), .off) }
        if r.failure != nil { return (L("output.state.startFailed"), .error) }
        let state = r.state ?? "idle"
        switch kind {
        case .stream:
            switch state {
            case "publishing": return (L("output.state.stream.publishing"), .live)
            case "connecting", "backoff":
                if r.frames > 0 {
                    // 连上过：重连。StreamOutput 断线后从第 2 次连接算起（第 1 次 = 原来那条连接），所以第 n 次重连 = 第 n + 1 次连接
                    guard let a = r.attempt else { return (L("output.state.stream.reconnecting"), .warning) }
                    return (L("output.state.stream.reconnectingAttempt", max(1, a - 1)), .warning)
                }
                guard let a = r.attempt, a >= 2 else { return (L("output.state.stream.connecting"), .pending) }
                return (L("output.state.stream.connectingAttempt", a), .warning)
            case "failed": return (L("output.state.stream.failed"), .error)
            case "stopping": return (L("output.state.stream.stopping"), .pending)
            case "stopped": return (L("output.state.stream.stopped"), .pending)
            case "idle": return (L("output.state.stream.idle"), .pending)
            default: return (state, .pending)
            }
        case .record:
            switch state {
            case "recording": return (L("output.state.record.recording"), .live)
            case "failed": return (L("output.state.record.failed"), .error)
            case "stopping": return (L("output.state.record.stopping"), .pending)
            case "stopped": return (L("output.state.record.stopped"), .pending)
            case "idle": return (L("output.state.record.idle"), .pending)
            default: return (state, .pending)
            }
        }
    }

    private static func summarize(_ routes: [OutputRouteStatus], kind: Kind) -> OutputButtonSummary {
        let off = kind == .stream ? L("bottom.stream") : L("bottom.record")
        let enabled = routes.filter(\.enabled)
        let states = Dictionary(uniqueKeysWithValues: routes.map { ($0.number, routeState($0, kind: kind)) })
        let tip = routes.map { r -> String in
            let s = states[r.number]!.text
            return r.enabled && r.failure != nil ? L("bottom.tip.lineReason", r.name, s, r.failure!) : L("bottom.tip.line", r.name, s)
        }.joined(separator: "\n")
        guard !enabled.isEmpty else { return OutputButtonSummary(title: off, toolTip: tip.isEmpty ? nil : tip, severity: .off) }
        let problems = enabled.filter { states[$0.number]!.severity >= .warning }
        let live = enabled.filter { states[$0.number]!.severity == .live }
        if let worst = problems.map({ states[$0.number]!.severity }).max() {
            let title: String
            if enabled.count == 1 {
                title = kind == .stream ? L("bottom.streamState", states[enabled[0].number]!.text) : L("bottom.recordState", states[enabled[0].number]!.text)
            } else {
                title = kind == .stream ? L("bottom.streamProblems", problems.count) : L("bottom.recordProblems", problems.count)
            }
            // 推流：有起不来的路时点主体 = 重试它们（不停正常的），提示里说一句
            let hint = kind == .stream && enabled.contains(where: { $0.failure != nil }) ? "\n" + L("bottom.tip.retryHint") : ""
            return OutputButtonSummary(title: title, toolTip: tip + hint, severity: worst)
        }
        switch kind {
        case .stream where !live.isEmpty:
            let title = routes.count == 1 ? L("bottom.streaming") : L("bottom.streamingMany", live.count, routes.count)
            return OutputButtonSummary(title: title, toolTip: tip, severity: .live)
        case .record where live.count == enabled.count:
            let title = enabled.count > 1 ? L("bottom.recordingMany", enabled.count) : L("bottom.recording")
            return OutputButtonSummary(title: title, toolTip: tip, severity: .live)
        default:
            // 都还在路上（刚开 / 首连 / 封口中）：写第一路还没到的状态
            let first = enabled.first { states[$0.number]!.severity == .pending } ?? enabled[0]
            let text = states[first.number]!.text
            let title: String
            if kind == .stream {
                title = enabled.count > 1 ? L("bottom.streamStateMany", text, enabled.count) : L("bottom.streamState", text)
            } else {
                title = enabled.count > 1 ? L("bottom.recordStateMany", text, enabled.count) : L("bottom.recordState", text)
            }
            return OutputButtonSummary(title: title, toolTip: tip, severity: .pending)
        }
    }
}

extension Theme {
    /// 输出按钮：有路在重连 / 首连已失败过（橙）。
    static let outputWarning = NSColor(red: 0.93, green: 0.55, blue: 0.10, alpha: 1)
    /// 输出按钮：有路起不来 / 失败（深红，和"在推 / 在录"的红分得开）。
    static let outputError = NSColor(red: 0.62, green: 0.06, blue: 0.06, alpha: 1)
}
