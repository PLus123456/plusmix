# 013 显示类输出进 Stats（`display[]`）；外部显示设置的正式字段（`OutputSettings.display`）

提出会话 / 分支：G4 / g4（2026-09-22；来源 W3-C 报告 §4 第 1 / 2 条与 §3 第 6 条，W2-B 的 `MetalDisplayView.presentedFrames` 同类；G4 报告 §8 第 5 条）
状态：**已批**（用户 2026-09-22 "4–8 也都做"；字段形态由 G4 拟，契约会话 P3（docs/plan/prompts/61）落地时可微调，把最终形态写进报告）

## 改什么

### A. `Stats` 加 `display: [DisplayEntry]`（JSON 键 `display`；缺键 = 空数组，写出总是写）

铁律 4 说所有数字进 Stats。`Stats.encoder[]` 的定义是"带编码器的输出（record / stream / ndi）"，显示类输出（外部显示窗口、虚拟摄像头、多画面窗口、主界面监视器）没有位置，
帧数只在各自对象的计数里（`MetalDisplayView.presentedFrames`、`VirtualCameraOutput.countersSnapshot`），菜单状态行和测试各读各的。

```swift
public struct DisplayEntry: Hashable, Codable, Sendable {
    /// 输出编号（MixerState.outputs 里的 number）；主界面的监视器视图不是输出，用 0。
    public var output: Int
    /// "externalDisplay" / "virtualCamera" / "multiviewWindow" / "monitor"。
    public var kind: String
    /// 已呈现（显示）/ 已送出（虚拟摄像头扩展收到）的帧数，累计。
    public var frames: UInt64
    /// 没赶上显示刷新 / 被扩展丢弃的帧数，累计。
    public var dropped: UInt64
    /// "idle" / "presenting" / "noDisplay"（显示器不在：退回主屏或黑着等）/ "waitingExtension"（扩展未激活）/ "publishing" / "stopped" / "failed"。
    public var state: String
}
```
JSON：`"display":[{"output":3,"kind":"externalDisplay","frames":36000,"dropped":0,"state":"presenting"}]`。

填数方：`ExternalDisplayManager`（每个外部显示输出一项）、`VirtualCameraOutput.countersSnapshot`、`MultiviewWindowController`、App 的 `MetalDisplayView.presentedFrames`（monitor，output 0）；
汇总进 Stats 的是 App `StatsHub` 与 headless 的 stats 源（headless 现在没有显示类输出，写空数组）。`StatsWriter` / `StatsSummary` 多几列（display 各项 frames / dropped 的汇总）。

### B. `OutputSettings` 加 `display: DisplayOutputSettings?`（kind = externalDisplay 用；nil = 主显示器、拔掉退回主屏）

```swift
public struct DisplayOutputSettings: Hashable, Codable, Sendable {
    /// CGDirectDisplayID；nil = 主显示器。显示器 ID 重启后可能变，App 侧另存型号 / 序列号做匹配是界面的事。
    public var displayID: UInt32? = nil
    /// 显示器不在时退回主显示器（true，默认）还是黑着等它回来（false）。
    public var fallbackToMain: Bool = true
}
```
过渡键 `extra["displayID"]`（数字）/ `extra["fallbackToMain"]`（布尔；`ExternalDisplaySpec.displayIDKey / fallbackKey`）保留一个版本作后备：正式字段为 nil 时读过渡键；解码旧 Show 时搬进正式字段、清掉旧键（与 010 的 `extra["layout"]` 同一做法）。

## 为什么

- 铁律 4：UI、API、测试三方读同一个结构。现在菜单状态行读 `VirtualCameraOutput.countersSnapshot`、测试读 `presentedFrames`，都在 Stats 之外；G4 的 gate 对显示类输出一个数都拿不到（docs/checklists/G4.md 第 6 / 7 条只能人工看）。
- 显示器 ID 放 `extra` 是占位（W3-C 报告 §4 第 2 条），W3-E 的设置面板已经在读写它（键名 G4 对齐成 displayID），有面板的东西该是正式字段。

## 影响谁

SwitcherContracts（两个结构 + Codable 往返 / 键名快照）、SwitcherTestKit `Stats/`（StatsWriter / StatsSummary）、SwitcherOutputs `External/`（statsEntry）与 `VirtualCamera/`（statsEntry）、
App（`AuxOutputRuntime` / `StatsHub` 汇总、`OutputExtras` 改读正式字段）、headless（写空数组）、docs/CONTRACTS.md §2.5 / §2.7、测试标准 §7 的字段表（由用户同步，P3 报告列出）。
W3-C2（prompt 65）在 P3 之后复核填数（dropped、noDisplay / waitingExtension 状态）。

## 怎么迁移

缺键 = 空数组 / nil，老 stats.jsonl 与老 Show 原样可解；`Show.schemaVersion` 不升；写出总是写全。
