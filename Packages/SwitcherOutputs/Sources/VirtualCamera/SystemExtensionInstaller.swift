import Foundation
import SystemExtensions

/// 系统扩展的安装 / 激活 / 卸载（OSSystemExtensionRequest）。状态给 UI 提示；回调都在主线程。
///
/// 要求（落地方案 §6）：App 用 Apple 签发的证书签名并带 Team ID、带 `com.apple.developer.system-extension.install` 权限、
/// 从 /Applications 运行；扩展嵌在 App 的 Contents/Library/SystemExtensions/。开发期没有 Team ID 只能编译，激活会失败（BLOCKED-签名）。
/// `systemextensionsctl developer on`（跳过 /Applications 要求）在 macOS 26.6.2 上仍要求关 SIP：探针实测它直接打印
/// "cannot be used if System Integrity Protection is enabled"。替代验证路径见 `developerModeHint`。
public final class SystemExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    /// 状态。
    public enum Status: Hashable, Sendable {
        case unknown
        case notInstalled
        /// 请求已发出，等系统 / 用户。
        case requesting
        /// 系统设置里等用户批准（隐私与安全性 → 允许）。
        case needsUserApproval
        case installed(version: String)
        /// 卸载完成。
        case uninstalled
        /// 要重启才生效。
        case needsReboot
        case failed(String)
    }

    public let extensionIdentifier: String
    public private(set) var status: Status = .unknown
    /// 状态变化（主线程）。
    public var onStatusChange: ((Status) -> Void)?
    private var current: OSSystemExtensionRequest?

    public init(extensionIdentifier: String = VirtualCameraConstants.extensionBundleIdentifier) {
        self.extensionIdentifier = extensionIdentifier
        super.init()
    }

    /// 没有 Team ID / 没关 SIP 时怎么验证扩展：
    public static let developerModeHint = """
        systemextensionsctl developer on 在 macOS 26 上要求关闭 SIP（恢复模式 csrutil disable），开发机不建议。替代路径：
        1）用 Apple Development 证书 + Team ID 签（DEVELOPMENT_TEAM=XXXXXXXXXX make gen），把 Switcher.app 拷到 /Applications 再启动，正常走激活；
        2）没有证书时只验证扩展本体：xcodebuild 编出的 .systemextension 可用 codesign -dvv 看签名与权限，扩展的 provider 逻辑在 VirtualCameraTests 里单测。
        """

    /// 激活（安装）扩展。
    public func activate() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        current = request
        deactivating = false
        set(.requesting)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// 卸载扩展。
    public func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        current = request
        deactivating = true
        set(.requesting)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// 查询是否已装（macOS 12+ 的属性请求）。
    public func refresh() {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        current = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func set(_ s: Status) {
        status = s
        onStatusChange?(s)
    }

    /// 请求结果 → 状态（纯映射，测试用）。
    static func status(for result: OSSystemExtensionRequest.Result, version: String) -> Status {
        switch result {
        case .completed: .installed(version: version)
        case .willCompleteAfterReboot: .needsReboot
        @unknown default: .installed(version: version)
        }
    }

    /// 错误 → 状态文案（纯映射，测试用）。
    static func status(for error: any Error) -> Status {
        let ns = error as NSError
        if ns.domain == OSSystemExtensionErrorDomain {
            switch OSSystemExtensionError.Code(rawValue: ns.code) {
            case .extensionNotFound: return .failed("App 里没有扩展（\(ns.localizedDescription)）：需要带 Team ID 签名并嵌入 Contents/Library/SystemExtensions；BLOCKED-签名")
            case .codeSignatureInvalid, .validationFailed, .missingEntitlement, .unsupportedParentBundleLocation, .forbiddenBySystemPolicy:
                return .failed("签名 / 权限 / 位置不满足（\(ns.localizedDescription)）：见 SystemExtensionInstaller.developerModeHint；BLOCKED-签名")
            case .requestCanceled: return .failed("请求被取消")
            case .requestSuperseded: return .failed("请求被更新的请求替代")
            case .authorizationRequired: return .needsUserApproval
            default: break
            }
        }
        return .failed("\(ns.localizedDescription)（\(ns.domain) \(ns.code)）")
    }

    // MARK: OSSystemExtensionRequestDelegate（主线程队列）

    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                        withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        set(.needsUserApproval)
    }

    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if deactivating {
            deactivating = false
            set(.uninstalled)
        } else {
            set(Self.status(for: result, version: lastKnownVersion))
        }
        current = nil
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        set(Self.status(for: error))
        current = nil
    }

    public func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        if let p = properties.first(where: { $0.isEnabled }) ?? properties.first {
            lastKnownVersion = p.bundleShortVersion
            set(p.isEnabled ? .installed(version: p.bundleShortVersion) : (p.isAwaitingUserApproval ? .needsUserApproval : .notInstalled))
        } else {
            set(.notInstalled)
        }
        current = nil
    }

    private var lastKnownVersion = ""
    private var deactivating = false
}

extension SystemExtensionInstaller {
    /// 状态文案。
    public static func describe(_ s: Status) -> String {
        switch s {
        case .unknown: "未知"
        case .notInstalled: "未安装"
        case .requesting: "请求中…"
        case .needsUserApproval: "等待在「系统设置 → 隐私与安全性」里允许"
        case .installed(let v): "已安装（\(v)）"
        case .uninstalled: "已卸载"
        case .needsReboot: "重启后生效"
        case .failed(let m): "失败：\(m)"
        }
    }
}
