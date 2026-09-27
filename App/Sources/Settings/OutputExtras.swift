// `OutputSettings.extra`（契约里各输出会话的附加项，自由 JSON）里 App 还在用的键，集中在这里免得散落：
//   NDI 发送：ndi.groups = 分组；ndi.conversion 是 W2-D 定的（NDISender.Configuration.Conversion.extraKey）
// 提案 010 / 013 落地后，显示器 ID 与多画面布局都是正式字段（`OutputSettings.display` / `.multiview`），不再走 extra：只读正式字段
// （W3-E3 删了读过渡键 extra["displayID"] 的后备——包的 ExternalDisplaySpec 从 W3-C2 起、契约从 P3 起都不读了）；
// 旧节目文件由 `Show.load` 一次性搬迁，API 直接 addOutput / setOutputSettings 进来的由 reducer 搬（P4）；App 自己不搬（W3-E4 删了设置页里多余的那两处调用）。
import AppKit
import SwitcherContracts

enum OutputExtras {
    static let ndiGroups = "ndi.groups"
    static let ndiConversion = "ndi.conversion"

    static let ndiConversions = ["auto", "gpu", "cpu"]

    /// 外部显示输出的显示器编号（提案 013 的正式字段；nil = 主显示器）。
    static func displayNumber(of output: OutputState) -> UInt32? {
        output.settings.display?.displayID
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
