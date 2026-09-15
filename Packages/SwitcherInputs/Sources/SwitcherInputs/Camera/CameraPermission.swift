@preconcurrency import AVFoundation

/// 摄像头 / 麦克风权限（S6）。
public enum CapturePermission {
    public enum Status: String, Sendable {
        case authorized, notDetermined, denied, restricted
        /// 系统没有弹提示就拒了（本进程 / 责任进程的 Info.plist 没有用途说明；命令行工具从 Claude / 脚本里起的时候就是这样）。
        case deniedWithoutPrompt
    }

    /// 当前状态（不弹提示）。
    public static func status(for mediaType: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    /// 给用户看的文案。`process` 是"本程序"的叫法。
    public static func message(for status: Status, mediaType: AVMediaType) -> String {
        let what = mediaType == .video ? "摄像头" : "麦克风"
        let pane = mediaType == .video ? "摄像头" : "麦克风"
        switch status {
        case .authorized: return ""
        case .notDetermined: return "\(what)权限尚未授权：等待系统提示，允许后会自动恢复。"
        case .denied: return "\(what)权限被拒。打开 系统设置 › 隐私与安全性 › \(pane)，允许本程序后会自动恢复，不用重启。"
        case .restricted: return "\(what)权限被系统策略限制（家长控制 / MDM），本程序无法使用\(what)。"
        case .deniedWithoutPrompt:
            return "\(what)权限被拒，且系统没有弹出授权提示：本进程（或启动它的程序）的 Info.plist 没有\(what)用途说明，"
                + "从终端或带用途说明的 .app 启动，在 系统设置 › 隐私与安全性 › \(pane) 允许后会自动恢复。"
        }
    }
}
