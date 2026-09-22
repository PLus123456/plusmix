# 014 输入声道映射（`InputSource` 里给纯音频 / DeckLink 加"取哪几路"）

提出：W2-A2（分支 `w2-inputs-2`，2026-09-23）。前一次提出同一件事：W3-A 报告 §4 第 5 条（DeckLink 内嵌音频声道数）。
状态：**待用户批**（铁律 1：没批之前 SwitcherContracts 一个字都不改）。

## 改什么

`InputSource` 的两个 case 各加一个带默认值的参数：

```swift
/// Core Audio 设备 UID（纯音频输入）。channels = 取设备的哪几路（设备声道下标，长度 = 环的声道数）；
/// 空数组 = 取前几路（单声道设备复制到所有声道，设备声道比环少时复制最后一路）。
case audio(deviceUID: String, channels: [Int] = [])
/// DeckLink 设备。channels 同上（SDI 内嵌音频 2–16 路里挑两路）。
case decklink(deviceID: String, connection: DeckLinkConnection = .auto, channels: [Int] = [])
```

（`.decklink` 的 `connection` 是提案 008 的，P3 正在落地；这里只加 `channels`，两条提案在同一个 case 上，落地时一起改。）

`Codable`：两个 case 都要显式写 `init(from:)`，缺键按默认值解（合成的 Codable 对缺键会报错，老节目文件读不进来——提案 008 §"迁移"里是同一条）。

## 为什么

- **纯音频设备**（W2-A2）：USB 接口 / 小调音台常见 4、8、16 路输入，主持人话筒可能插在第 5、6 路上。
  现在包内有 `AudioDeviceInput.Options.channelMap`（默认取前两路），但 `Options` 不进节目文件：
  用户在 Add Input 里选了"取第 5、6 路"，存盘再打开就变回第 1、2 路。W3-E2 的 Add Input 表单要填的就是这个值。
- **DeckLink**（W3-A）：`Options.audioChannels` 默认 2，卡给 2–16，同样存不住。
- 两个会话独立撞到同一个缺口，不是个别需求。

## 影响谁

| 谁 | 怎么改 |
|---|---|
| `SwitcherContracts/Input.swift` | 两个 case 加参数 + 显式 `Codable`；`InputSource.kind` 不变 |
| `SwitcherInputs`（W2-A2 / W3-A） | `AudioDeviceInput.init(config:)` / `DeckLinkInput.init(config:)` 把它读进各自的 `Options.channelMap`，包内选项保留（探针 / 测试直接传） |
| App（W3-E2） | Add Input 的"纯音频设备"页加声道选择（设备声道数 > 环声道数时才显示）；DeckLink 页同理 |
| 别的包 | 不受影响：`InputSource` 的其他 case 不动，mixer / 渲染 / 输出都不看它 |
| 快照测试 | `InputSource` 的 JSON 快照多两个键（带默认值，老文件仍能解） |

## 为什么不放 `InputAudioSettings`

`InputAudioSettings`（路由 / 增益 / 静音 / 声像 / 延迟）是**混音侧**的参数，从 `MixerState` 快照读、运行中可改。
声道映射是**采集侧**的：它决定输入往环里写什么，而输入对象today 不看 MixerState（契约 `Input` 协议里没有状态入口），
改它等于重建这一路输入——和"换设备"是同一类操作。所以放在 `InputSource` 里（= 这路输入"接的是什么"）更合口径。
如果希望它运行中可改不重建，那就是另一件事（输入要能看快照），范围比本提案大得多，建议单独提。

## 不批会怎样

两边都只能留在包内 `Options`：默认取前两路，节目文件记不住，Add Input 表单里那一项做不了（或者做了也存不住）。
功能上不阻塞——单声道 / 双声道设备（绝大多数话筒、USB 声卡的主输出）走默认就对。
