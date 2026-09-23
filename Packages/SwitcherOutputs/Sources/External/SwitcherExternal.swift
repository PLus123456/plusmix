// SwitcherExternal —— 外部显示输出（W3-C，设计方案 §8 外部显示行、§3.3；W3-C2 续做）。
//
// `ExternalDisplayWindow`：一块指定显示器上的全屏无边框 NSWindow。源可选 PGM / PVW / 多画面 / 任一输入：
// - PGM / PVW / 多画面：`MetalDisplayView`（W1-C / W2-B 的显示视图，自己的 display link 按该显示器刷新率把"最新完成的纹理"blit 上去，
//   渲染线程不碰它），数据源夹一层 `DisplayFrameLedger` 记"没赶上刷新"的帧；
// - 输入 n（Aux，W3-C2）：`AuxInputView` + `AuxInputPresenter` 每次显示刷新用帧槽的契约读入口取该路最新帧（组装方经 `AuxFrameTap`
//   给一个 InputFrameTee 分支），CVMetalTextureCache 包成纹理，按渲染器同一套系数全分辨率画（`AuxShaders.swift`）。Aux = 原始画面；
//   无信号画占位（与多画面格子同一套文案）。
// 显示器插拔由 `ExternalDisplayManager` 处理：目标显示器不在就把窗口收起（可选退到主屏），回来了再放回去。
// 一个窗口 = 契约里一个 `kind = .externalDisplay` 的输出：`settings.source` 是源，显示器 ID / 退回策略是 `settings.display`（提案 013）。
// 统计进 `Stats.display[]`（`ExternalDisplayManager.statsEntries`）。
import SwitcherContracts

/// 模块版本 = 契约版本。
public enum SwitcherExternalInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
}
