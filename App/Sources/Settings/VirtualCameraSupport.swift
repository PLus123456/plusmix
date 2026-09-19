// 虚拟摄像头（CMIO Camera Extension，W3-C）的安装状态与安装请求：OSSystemExtensionManager 的属性查询 / 激活请求。
// 扩展本体、签名、XPC 送帧都在 W3-C；这里只问系统"装没装"并能发一次激活请求，扩展不在 App 包里时报错文案照实显示
// （未签名 / 无 Team ID 时是 BLOCKED-签名）。扩展的 bundle ID 从 Info.plist 的 SwitcherCameraExtensionBundleID 读，没有就按
// <App bundle ID>.camera 猜（W3-C 定了正式值后写进 Info.plist 即可）。
import Foundation
import SystemExtensions

@MainActor
final class VirtualCameraSupport: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionBundleID: String = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "SwitcherCameraExtensionBundleID") as? String, !id.isEmpty { return id }
        return (Bundle.main.bundleIdentifier ?? "com.example.switcher") + ".camera"
    }()

    enum Status: Equatable {
        case unknown
        case checking
        case installed(version: String, enabled: Bool)
        case notInstalled
        case needsApproval
        case failed(String)

        /// 给人看的文案。
        @MainActor var text: String {
            switch self {
            case .unknown: L("vcam.status.unknown")
            case .checking: L("vcam.status.checking")
            case .installed(let v, let enabled): enabled ? L("vcam.status.installed", v) : L("vcam.status.installedDisabled", v)
            case .notInstalled: L("vcam.status.notInstalled")
            case .needsApproval: L("vcam.status.needsApproval")
            case .failed(let m): L("vcam.status.failed", m)
            }
        }
    }

    private(set) var status: Status = .unknown
    var onChange: ((Status) -> Void)?
    private var pending: [ObjectIdentifier: (kind: String, request: OSSystemExtensionRequest)] = [:]

    /// 问系统装没装。
    func refresh() {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.extensionBundleID, queue: .main)
        submit(request, kind: "properties")
        set(.checking)
    }

    /// 发激活请求（系统会弹"允许"对话框；扩展不在包里会失败）。
    func install() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionBundleID, queue: .main)
        submit(request, kind: "activation")
        set(.checking)
    }

    /// 卸载。
    func uninstall() {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionBundleID, queue: .main)
        submit(request, kind: "deactivation")
        set(.checking)
    }

    private func submit(_ request: OSSystemExtensionRequest, kind: String) {
        request.delegate = self
        pending[ObjectIdentifier(request)] = (kind, request)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func set(_ s: Status) {
        status = s
        onChange?(s)
    }

    // MARK: OSSystemExtensionRequestDelegate（queue 是 main，回调已在主线程；只把 Sendable 的值带进 MainActor）

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { self.set(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let id = ObjectIdentifier(request)
        let completed = result == .completed
        MainActor.assumeIsolated {
            let kind = self.pending.removeValue(forKey: id)?.kind
            if kind == "deactivation" { self.set(.notInstalled); return }
            self.set(.installed(version: "", enabled: completed))
            self.refresh()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let id = ObjectIdentifier(request)
        let ns = error as NSError
        let notFound = ns.domain == OSSystemExtensionErrorDomain && ns.code == OSSystemExtensionError.extensionNotFound.rawValue
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.pending.removeValue(forKey: id)
            self.set(notFound ? .notInstalled : .failed(message))
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let id = ObjectIdentifier(request)
        let found = properties.first.map { (version: $0.bundleShortVersion, enabled: $0.isEnabled) }
        MainActor.assumeIsolated {
            self.pending.removeValue(forKey: id)
            guard let found else { self.set(.notInstalled); return }
            self.set(.installed(version: found.version, enabled: found.enabled))
        }
    }
}
