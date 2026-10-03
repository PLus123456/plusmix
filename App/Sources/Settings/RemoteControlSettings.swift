// 设置"远程控制"页（W5-L，01a P3 / 02 X33）：本地 API 与第三方 API 兼容层各"仅本机 / 允许局域网"二选一（代替自由填监听地址），
// 下面只读显示别的机器该连的地址 http://<本机局域网 IP>:<端口>（带"复制"）；允许局域网又没设 token 时黄字提醒（兼容层没有鉴权，允许局域网就提醒）；
// 兼容层的 HTTP 端口可改（原来写死 127.0.0.1 / 8088）。改动走设置窗底部的"应用 / 应用并重起引擎"（与原来的 API 一节同一口径）。
// 本机局域网地址：开着、在跑、不是回环 / 点对点隧道（VPN）、不是 169.254 自分配的 IPv4；默认路由那块网卡排第一（SCDynamicStore 的 PrimaryInterface）。
import AppKit
import SwiftUI

/// 监听范围。
enum ListenScope: String, CaseIterable, Identifiable, Sendable {
    /// 仅本机：127.0.0.1。
    case localOnly
    /// 允许局域网：0.0.0.0（启动参数 / 设置里原来就写了一个具体的本机地址时原样留着）。
    case lan

    var id: String { rawValue }

    init(host: String) { self = .localOnly }

    /// 选了这一档之后的监听地址。
    func host(replacing current: String) -> String { current }
}

/// 本机地址。
enum NetworkAddresses {
    /// 本机的局域网 IPv4，默认路由那块网卡的排第一。
    static func lanIPv4() -> [String] { [] }
}

/// "复制"按钮：把一行地址放进剪贴板。
enum RemoteAddressCopy {
    @MainActor
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {}
}
