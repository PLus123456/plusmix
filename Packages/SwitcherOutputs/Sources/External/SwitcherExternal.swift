// SwitcherExternal —— 外部显示输出（W3-C，设计方案 §8 外部显示行、§3.3）。
//
// `ExternalDisplayWindow`：一块指定显示器上的全屏无边框 NSWindow + `MetalDisplayView`（W1-C / W2-B 的显示视图，
// 自己的 display link 按该显示器刷新率把"最新完成的纹理"blit 上去，渲染线程不碰它）。源可选 PGM / PVW / 多画面 / 任一输入
// （Aux 语义：输入取多画面纹理里它的格子，`MultiviewLayout.inputCell`）。显示器插拔由 `ExternalDisplayManager` 处理：
// 目标显示器不在就把窗口收起（可选退到主屏），回来了再放回去。
// 一个窗口 = 契约里一个 `kind = .externalDisplay` 的输出：`settings.source` 是源，显示器 ID 放 `settings.extra["displayID"]`
// （契约给各输出会话的附加项占位，不改契约）。
import SwitcherContracts

/// 模块版本 = 契约版本。
public enum SwitcherExternalInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
}
