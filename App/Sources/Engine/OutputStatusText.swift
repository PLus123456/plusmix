// 显示类输出与系统扩展的状态文案（W3-E2；G4 问题单 G4-w3-app2-localize-w3c-app-strings 第 2 条、提案 013）：
// - SwitcherOutputs 里的 `SystemExtensionInstaller.describe` / `ExternalDisplayManager.describe` / `ExternalDisplaySpec.describe` 返回中文，
//   包不该管语言：App 按枚举查表（W3-C3 起包里的 describe 都删了；`.failed` 带的是枚举原因 + 系统给的描述，原因查表、描述附在后面）。
// - 帧数与状态只读 `Stats.display[]`（铁律 4：菜单、状态行、设置页、API、测试读同一个结构），不再直接读
//   `VirtualCameraOutput.countersSnapshot` / `MetalDisplayView.presentedFrames`。
import SwitcherContracts
import SwitcherExternal
import SwitcherVirtualCamera

@MainActor
enum OutputStatusText {
    /// 虚拟摄像头扩展的安装状态。
    static func extensionStatus(_ s: SystemExtensionInstaller.Status) -> String {
        switch s {
        case .unknown: L("aux.extension.unknown")
        case .notInstalled: L("aux.extension.notInstalled")
        case .requesting: L("aux.extension.requesting")
        case .needsUserApproval: L("aux.extension.needsUserApproval")
        case .installed(let v): v.isEmpty ? L("aux.extension.installedNoVersion") : L("aux.extension.installed", v)
        case .uninstalled: L("aux.extension.uninstalled")
        case .needsReboot: L("aux.extension.needsReboot")
        case .failed(let f): L("aux.extension.failed", failureReason(f))
        }
    }

    /// 扩展请求失败的原因（W3-C3：包只给枚举原因 + 系统给的描述）：原因查表，系统描述（系统本地化）附在后面。
    static func failureReason(_ f: SystemExtensionInstaller.Failure) -> String {
        let reason = L("aux.extension.failure.\(f.reason.rawValue)")
        return f.detail.isEmpty ? reason : L("aux.extension.failure.detail", reason, f.detail)
    }

    /// 外部显示窗口的状态（状态变化时的提示用；持续的帧数看 `display(_:)`）。
    static func externalWindow(_ s: ExternalDisplayWindow.Status) -> String {
        switch s {
        case .showing(let id): L("aux.external.showing", id)
        case .waitingForDisplay(let id): L("aux.external.waitingForDisplay", id)
        case .fallbackToMain(let id): L("aux.external.fallbackToMain", id)
        }
    }

    /// `Stats.DisplayEntry.state` → 文案；认不出的原样给。
    static func displayState(_ state: String) -> String {
        Stats.DisplayEntry.states.contains(state) ? L("aux.displayState.\(state)") : state
    }

    /// 一个显示类输出的一行："显示中 · 1234 帧"，有丢帧再加"（丢 5）"。
    static func display(_ e: Stats.DisplayEntry) -> String {
        let base = L("aux.display.line", displayState(e.state), Int(clamping: e.frames))
        return e.dropped > 0 ? base + L("aux.display.dropped", Int(clamping: e.dropped)) : base
    }

    /// NDI 发送一行（输出设置 NDI 页）。enabled = 输出的目标开关；entry = Stats.encoder 里它那一项（state：publishing / idle / unavailable / failed，提案 002 / 019）。
    /// publishing 带接收方数（`connections`，019）；unavailable = SDK 不在（要做的事是装 SDK），failed = SDK 在但 initialize / send_create 失败（要做的事是看日志）——两句分开。
    static func ndi(enabled: Bool, entry: Stats.EncoderEntry?) -> String {
        guard enabled else { return L("ndi.status.disabled") }
        guard let e = entry else { return L("ndi.status.starting") }
        switch e.state {
        case "publishing":
            let base = L("ndi.status.publishing", Int(clamping: e.frames)) + L("ndi.status.connections", Int(clamping: e.connections))
            return e.dropped > 0 ? base + L("ndi.status.dropped", Int(clamping: e.dropped)) : base
        case "unavailable": return L("ndi.status.unavailable")
        case "failed": return L("ndi.status.failed")
        case "idle": return L("ndi.status.starting")
        default: return e.state
        }
    }

    /// 虚拟摄像头输出一行（菜单的状态行 / 设置页）。enabled = 节目里有 enabled 的虚拟摄像头输出；entry = Stats.display[] 里它那一项。
    static func virtualCamera(enabled: Bool, entry: Stats.DisplayEntry?) -> String {
        guard enabled else { return L("aux.virtualCamera.disabled") }
        guard let e = entry else { return L("aux.virtualCamera.starting") }
        switch e.state {
        case "idle": return L("aux.virtualCamera.idle")
        case "waitingExtension": return L("aux.virtualCamera.waitingExtension", Int(clamping: e.undelivered))   // 提案 018：没连上时丢的是 undelivered，dropped 只算连上之后的
        case "publishing": return L("aux.virtualCamera.publishing", Int(clamping: e.frames))
        case "stopped": return L("aux.virtualCamera.stopped")
        default: return display(e)
        }
    }
}
