// 设置里的"提醒"一节（W5-L，02 N02 / 04 Q50）：主窗口提醒条的三条各一个开关（没在录 / 推默认关、带分钟数；FTB / Master 过低默认开），即时生效。
import AppKit
import SwiftUI

@MainActor
final class ReminderSettingsModel: ObservableObject {
    @Published var notLiveEnabled: Bool { didSet { if notLiveEnabled != oldValue { commit() } } }
    @Published var notLiveMinutes: Int { didSet { if notLiveMinutes != oldValue { commit() } } }
    @Published var ftbEnabled: Bool { didSet { if ftbEnabled != oldValue { commit() } } }
    @Published var lowAudioEnabled: Bool { didSet { if lowAudioEnabled != oldValue { commit() } } }
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        let r = controller.settings.reminders
        notLiveEnabled = r.notLiveEnabled
        notLiveMinutes = r.notLiveMinutes
        ftbEnabled = r.ftbEnabled
        lowAudioEnabled = r.lowAudioEnabled
    }

    /// 即时生效：只写提醒的四个键，主窗口的提醒马上按新设置算。
    private func commit() {
        let reminders = ReminderSettings(notLiveEnabled: notLiveEnabled, notLiveMinutes: ReminderSettings.clampMinutes(notLiveMinutes),
                                         ftbEnabled: ftbEnabled, lowAudioEnabled: lowAudioEnabled)
        controller.updateSettings({ $0.reminders = reminders }, saving: { $0.saveReminders(to: $1) })
    }
}

struct ReminderSettingsSection: View {
    @ObservedObject var model: ReminderSettingsModel

    var body: some View {
        Section(L("prefs.reminder.title")) {
            Toggle(L("prefs.reminder.notLive"), isOn: $model.notLiveEnabled)
            Stepper(value: $model.notLiveMinutes, in: ReminderSettings.notLiveMinutesRange) {
                Text(L("prefs.reminder.notLiveMinutes", model.notLiveMinutes))
            }
            .disabled(!model.notLiveEnabled)
            Toggle(L("prefs.reminder.ftb", Int(ReminderTracker.ftbSeconds)), isOn: $model.ftbEnabled)
            Toggle(L("prefs.reminder.lowAudio", Int(ReminderTracker.lowAudioSeconds), Int(ReminderTracker.lowAudioThresholdDb)), isOn: $model.lowAudioEnabled)
            Text(L("prefs.reminder.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
