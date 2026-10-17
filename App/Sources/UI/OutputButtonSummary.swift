// 底栏录制 / 推流主体按钮的文案、颜色与提示（W5-B：02 X02 / X11，01a L4 / L13 / K11）。纯函数，测试直接喂。
// 输入是每一路的：目标开关（快照里的 enabled）、Stats.encoder 里那一项的 state / frames / attempt / uptime_s（铁律 4，同一行 Stats；
// W5-N 起"第几次连接"读 022 的 attempt、不再读 App 的运行表，G6 追加 ②）、起不来的原因（OutputRuntime 的 failed 表）。
// W5-N（01a E10）：在录 / 在推时标题带时长"● 录制 01:02:05"，时长 = Stats.encoder[].uptime_s（多路取最长那一路），不在 App 里自己计时；
// 工具条右组、录制 ▴、ISO 表、状态面板读同一份。
// 汇总口径：
//   - 没有一路开着 → "推流" / "录制"；
//   - 有一路起不来 / 失败（红）或在重连、首连已失败过（橙）→ 只有一路开着时直接写它的状态（"推流 · 重连中（第 2 次）"），多路写"推流 · k 路异常"，
//     颜色按最差的那一路；提示里逐路列状态与原因；
//   - 否则有在推的 → "● 推流中"（只有一个目的地）/ "● 推流中 n/m"（n = 在推的路数，m = 目的地总数）；录制 → "● 录制中" / "● 录制中（n 路）"；
//   - 其余（刚开、首连第 1 次、封口中）→ "推流 · 连接中" 之类，颜色同"开着"。
// state 一律查本地化表（"推流 · idle"这类原样英文不再出现）；首次连接叫"连接中"，连上过之后才叫"重连中"，次数是真实的尝试次数。
import AppKit
import SwitcherContracts

/// 一路起不来 / 停住的原因（OutputRuntime.routeFailure 给）。用字符串字面量写 = 运行表起不来的那一种（测试、老调用照旧传一句原因）。
struct OutputRouteFailure: Equatable, Sendable, ExpressibleByStringLiteral {
    /// 给人看的一句原因。
    var reason: String
    /// 推流对象自己停在 failed（服务器拒绝鉴权；重连放弃——App 里不给重连上限，正常不会出现）：Stats 报 failed，界面写"失败"（与状态窗同字，
    /// W5-P / 111 留下的，用户 2026-10-17 定）；改地址 / 账号不会自动重试，要点"重试"或底栏主体。false = 运行表起不来（没地址 / 地址不认 /
    /// 建不起来 / 录制起不来），写"起不来"，设置改对了自动重试。
    var stoppedStream = false

    init(reason: String, stoppedStream: Bool = false) {
        self.reason = reason
        self.stoppedStream = stoppedStream
    }

    init(stringLiteral value: String) { self.init(reason: value) }
}

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
    /// 推流：正在 / 即将进行第几次连接（从 1 起，Stats.encoder 的 attempt（提案 022 B1）；不在连为 nil）。
    var attempt: Int? = nil
    /// 起不来 / 停住的原因（没有地址 / 地址不认 / 建不起来 / 录制起不来 / 推流对象停在 failed……）；nil = 没有。
    var failure: String? = nil
    /// 这一路本次运行的时长（秒，Stats.encoder 的 uptime_s，提案 022）；没有这一项为 0。
    var uptime: Double = 0
    /// failure 来自停在 failed 的推流对象（OutputRouteFailure.stoppedStream）：状态按 Stats 的 failed 写"失败"，点主体照样重试它。
    var failureStopped = false
}

extension OutputRouteStatus {
    /// 快照里的一路 + Stats.encoder 里它那一项（按 output 对号）+ 起不来的原因：state / frames / attempt / uptime 全读 Stats（W5-N）。
    init(output o: OutputState, entry: Stats.EncoderEntry?, failure: OutputRouteFailure? = nil) {
        self.init(number: o.number, name: o.name, enabled: o.enabled, state: entry?.state, frames: entry?.frames ?? 0,
                  attempt: entry.flatMap { $0.attempt > 0 ? $0.attempt : nil }, failure: failure?.reason, uptime: entry?.uptimeS ?? 0,
                  failureStopped: failure?.stoppedStream ?? false)
    }
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

    /// 时长"hh:mm:ss"（向下取整到秒；超过一天小时数照写、不绕回；负数 / 非有限按 0）。底栏、工具条、录制 ▴、ISO 表、状态面板共用。
    static func durationText(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds.rounded(.down)) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func stream(_ routes: [OutputRouteStatus]) -> OutputButtonSummary { summarize(routes, kind: .stream) }
    static func record(_ routes: [OutputRouteStatus]) -> OutputButtonSummary { summarize(routes, kind: .record) }

    /// 一路的状态文字与严重程度（按钮、提示、推流页那一段的状态行共用）。
    static func routeState(_ r: OutputRouteStatus, kind: Kind) -> (text: String, severity: OutputButtonSeverity) {
        guard r.enabled else { return (L("output.state.off"), .off) }
        if r.failure != nil {
            // 推流对象自己停在 failed（服务器拒绝鉴权）：与 Stats / 状态窗同一个字"失败"，不叫"起不来"（W5-P，111 留下的）；failure 照旧非空，点主体 = 重试它
            if r.failureStopped { return (kind == .stream ? L("output.state.stream.failed") : L("output.state.record.failed"), .error) }
            return (L("output.state.startFailed"), .error)
        }
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
            // 推流：有起不来 / 失败的路时点主体 = 重试它们（不停正常的），提示里说一句（有停在 failed 的推流对象时连"失败"一起说）
            let failing = enabled.filter { $0.failure != nil }
            let hint = kind != .stream || failing.isEmpty ? ""
                : "\n" + (failing.contains(where: \.failureStopped) ? L("bottom.tip.retryHintStopped") : L("bottom.tip.retryHint"))
            return OutputButtonSummary(title: title, toolTip: tip + hint, severity: worst)
        }
        // 时长：在录 / 在推的路里最长的那一路（同一拍起的几路差不到一秒；推流的 uptime 含重连期，提案 022 默认口径）
        let duration = durationText(live.map(\.uptime).max() ?? 0)
        switch kind {
        case .stream where !live.isEmpty:
            let title = routes.count == 1 ? L("bottom.streamingTime", duration) : L("bottom.streamingTimeMany", duration, live.count, routes.count)
            return OutputButtonSummary(title: title, toolTip: tip, severity: .live)
        case .record where live.count == enabled.count:
            let title = enabled.count > 1 ? L("bottom.recordingTimeMany", duration, enabled.count) : L("bottom.recordingTime", duration)
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
