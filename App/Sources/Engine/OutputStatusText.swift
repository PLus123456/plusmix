// 显示类输出与系统扩展的状态文案（W3-E2；G4 问题单 G4-w3-app2-localize-w3c-app-strings 第 2 条、提案 013）：
// - SwitcherOutputs 里的 `SystemExtensionInstaller.describe` / `ExternalDisplayManager.describe` / `ExternalDisplaySpec.describe` 返回中文，
//   包不该管语言：App 按枚举查表（`.failed(String)` 带的原因是包给的诊断文字，原样附在后面）。
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
        case .failed(let m): L("aux.extension.failed", m)
        }
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

    /// 虚拟摄像头输出一行（菜单的状态行 / 设置页）。enabled = 节目里有 enabled 的虚拟摄像头输出；entry = Stats.display[] 里它那一项。
    static func virtualCamera(enabled: Bool, entry: Stats.DisplayEntry?) -> String {
        guard enabled else { return L("aux.virtualCamera.disabled") }
        guard let e = entry else { return L("aux.virtualCamera.starting") }
        switch e.state {
        case "idle": return L("aux.virtualCamera.idle")
        case "waitingExtension": return L("aux.virtualCamera.waitingExtension", Int(clamping: e.dropped))
        case "publishing": return L("aux.virtualCamera.publishing", Int(clamping: e.frames))
        case "stopped": return L("aux.virtualCamera.stopped")
        default: return display(e)
        }
    }
}
