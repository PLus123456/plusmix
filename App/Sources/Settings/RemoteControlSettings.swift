// 设置"远程控制"页（W5-L，01a P3 / 02 X33）：本地 API 与第三方 API 兼容层各"仅本机 / 允许局域网"二选一（代替自由填监听地址），
// 下面只读显示别的机器该连的地址 http://<本机局域网 IP>:<端口>（带"复制"）；允许局域网又没设 token 时黄字提醒（兼容层没有鉴权，允许局域网就提醒）；
// 兼容层的 HTTP 端口可改（原来写死 127.0.0.1 / 8088）。改动走设置窗底部的"应用 / 应用并重起引擎"（与原来的 API 一节同一口径）。
// 本机局域网地址：开着、在跑、不是回环 / 点对点隧道（VPN）、不是 169.254 自分配的 IPv4；默认路由那块网卡排第一（SCDynamicStore 的 PrimaryInterface）。
// 写成独立的几节（RemoteControlSection 等），96 合窗时整节挂进"远程控制"页。
import AppKit
import Darwin
import SwiftUI
import SystemConfiguration

/// 监听范围。
enum ListenScope: String, CaseIterable, Identifiable, Sendable {
    /// 仅本机：127.0.0.1。
    case localOnly
    /// 允许局域网：0.0.0.0（启动参数 / 设置里原来就写了一个具体的本机地址时原样留着）。
    case lan

    var id: String { rawValue }

    init(host: String) { self = Self.isLoopback(host) ? .localOnly : .lan }

    /// 回环地址（空串按"没写 = 127.0.0.1"算）。
    static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h.isEmpty || h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    /// 选了这一档之后的监听地址：仅本机 = 127.0.0.1；允许局域网 = 原来已经是非回环的具体地址就留着，否则 0.0.0.0。
    func host(replacing current: String) -> String {
        switch self {
        case .localOnly: return "127.0.0.1"
        case .lan: return ListenScope(host: current) == .lan ? current.trimmingCharacters(in: .whitespaces) : "0.0.0.0"
        }
    }

    var title: String { L("prefs.remote.scope.\(rawValue)") }
}

/// 本机地址。
enum NetworkAddresses {
    /// 本机的局域网 IPv4，默认路由那块网卡的排第一，其余按网卡出现的顺序。
    static func lanIPv4() -> [String] {
        var found: [(interface: String, ip: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !ip.hasPrefix("169.254."), !found.contains(where: { $0.ip == ip }) else { continue }
            found.append((String(cString: p.pointee.ifa_name), ip))
        }
        let primary = primaryInterface()
        return found.filter { $0.interface == primary }.map(\.ip) + found.filter { $0.interface != primary }.map(\.ip)
    }

    /// 默认路由走的那块网卡（"en0"）；查不到为 nil。
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "PlusMix" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    /// 某个监听地址对别人来说该连哪些主机：回环 → 127.0.0.1；0.0.0.0 → 本机的局域网地址（可能一个都没有）；具体地址 → 它自己。
    static func reachableHosts(listenHost: String) -> [String] {
        let h = listenHost.trimmingCharacters(in: .whitespaces)
        if ListenScope.isLoopback(h) { return ["127.0.0.1"] }
        if h == "0.0.0.0" || h == "::" || h == "*" { return lanIPv4() }
        return [h]
    }
}

/// "复制"按钮：把一行地址放进剪贴板。
enum RemoteAddressCopy {
    @MainActor
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// 一行只读地址 + "复制"。地址整行显示、不截断（LabeledContent 对半分会把端口截成"…"）。
struct AddressRow: View {
    let label: String
    let address: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 12)
            Text(verbatim: address).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).fixedSize()
            Button(L("prefs.remote.copy")) { RemoteAddressCopy.copy(address) }.controlSize(.small)
        }
    }
}

/// 本地 API 与兼容层两节（PreferencesView 里用；改动走窗口底部的"应用 / 应用并重起引擎"）。
struct RemoteControlSection: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Section(L("prefs.remote.title")) {
            Toggle(L("prefs.api.enabled"), isOn: $model.apiEnabled)
            Picker(L("prefs.remote.scope"), selection: Binding(get: { model.apiScope }, set: { model.apiScope = $0 })) {
                ForEach(ListenScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(L("prefs.api.port"), value: $model.apiPort, format: PreferencesModel.plainInteger)
            SecureField(L("prefs.api.token"), text: $model.apiToken)
            addressRows(label: L("prefs.remote.address"), first: model.apiAddress, others: model.apiOtherAddresses, lan: model.apiScope == .lan)
            if let warning = model.apiWarning { Text(warning).font(.caption).foregroundStyle(.yellow) }
            Text(L("prefs.api.hint")).font(.caption).foregroundStyle(.secondary)
        }
        Section(L("prefs.compat.title")) {
            Toggle(L("prefs.compat.enabled"), isOn: $model.compatLayerEnabled)
            Picker(L("prefs.remote.scope"), selection: Binding(get: { model.compatScope }, set: { model.compatScope = $0 })) {
                ForEach(ListenScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(L("prefs.compat.port"), value: $model.compatLayerPort, format: PreferencesModel.plainInteger)
            TextField(L("prefs.compat.httpPort"), value: $model.compatLayerHTTPPort, format: PreferencesModel.plainInteger)
            addressRows(label: L("prefs.remote.compatHTTP"), first: model.compatHTTPAddress, others: [], lan: model.compatScope == .lan)
            if !model.compatTCPAddress.isEmpty { AddressRow(label: L("prefs.remote.compatTCP"), address: model.compatTCPAddress) }
            if let warning = model.compatWarning { Text(warning).font(.caption).foregroundStyle(.yellow) }
            Text(PreferencesModel.compatLegalNotice).font(.caption).foregroundStyle(.secondary)
            Text(L("prefs.compat.pending")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func addressRows(label: String, first: String, others: [String], lan: Bool) -> some View {
        if first.isEmpty {
            Text(L("prefs.remote.noLAN")).font(.caption).foregroundStyle(.secondary)
        } else {
            AddressRow(label: label, address: first)
            if !others.isEmpty { Text(L("prefs.remote.otherAddresses", others.joined(separator: L("prefs.remote.listSeparator")))).font(.caption).foregroundStyle(.secondary) }
            if !lan { Text(L("prefs.remote.localOnlyHint")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
