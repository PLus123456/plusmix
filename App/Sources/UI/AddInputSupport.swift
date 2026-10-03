// 添加输入面板的辅助（W5-K，prompt 97 交付 1，01a G2–G12）：类型的分组 / 图标、权限 / SDK / 驱动横幅、最近文件。
import AppKit
import AVFoundation
import SwitcherContracts
import SwitcherInputs

/// 类型分组（G3）：设备 / 网络 / 屏幕 / 媒体 / 测试。
enum AddInputKindGroup: String, CaseIterable, Identifiable {
    case devices, network, screen, media, test
    var id: String { rawValue }
    var title: String { L("addInput.group.\(rawValue)") }
    var kinds: [AddInputModel.Kind] { AddInputModel.Kind.displayOrder.filter { $0.group == self } }
}

extension AddInputModel.Kind {
    /// 面板左栏与 ▴ / "按类型添加 ▸"菜单的顺序。
    static var displayOrder: [Self] { allCases }

    var group: AddInputKindGroup { .devices }

    /// 系统符号图标。
    var symbolName: String { "questionmark" }
}

/// 页顶横幅（G6）。
struct AddInputBanner: Equatable {
    enum Action: Equatable {
        case openSystemSettings(URL)
        case showHelp(String)
    }
    var title: String
    var message: String
    var action: Action
    var actionTitle: String {
        switch action {
        case .openSystemSettings: L("addInput.banner.openSettings")
        case .showHelp: L("addInput.banner.help")
        }
    }
}

/// 添加面板看的系统状态与外部动作（测试注入假的）。
struct AddInputEnvironment {
    enum PrivacyPane: String {
        case camera = "Privacy_Camera"
        case microphone = "Privacy_Microphone"
        case screenRecording = "Privacy_ScreenCapture"
    }
    var cameraPermission: @MainActor () -> CapturePermission.Status
    var microphonePermission: @MainActor () -> CapturePermission.Status
    var screenRecordingAllowed: @MainActor () -> Bool
    var ndiAvailable: @MainActor () -> Bool
    var decklinkSDKAvailable: @MainActor () -> Bool
    var decklinkDriverPresent: @MainActor () -> Bool
    var openURL: @MainActor (URL) -> Void
    var openHelp: @MainActor (String) -> Void

    static func privacyURL(_ pane: PrivacyPane) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    }

    static var live: AddInputEnvironment {
        AddInputEnvironment(cameraPermission: { .authorized }, microphonePermission: { .authorized }, screenRecordingAllowed: { true },
                            ndiAvailable: { true }, decklinkSDKAvailable: { true }, decklinkDriverPresent: { true },
                            openURL: { _ in }, openHelp: { _ in })
    }
}

/// 最近文件的一项（G11）。
struct AddInputRecentFile: Identifiable, Hashable {
    var path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var exists: Bool
}
