// 设置 › Tally（W5-L，01a P2 / 02 X32 / 04 Q46）：一个开关（默认关；打开 = App 起只读 tally 流、听局域网）、端口（默认 API 端口 + 1）、
// 只读地址 WS / HTTP 两行带"复制"、连接数（WS 订阅数，每秒刷一次）。即时生效：开 = 起 TallyServer、关 = 停，不用重起引擎。
import AppKit
import SwiftUI

@MainActor
final class TallySettingsModel: ObservableObject {
    @Published var enabled: Bool
    @Published var port: Int
    /// 现在连着的 WS 客户端数。
    @Published private(set) var connections = 0
    /// 只读地址两行（没开为空串）。
    @Published private(set) var wsAddress = ""
    @Published private(set) var httpAddress = ""
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        enabled = controller.settings.tallyEnabled
        port = controller.settings.effectiveTallyPort
    }
}
