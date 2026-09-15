// SwitcherNDISend —— NDI 发送（W2-D 交付 3；设计方案 §8 NDI 发送行）。
//
//   NDISender     FrameConsumer + AudioBlockConsumer：PGM 必送（`source = .program`），PVW / 多画面 / 任一输入可选。
//                 自己的线程 + 深度 2–3 的有界队列（满了丢最旧并计 skipped），线程里做 NV12 → UYVY 再 NDIlib_send_send_video_async_v2；
//                 音频块（Master，float32 非交错）走同一条线程 NDIlib_send_send_audio_v3。
//   NV12ToUYVY    转换器：GPU（compute kernel，输出到共享内存 MTLBuffer，双缓冲）/ CPU（逐行）。两者逐字节相同。
//                 选法 `Configuration.Conversion`：auto（默认，定期两种都试用便宜的；负载变了会自己切）/ gpu / cpu，
//                 运行时 `setConversion` 可改，Show 文件用 `OutputSettings.extra["ndi.conversion"]`。
//
// `#if canImport(NDI)`：Package.swift 探测到 NDI SDK（/Library/NDI SDK for Apple 或 NDI_SDK_DIR）才挂系统库 target NDI；
// 没有 SDK 时本模块编成空实现：start() 抛 `NDISendError.sdkUnavailable`，计数里 `unavailable = true`（Stats 标 unavailable 等提案 002）。
import SwitcherContracts

/// 模块信息。
public enum SwitcherNDISendInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
    /// 编译时是否带了 NDI SDK。
    public static var isSDKAvailable: Bool {
        #if canImport(NDI)
        return true
        #else
        return false
        #endif
    }
}
