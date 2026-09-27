// 摄像头授权探针（W4-A soak 的前置检查）：`camera-auth status` 只查不弹框；`camera-auth request` 请求一次并等回答（最多 120 s）。
// 输出一行 `video=<authorized|denied|restricted|notDetermined>`。授权归属于"负责进程"（在终端里跑就是终端 App），
// 所以 soak 开跑前在同一个终端里问一次：人在键盘前点允许，8 小时里 headless 的 CameraInput 就不会停在"等授权"上。
import AVFoundation
import Foundation

func name(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "status"
if mode == "request", AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
    let done = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in done.signal() }
    _ = done.wait(timeout: .now() + 120)
}
print("video=\(name(AVCaptureDevice.authorizationStatus(for: .video)))")
