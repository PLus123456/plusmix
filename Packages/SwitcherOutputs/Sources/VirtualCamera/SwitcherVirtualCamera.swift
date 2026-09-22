// SwitcherVirtualCamera —— 虚拟摄像头桥（W3-C，设计方案 §8 虚拟摄像头行）。
//
// 扩展本体（CMIO Camera Extension，CMIOExtension API）在仓库根 CameraExtension/，作为 App 的系统扩展 target 嵌在
// Switcher.app/Contents/Library/SystemExtensions/ 里。它给系统一个摄像头设备，带两条流：source stream（FaceTime / QuickTime 读）
// 和 sink stream（本 App 写）。主程序这边：
// - `VirtualCameraOutput`：PGM 帧的消费者。自己的线程 + 有界队列；把 NV12 IOSurface 包成 CMSampleBuffer（PTS = 拍点时刻，
//   帧率跟节目）经 CoreMediaIO 客户端 API 送进 sink stream（`CMIOSinkStreamClient`）。找不到设备（扩展没装 / 没激活）就每秒重试。
// - `SystemExtensionInstaller`：OSSystemExtensionRequest 的激活 / 卸载 / 属性查询，状态给 UI 提示。
// Shared/ 里的常量（设备名 / UID / 扩展 bundle ID）同时编进扩展 target。
// 签名：系统扩展必须由 Apple 签发的证书签名并带 Team ID（project.yml 的 DEVELOPMENT_TEAM）；没有就只能编译，激活 BLOCKED-签名。
import SwitcherContracts

/// 模块版本 = 契约版本。
public enum SwitcherVirtualCameraInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
}
