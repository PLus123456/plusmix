// SwitcherNDI —— NDI 接收（W3-A 交付 2；设计方案 §6 NDI 行、§3.6）。
//
//   NDIFinder     源发现（NDIlib_find）：列出网络上的源（"机器名 (源名)" + 地址），App 的 Add Input 和 NDIInput 自己都用它。
//   NDIInput      一路 NDI 输入：接收线程 NDIlib_recv_capture_v3（请求 UYVY，有 alpha 的源给 BGRA）→ 拷进 IOSurface 背后的
//                 CVPixelBuffer（池）→ 入口打 host time → 帧槽；音频 float32 平面 → 环（非 48 kHz 的先线性重采样到 48 kHz）；
//                 tally 回传（NDIlib_recv_set_tally）；源没帧超过 N 个帧间隔 → noSignal；源消失 / 换地址 → 自动重连。
//   NDIClockMap   抖动缓冲的数学（纯 Swift，SDK 不在也能测）：发送端时间戳 → "这帧走最快路径本该几时到"，多出来的就是抖动。
//
// 时间戳（铁律 5、设计方案 §3.6 "NDI 收到时打戳，另加一个小抖动缓冲"）：
//   arrival   = capture 返回那一刻的 host time（入口打戳）
//   jitter    = NDIClockMap：d_k = 本机墙钟 − 发送端时间戳；基线 m = 最近 1–2 s 内 d 的最小值；jitter = d_k − m ≥ 0
//   pts       = arrival − jitter + J × 帧间隔（J = Options.jitterBufferFrames，默认 1，0–2 可配）
//   ingress   = push 前一刻
// 于是走最快路径到的帧 pts 比到达晚 J 帧，晚到（抖动）的帧 pts 相应提前——引擎按 pts ≤ 拍点挑帧，J 帧的缓冲就吸收 ≤ J 帧的抖动，
// 再晚的帧才会迟到；引擎自己的到达余量（W1-B2）看到的 d = ingress − pts = jitter − J×T，只在网络比缓冲还差时才再加余量，不会重复付。
// 音频块的 hostTime 用同一个映射并加同样的 J×T，A/V 相对关系不变。L1 因此包含 J 帧（prompt："L1 ≤ 3 帧 + 抖动缓冲"）。
//
// 编译开关：Package.swift 探测到 NDI SDK 才把 SDK 编进 CSwitcherNDI；没有时 `SwitcherNDIInfo.isSDKAvailable == false`，
// `NDIInput.start()` 抛 `NDIInputError.sdkUnavailable` 并把 state 置成带文案的 error。
import CSwitcherNDI
import SwitcherContracts

/// 模块信息。
public enum SwitcherNDIInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
    /// 编译时是否带了 NDI SDK（Package.swift 探测 /Library/NDI SDK for Apple 或 NDI_SDK_DIR）。
    public static var isSDKAvailable: Bool { sw_ndi_sdk_compiled() != 0 }
    /// NDI 运行库版本字串（SDK 不在时空串）。
    public static var sdkVersion: String { String(cString: sw_ndi_version()) }
    /// SDK 不在时给用户看的文案。
    public static let unavailableMessage = "NDI SDK 未编译进来：安装 NDI SDK for Apple 到 /Library/NDI SDK for Apple（或设 NDI_SDK_DIR）后重新编译"
}
