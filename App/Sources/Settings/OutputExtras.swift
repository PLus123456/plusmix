// `OutputSettings.extra`（契约里各输出会话的附加项，自由 JSON）里 App 用到的键，集中在这里免得散落：
//   外部显示：display.number = 显示器编号（NSScreenNumber / CGDirectDisplayID）
//   NDI 发送：ndi.groups = 分组；ndi.conversion 是 W2-D 定的（NDISender.Configuration.Conversion.extraKey）
//   多画面：layout = 布局名（W3-B 的多画面布局，App 只存不解释）
import AppKit
import SwitcherContracts

enum OutputExtras {
    static let displayNumber = "display.number"
    static let ndiGroups = "ndi.groups"
    static let ndiConversion = "ndi.conversion"
    static let multiviewLayout = "layout"

    static let ndiConversions = ["auto", "gpu", "cpu"]

    static func displayNumber(of output: OutputState) -> UInt32? {
        if case .number(let n)? = output.settings.extra[displayNumber], n >= 0, n <= Double(UInt32.max) { return UInt32(n) }
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
