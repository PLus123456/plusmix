// 设置里的"提醒"一节（W5-L，02 N02 / 04 Q50）：主窗口提醒条的三条各一个开关（没在录 / 推默认关、带分钟数；FTB / Master 过低默认开），即时生效。
import AppKit
import SwiftUI

@MainActor
final class ReminderSettingsModel: ObservableObject {
    @Published var notLiveEnabled: Bool
    @Published var notLiveMinutes: Int
    @Published var ftbEnabled: Bool
    @Published var lowAudioEnabled: Bool
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        let r = controller.settings.reminders
        notLiveEnabled = r.notLiveEnabled
        notLiveMinutes = r.notLiveMinutes
        ftbEnabled = r.ftbEnabled
        lowAudioEnabled = r.lowAudioEnabled
    }
}
