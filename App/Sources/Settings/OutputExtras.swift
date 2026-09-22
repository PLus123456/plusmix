// `OutputSettings.extra`（契约里各输出会话的附加项，自由 JSON）里 App 还在用的键，集中在这里免得散落：
//   NDI 发送：ndi.groups = 分组；ndi.conversion 是 W2-D 定的（NDISender.Configuration.Conversion.extraKey）
// 提案 010 / 013 落地后，显示器 ID 与多画面布局都是正式字段（`OutputSettings.display` / `.multiview`），不再走 extra：
// 读的时候正式字段优先、过渡键作后备（保留一个版本），写的时候只写正式字段；旧节目文件由 `Show.load` 一次性搬迁。
import AppKit
import SwitcherContracts
import SwitcherExternal

enum OutputExtras {
    static let ndiGroups = "ndi.groups"
    static let ndiConversion = "ndi.conversion"

    static let ndiConversions = ["auto", "gpu", "cpu"]

    /// 外部显示输出的显示器编号（提案 013 的正式字段；过渡键 `extra["displayID"]` 作后备）。
    static func displayNumber(of output: OutputState) -> UInt32? {
        if let id = output.settings.display?.displayID { return id }
        if case .number(let n)? = output.settings.extra[ExternalDisplaySpec.displayIDKey], n >= 0, n <= Double(UInt32.max) { return UInt32(n) }
        return nil
    }

    static func string(_ output: OutputState, _ key: String) -> String? {
        if case .string(let s)? = output.settings.extra[key] { return s }
        return nil
    }
}

extension NSScreen {
    /// 显示器编号（CGDirectDisplayID；deviceDescription 的 NSScreenNumber）。
    var displayNumber: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 按编号找屏。
    static func screen(number: UInt32) -> NSScreen? { screens.first { $0.displayNumber == number } }

    /// 给人看的名字："内建显示器（3024×1964）"。
    var displayTitle: String { L("screen.title", localizedName, Int(frame.width), Int(frame.height)) }
}

extension OutputSource {
    /// 给人看的名字。
    @MainActor
    func title(in state: MixerState) -> String {
        switch self {
        case .program: L("source.program")
        case .preview: L("source.preview")
        case .multiview: L("source.multiview")
        case .input(let n): L("source.input", n, state.input(n)?.name ?? "")
        }
    }
}
