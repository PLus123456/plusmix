// 主窗口里的提醒（W5-L，02 N02 / 04 Q50）：志愿者最常见的事故"忘了开录""FTB 忘了关""话筒没开"，在主窗口里提醒就能防住。
// 只在主窗口里（状态行的提醒条 + PGM 标题条的 FTB 色块），不叠进多画面（要渲染器支持，走提案）、不改契约。三条，每条可在设置里关：
//   - 没在录 / 推：录制和推流都没开、引擎跑了 n 分钟（从引擎起或最后一路停下那一刻算；默认关，可开）；
//   - FTB 开着：满 10 秒（正常的淡出淡入不打扰）；
//   - Master 电平过低：有进 Master 的声源时，Master 峰值持续 30 秒低于 −50 dBFS（读 1 Hz 的 Stats.audio.meters，铁律 4）。
// ReminderTracker 是纯逻辑（时间由调用方给），MainWindowController 每个快照 / 每行 Stats / 每秒一次喂它。
import Foundation
import SwitcherContracts

/// 提醒的设置（本机偏好，AppSettings.reminders）。
struct ReminderSettings: Equatable, Sendable {
    /// 没在录 / 推的提醒（默认关）。
    var notLiveEnabled = false
    /// 引擎跑了几分钟还没在录 / 推就提醒。
    var notLiveMinutes = 5
    /// FTB 开着满 10 秒（默认开）。
    var ftbEnabled = true
    /// Master 电平持续过低（默认开）。
    var lowAudioEnabled = true

    static let notLiveMinutesRange = 1...120
    static func clampMinutes(_ m: Int) -> Int { min(max(m, notLiveMinutesRange.lowerBound), notLiveMinutesRange.upperBound) }
}

/// 一条提醒。
enum Reminder: String, CaseIterable, Sendable {
    case notLive, ftb, lowAudio
}

/// 三条提醒的计时（纯逻辑）。
struct ReminderTracker {
    /// FTB 开着多久才提醒（秒）。
    static let ftbSeconds: Double = 10
    /// Master 低于门限多久才提醒（秒）。
    static let lowAudioSeconds: Double = 30
    /// Master 的门限（dBFS，峰值取左右声道大的那个）。
    static let lowAudioThresholdDb: Double = -50

    private var running = false
    /// 录制 / 推流都没开从什么时候算起（引擎起、或最后一路停下的那一刻）；有一路开着为 nil。
    private var notLiveSince: Double?
    /// FTB 从什么时候开着；关着为 nil。
    private var ftbSince: Double?
    /// Master 从什么时候低于门限；不低 / 没法判为 nil。
    private var lowSince: Double?
    /// 快照里声音进 Master 的输入（送 Master 且没静音）。
    private var masterRouted: Set<Int> = []

    mutating func engineStarted(at now: Double) {
        running = true
        notLiveSince = now
        ftbSince = nil
        lowSince = nil
    }

    mutating func engineStopped() {
        running = false
        notLiveSince = nil
        ftbSince = nil
        lowSince = nil
    }

    /// 快照：录制 / 推流开没开（目标开关，起不来的也算开着——那是另一种提示）、FTB、哪几路的声音进 Master。
    mutating func update(state: MixerState, now: Double) {
        let live = state.outputs.contains { ($0.kind == .record || $0.kind == .stream) && $0.enabled }
        if live { notLiveSince = nil } else if notLiveSince == nil { notLiveSince = now }
        if state.ftb.on { if ftbSince == nil { ftbSince = now } } else { ftbSince = nil }
        masterRouted = Set(state.inputs.filter { $0.settings.audio.routing.master && !$0.settings.audio.muted }.map(\.number))
    }

    /// 1 Hz 的 Stats：Master 峰值。只在"有一路带声音的输入（表读数里有它）、送 Master、没静音"时判——纯画面的节目、都静音了不算话筒没开。
    mutating func update(stats: Stats, now: Double) {
        let audible = stats.audio.meters.inputs.keys.contains { masterRouted.contains($0) }
        guard audible, let master = stats.audio.meters.buses.first(where: { $0.bus == Bus.master.name }), let peak = master.peakDb.max() else {
            lowSince = nil
            return
        }
        if peak < Self.lowAudioThresholdDb {
            if lowSince == nil { lowSince = now }
        } else {
            lowSince = nil
        }
    }

    /// 这一刻该显示的提醒（按 Reminder.allCases 的顺序）。
    func active(now: Double, settings: ReminderSettings) -> [Reminder] {
        guard running else { return [] }
        var out: [Reminder] = []
        if settings.notLiveEnabled, let since = notLiveSince, now - since >= Double(settings.notLiveMinutes) * 60 { out.append(.notLive) }
        if settings.ftbEnabled, let since = ftbSince, now - since >= Self.ftbSeconds { out.append(.ftb) }
        if settings.lowAudioEnabled, let since = lowSince, now - since >= Self.lowAudioSeconds { out.append(.lowAudio) }
        return out
    }
}

extension Reminder {
    /// 提醒条上的一句。
    func text(settings: ReminderSettings) -> String {
        switch self {
        case .notLive: L("reminder.notLive", settings.notLiveMinutes)
        case .ftb: L("reminder.ftb")
        case .lowAudio: L("reminder.lowAudio", Int(ReminderTracker.lowAudioSeconds), Int(ReminderTracker.lowAudioThresholdDb))
        }
    }
}
