// 主程序（SwitcherVirtualCamera）和扩展（CameraExtension target，project.yml 按路径把本目录编进去）共用的常量。只放字面量，不 import 本仓库的包。
import Foundation

/// 虚拟摄像头的标识。
public enum VirtualCameraConstants {
    /// 设备名（FaceTime / QuickTime 的摄像头列表里显示的名字）。
    public static let deviceName = "Switcher"
    /// 型号。
    public static let deviceModel = "Switcher Virtual Camera"
    /// 设备 UID（主程序按它找设备）。
    public static let deviceUID = "com.plusmix.switcher.virtual-camera.device"
    /// 给其他 App 读的流（扩展的 source stream）。设备 / 流名是系统里给人看的字，用 ASCII（W3-C3：包里不写中文字面量）。
    public static let sourceStreamName = "Switcher Program"
    public static let sourceStreamUID = "com.plusmix.switcher.virtual-camera.source"
    /// 主程序写进来的流（扩展的 sink stream）。
    public static let sinkStreamName = "Switcher Program Sink"
    public static let sinkStreamUID = "com.plusmix.switcher.virtual-camera.sink"
    /// 扩展的 bundle ID（= 主程序 bundle ID + ".camera-extension"；正式 bundle ID 由 W4-B 定，两处一起改）。
    public static let extensionBundleIdentifier = "com.plusmix.switcher.camera-extension"
    /// 允许往 sink 写的 App 的签名 ID 前缀（扩展按 client.signingID 校验）。
    public static let allowedClientSigningIDPrefix = "com.plusmix.switcher"
    /// 输出格式：1080p NV12；帧率跟节目，这里是标称 / 占位画面用的。
    public static let width = 1920
    public static let height = 1080
    public static let nominalFrameRate = 60
    /// 主程序没在送帧时扩展自己产的占位画面帧率。
    public static let placeholderFrameRate = 30
    /// sink stream 队列深度（帧）。
    public static let sinkQueueDepth = 8
}
