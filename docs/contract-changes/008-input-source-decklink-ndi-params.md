# 008 InputSource 的 DeckLink / NDI 来源参数：输入接口、带宽模式、抖动缓冲深度

提出会话 / 分支：W3-A / w3-inputs2（worktree 原名 claude/decklink-ndi-inputs-da4ad2，已改名）
状态：**待批**

## 改什么

`InputSource`（Input.swift）的两个 case 加带默认值的关联值；`InputSettings` 不动（这些参数描述"接的是什么、怎么接"，改了要重开设备，
和设备 ID / 源名同一性质；裁切 / 变换 / 音频那类"接上之后怎么调"的才放 InputSettings）。

现在：
```swift
case decklink(deviceID: String)
case ndi(sourceName: String)
```
提议：
```swift
/// DeckLink 设备的持久标识 + 输入接口。deviceID 格式由 W3-A 定：卡有 BMDDeckLinkPersistentID 属性时 "peid:<int64>"，
/// 没有时 "model:<型号>#<同型号内序号>"；空串 = 第一台有输入的卡。connection nil = 不改卡上的当前设置。
case decklink(deviceID: String, connection: DeckLinkConnection? = nil)
/// NDI 源名（"机器名 (源名)"）+ 带宽模式 + 抖动缓冲深度（帧，0–2）。
case ndi(sourceName: String, bandwidth: NDIBandwidth = .highest, jitterBufferFrames: Int = 1)

/// DeckLink 输入接口（BMDVideoConnection 单个位）。
public enum DeckLinkConnection: String, Codable, Sendable, CaseIterable { case sdi, hdmi, opticalSDI, component, composite, sVideo }
/// NDI 接收带宽（NDIlib_recv_bandwidth）。
public enum NDIBandwidth: String, Codable, Sendable, CaseIterable { case highest, lowest, audioOnly }
```

JSON：`{"decklink":{"deviceID":"peid:…","connection":"sdi"}}`、`{"ndi":{"sourceName":"…","bandwidth":"highest","jitterBufferFrames":1}}`。
缺键按默认解（`decodeIfPresent`），老节目文件里的 `{"ndi":{"sourceName":"…"}}` 原样可读。

## 为什么

- prompt 50 交付 3："两者的 InputSettings 扩展（DeckLink 输入口 / 连接类型；NDI 源名、带宽模式）走契约提案流程"。
- DeckLink 卡多数有多个输入接口（Mini Recorder 有 SDI + HDMI），当前接口是卡的全局设置（`bmdDeckLinkConfigVideoInputConnection`），
  节目文件里不记就要靠用户在 Desktop Video Setup 里点；`DeckLinkInput.Options.connection` 现在是包内选项，组装方（App / headless）没处取值。
- NDI 带宽模式决定这路是全分辨率还是预览流（多画面缩略图用 lowest 省一半以上带宽 / 解码），也该跟着输入存。
- 抖动缓冲深度：设计方案 §3.6 "NDI 收到时打戳，另加一个小抖动缓冲"，prompt 要求"1–2 帧，可配"。它直接决定这路的延迟（W3-A 实测
  J = 0 / 1 / 2 → L1 0.65 / 1.73 / 2.71 帧，reports/w3-inputs2.md §2），不同网络环境要不同值，属于节目文件该记的东西。
  若嫌 case 关联值太多，可以只加 bandwidth、把 jitterBufferFrames 放 `InputSettings` 里一个 `ndi` 子结构——W3-A 倾向放 InputSource，
  因为改它要重开接收器（pts 口径变了，帧槽里的旧帧要作废）。

## 影响谁

- `Input.swift`：两个 case 加关联值 + 两个新枚举；`InputSource` 的 Codable 是合成的，加关联值后 JSON 键会多出来，需要给 `decklink` / `ndi`
  写显式 `init(from:)` 用 `decodeIfPresent` 兜老文件（或接受老文件缺键即默认——合成的 Codable 对缺键会报错，所以必须显式写）。
- `SwitcherContractsTests`：Codable 往返 + 键名快照。
- W3-A 的 `DeckLinkInput.init(config:)` / `NDIInput.init(config:)`：从 case 里取 connection / bandwidth / jitterBufferFrames 填 Options
  （现在从 Options 参数取，组装方给；落地后 Options 里这三项保留为覆盖）。
- W3-E App 的 Add Input 表单：DeckLink 选接口（`DeckLinkDeviceInfo.inputConnections` 列出卡支持的）、NDI 选带宽 / 抖动缓冲。
- headless / TestKit：不受影响（默认值）。`Show.schemaVersion` 不升（老文件按默认解）。

## 怎么迁移

- 老 Show 文件：缺键 = 默认（connection nil、bandwidth highest、jitterBufferFrames 1），不改文件。
- 写出总是写全。
- 不批的话：三项留在包内 `Options`，节目文件记不住，App 每次打开都是默认值；DeckLink 接口只能在 Desktop Video Setup 里改。
