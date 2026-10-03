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

    mutating func engineStarted(at now: Double) {}
    mutating func engineStopped() {}
    mutating func update(state: MixerState, now: Double) {}
    mutating func update(stats: Stats, now: Double) {}

    /// 这一刻该显示的提醒（按 Reminder.allCases 的顺序）。
    func active(now: Double, settings: ReminderSettings) -> [Reminder] { [] }
}
