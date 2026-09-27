import Foundation
import SystemExtensions

/// 系统扩展的安装 / 激活 / 卸载（OSSystemExtensionRequest）。状态给 UI 提示；回调都在主线程。
/// 包只给枚举：状态与失败原因的文字由组装方查表（App 的 `OutputStatusText.extensionStatus`），包里不拼文案（W3-C3）。
///
/// 要求（落地方案 §6）：App 用 Apple 签发的证书签名并带 Team ID、带 `com.apple.developer.system-extension.install` 权限、
/// 从 /Applications 运行；扩展嵌在 App 的 Contents/Library/SystemExtensions/。开发期没有 Team ID 只能编译，激活会失败（BLOCKED-签名；
/// 探针：未签名的宿主回 OSSystemExtensionErrorDomain 2 = missingEntitlement → `.requirementsNotMet`）。
/// `systemextensionsctl developer on`（跳过 /Applications 要求）在 macOS 26.6.2 上仍要求关 SIP：探针实测它直接打印
/// "cannot be used if System Integrity Protection is enabled"，开发机不建议。没有 Team ID / 不关 SIP 时的验证路径：
/// 1）用 Apple Development 证书 + Team ID 签（`DEVELOPMENT_TEAM=XXXXXXXXXX make gen`），把 Switcher.app 拷到 /Applications 再启动，正常走激活；
/// 2）没有证书时只验证扩展本体：xcodebuild 编出的 .systemextension 用 `codesign -dvv` 看签名与权限，主程序侧的记账在 VirtualCameraTests 里用假 sink 测。
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
        /// 请求失败：原因（枚举）+ 系统给的诊断。
        case failed(Failure)
    }

    /// 请求失败（W3-C3：以前是包拼好的中文句子）。组装方按 `reason` 查表出文字；`detail` 是系统给的描述（NSError.localizedDescription，
    /// 系统按用户语言本地化），可以原样附在后面；`domain` / `code` 给日志。
    public struct Failure: Hashable, Sendable {
        /// 按 OSSystemExtensionError 的码归的类。
        public enum Reason: String, Hashable, Sendable, CaseIterable {
            /// App 里没有这个扩展（没嵌进 Contents/Library/SystemExtensions，或没带 Team ID 签名）：BLOCKED-签名。
            case extensionNotFound
            /// 签名 / 权限 / 位置 / 系统策略不满足（codeSignatureInvalid、validationFailed、missingEntitlement、
            /// unsupportedParentBundleLocation = 不在 /Applications、forbiddenBySystemPolicy）：BLOCKED-签名。
            case requirementsNotMet
            /// 请求被取消。
            case canceled
            /// 请求被更新的请求替代。
            case superseded
            /// 其他（扩展包本身有问题、未知码、别的错误域）：看 domain / code / detail。
            case other
        }

        public var reason: Reason
        public var domain: String
        public var code: Int
        public var detail: String

        public init(reason: Reason, domain: String, code: Int, detail: String) {
            self.reason = reason
            self.domain = domain
            self.code = code
            self.detail = detail
        }

        /// 签名那一类（开发期没有 Team ID / 不在 /Applications 时的常态，BLOCKED-签名）。
        public var isSigningBlocked: Bool { reason == .extensionNotFound || reason == .requirementsNotMet }
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

    /// 错误 → 状态（纯映射，测试用）：按错误码归类，系统给的描述原样带着。
    static func status(for error: any Error) -> Status {
        let ns = error as NSError
        var reason = Failure.Reason.other
        if ns.domain == OSSystemExtensionErrorDomain {
            switch OSSystemExtensionError.Code(rawValue: ns.code) {
            case .extensionNotFound: reason = .extensionNotFound
            case .codeSignatureInvalid, .validationFailed, .missingEntitlement, .unsupportedParentBundleLocation, .forbiddenBySystemPolicy:
                reason = .requirementsNotMet
            case .requestCanceled: reason = .canceled
            case .requestSuperseded: reason = .superseded
            case .authorizationRequired: return .needsUserApproval
            default: break
            }
        }
        return .failed(Failure(reason: reason, domain: ns.domain, code: ns.code, detail: ns.localizedDescription))
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
