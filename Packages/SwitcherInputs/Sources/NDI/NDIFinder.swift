import CSwitcherNDI
import Foundation
import Synchronization

/// 网络上的一个 NDI 源。`name` 是 "机器名 (源名)"，也就是 `InputSource.ndi(sourceName:)` 存的东西；`url` 是当前地址（会变）。
public struct NDISource: Hashable, Sendable, Codable {
    public var name: String
    public var url: String?
    public init(name: String, url: String? = nil) {
        self.name = name
        self.url = url
    }
}

/// NDI 源发现（NDIlib_find）。App 的 Add Input 列源用它；`NDIInput` 内部也用它找源、盯源换地址。
/// 线程：一个实例只在一条线程上用（SDK 要求 get_current_sources 不并发）。
public final class NDIFinder: @unchecked Sendable {
    private let handle: OpaquePointer

    /// - Parameters:
    ///   - showLocalSources: 本机的源也列出来（回环测试需要）。
    ///   - groups: NDI 分组（逗号分隔），nil = 默认组。
    ///   - extraIPs: 额外要问的机器地址（逗号分隔）。
    public init(showLocalSources: Bool = true, groups: String? = nil, extraIPs: String? = nil) throws {
        guard SwitcherNDIInfo.isSDKAvailable else { throw NDIInputError.sdkUnavailable }
        guard sw_ndi_initialize() != 0 else { throw NDIInputError.initializeFailed }
        let h: OpaquePointer? = groups.withOptionalCString { g in
            extraIPs.withOptionalCString { e in sw_ndi_finder_create(showLocalSources ? 1 : 0, g, e) }
        }
        guard let h else { throw NDIInputError.finderCreateFailed }
        handle = h
    }

    deinit { sw_ndi_finder_destroy(handle) }

    /// 等源列表变化，最多 timeoutMs；变了返回 true。
    public func waitForChange(timeoutMs: UInt32) -> Bool { sw_ndi_finder_wait(handle, timeoutMs) != 0 }

    /// 当前源列表（不等待；字串已拷出）。
    public var currentSources: [NDISource] {
        var buf = [sw_ndi_source](repeating: sw_ndi_source(name: nil, url: nil), count: 64)
        var n = Int(sw_ndi_finder_sources(handle, &buf, Int32(buf.count)))
        if n > buf.count {
            buf = [sw_ndi_source](repeating: sw_ndi_source(name: nil, url: nil), count: n)
            n = Int(sw_ndi_finder_sources(handle, &buf, Int32(buf.count)))
        }
        return (0..<min(n, buf.count)).compactMap { i in
            guard let p = buf[i].name else { return nil }
            return NDISource(name: String(cString: p), url: buf[i].url.map { String(cString: $0) })
        }
    }

    /// 找名字完全相同的源。
    public func source(named name: String) -> NDISource? { currentSources.first { $0.name == name } }

    /// 一次性发现：建发现器、等最多 timeoutMs 让 mDNS 回答、返回列表。
    public static func discover(timeoutMs: UInt32 = 1500, showLocalSources: Bool = true) throws -> [NDISource] {
        let f = try NDIFinder(showLocalSources: showLocalSources)
        _ = f.waitForChange(timeoutMs: timeoutMs)
        return f.currentSources
    }
}

extension Optional where Wrapped == String {
    /// 可选字串 → 可为 NULL 的 C 字串。
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let s): return s.withCString { body($0) }
        case .none: return body(nil)
        }
    }
}
