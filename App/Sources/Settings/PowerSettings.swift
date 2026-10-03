// 设置"性能与电源"页（W5-L，01a P1 / 04 Q47）：两个开关——引擎运行时阻止系统睡眠与 App Nap、阻止显示器休眠（默认都开，即时生效）；
// 下面只读显示机型 / 芯片 / 内存 / GPU（本机信息，不进 Stats）。
import AppKit
import Metal
import SwiftUI

@MainActor
final class PowerSettingsModel: ObservableObject {
    /// 只读的一行"名称：值"。
    struct MachineRow: Identifiable, Equatable {
        var label: String
        var value: String
        var id: String { label }
    }

    @Published var preventSleep: Bool
    @Published var preventDisplaySleep: Bool
    let machineRows: [MachineRow]
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        preventSleep = controller.settings.preventSleepWhileRunning
        preventDisplaySleep = controller.settings.preventDisplaySleepWhileRunning
        machineRows = []
    }
}
