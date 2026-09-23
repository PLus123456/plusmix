# 014 输入声道映射（`InputSource` 里给纯音频 / DeckLink 加"取哪几路"）

提出：W2-A2（分支 `w2-inputs-2`，2026-09-23）。前一次提出同一件事：W3-A 报告 §4 第 5 条（DeckLink 内嵌音频声道数）。
状态：**已落地**（用户 2026-09-23 批，并指定 W2-A2 自己落地；分支 `w2-inputs-2`，叠在 P3 的 `ca1baa5` 之上）。

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
声道映射是**采集侧**的：它决定输入往环里写什么，而输入对象现在不看 MixerState（契约 `Input` 协议里没有状态入口），
改它等于重建这一路输入——和"换设备"是同一类操作。所以放在 `InputSource` 里（= 这路输入"接的是什么"）更合口径。
如果希望它运行中可改不重建，那就是另一件事（输入要能看快照），范围比本提案大得多，建议单独提。

## 不批会怎样

两边都只能留在包内 `Options`：默认取前两路，节目文件记不住，Add Input 表单里那一项做不了（或者做了也存不住）。
功能上不阻塞——单声道 / 双声道设备（绝大多数话筒、USB 声卡的主输出）走默认就对。

## 落地记录（2026-09-23，W2-A2）

| 文件 | 改动 |
|---|---|
| `SwitcherContracts/Input.swift` | `audio(deviceUID:channels:)`、`decklink(deviceID:connection:channels:)`，`channels: [Int] = []`；`InputSource` 顶上加"声道映射"一节的口径注释；`audio` 注释补"空串 = 跟随系统默认输入"；`Input.videoSlot` 注释写进纯音频输入的口径（W2-A2 报告 §4 第 2 条，用户同日定） |
| 同上（Codable） | P3 的"decklink / ndi 自己解、其余交给内部 Synthesized 枚举"改成**一个 JSON 形态镜像枚举 `Form`，解码 / 编码都走它**：带默认值的参数在镜像里是 Optional（合成 Codable 对 Optional 用 decodeIfPresent / encodeIfPresent），编码时空 `channels` 写成 nil。结果：014 之前能表达的值编出来逐字节不变（P3 的 `testP3_008_*` 键名快照原样通过），带映射的才多一个 `channels` 键 |
| `SwitcherContractsTests/Contracts014Tests.swift` | 5 条：老文件缺键 → `[]`；空映射不写键；带映射的形态与往返（含 `null` / `[]`）；其余 case 形态逐个再钉一遍；节目文件存取 |
| `docs/CONTRACTS.md` | 标题、变更记录、§2.4 表与两段口径（声道映射、纯音频输入）、§3 速查一条 |
| `SwitcherInputs/Common/InputChannelMap.swift`（新） | 映射口径的唯一实现：`requestedChannel` / `sourceChannel` / `clamp` / `requiredSourceChannels` |
| `SwitcherInputs/Audio/AudioDeviceInput.swift`、`AudioCaptureFIFO.swift` | `init(config:)` 从 case 取；`Options.channelMap` 非 nil = 显式覆盖（与 008 的 `connection` 同一口径）；交接区的声道表按 `InputChannelMap` 算 |
| `SwitcherInputs/DeckLink/DeckLinkInput.swift` | `Options.channelMap`（同上）；`init(config:)` 从 case 取；内嵌音频开的路数 = max(`audioChannels`, 映射要的) 按 2 / 8 / 16 往上取（`embeddedAudioChannels`）；回调里查 init 时算好的表，不碰 Swift 数组 |
| `App/Sources/Settings/InputSettingsPanel.swift` | 两处 `switch` 的模式跟着多一个关联值（编译跟改，2 行）；摘要里显示映射归 W3-E2 |
| 测试 | `InputChannelMapTests`（口径 4 条 + AudioDeviceInput 从 case 取 1 条）、`AudioCaptureFIFOTests` 加短映射 / 越界 / 跨 buffer 1 条、`DeckLinkChannelMapTests`（从 case 取、路数取整、对着 Fake 的 8 路内嵌音频 → 环 3 条） |

**与提案原文的一处出入**：原文"影响谁"里写"`InputSource` 的 JSON 快照多两个键"。落地时改成**空映射不写键**：老文件和不用映射的新文件逐字节不变，
快照和 docs/api.md 都不用动；用了映射的才多 `channels` 这一个键。语义没变（缺键 = 空 = 取前几路）。
