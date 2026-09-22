// SwitcherDeckLink —— DeckLink SDI / HDMI 输入（W3-A 交付 1；设计方案 §6 DeckLink 行、§3.6）。
//
//   DeckLinkDevices   设备枚举（持久 ID、型号、输入接口、是否支持格式检测）、驱动 / SDK 是否在。
//   DeckLinkInput     一路输入：C++ 桥接（CSwitcherDeckLink）把 SDK 回调变成 C 回调；这里做 Input 协议、状态、看门狗、热插拔重开、
//                     帧 → 帧槽（入口 host time：硬件参考时间经一阶滤波校准）、内嵌音频 → 环。
//
// 编译开关：Package.swift 探测到 DeckLink SDK（DECKLINK_SDK_DIR / ~/SDKs/DeckLink / NDI SDK 示例自带副本）才把桥接层编进去；
// 没有时 `SwitcherDeckLinkInfo.isSDKAvailable == false`，`DeckLinkInput.start()` 抛 `DeckLinkInputError.sdkUnavailable`。
// 运行时还要装 Blackmagic Desktop Video（驱动）：没装时枚举 0 台，输入进 noSignal 并给文案，不崩。
import CSwitcherDeckLink
import SwitcherContracts

/// 模块信息。
public enum SwitcherDeckLinkInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
    /// 编译时是否带了 DeckLink SDK。
    public static var isSDKAvailable: Bool { sw_decklink_sdk_compiled() != 0 }
    /// 编进来的 SDK 头文件版本（如 "10.11.2"）；没有时空串。
    public static var sdkVersion: String { String(cString: sw_decklink_sdk_version()) }
    /// 运行时 Desktop Video 驱动是否能加载。
    public static var isDriverPresent: Bool { sw_decklink_api_present() != 0 }
    /// 驱动版本字串；没有驱动时空串。
    public static var driverVersion: String {
        var buf = [CChar](repeating: 0, count: 64)
        return String(cString: sw_decklink_driver_version(&buf, buf.count))
    }
    /// SDK 不在时给用户看的文案。
    public static let unavailableMessage = "DeckLink SDK 未编译进来：把 Blackmagic Desktop Video SDK 解压到 ~/SDKs/DeckLink（或设 DECKLINK_SDK_DIR）后重新编译"
    /// 驱动不在时给用户看的文案。
    public static let driverMissingMessage = "没有找到 DeckLink 驱动：安装 Blackmagic Desktop Video（/Library/Frameworks/DeckLinkAPI.framework）后重试，不用重启本程序"
}
