# W2-A2 → W3-E2：App 接纯音频设备输入 + 提案 014 的声道选择

归属会话 / 分支：W3-E2 / `w3-app-3`（prompt 63 第 7 条已经点名"App 接线归 W3-E2"；这里把接法、014 带来的新表单项和定下来的界面口径写全）
发现于：W2-A2（分支 `w2-inputs-2`，2026-09-23）；`AudioDeviceInput` 与提案 014 都在这个分支上，**叠在 P3 之上**，要等检查点把 P3 与本分支都合进 main 后 W3-E2 才看得到
现象：
1. `App/Sources/Engine/InputFactory.swift` 的 `case .audio:` 还是 `throw InputFactoryError.unsupported(config.kind)`，Add Input 的"纯音频设备"页能选设备，建出来是一路占位输入（`PlaceholderInput` + 文案），没有声音。
2. 提案 014 已落地：`InputSource.audio(deviceUID:channels:)`、`.decklink(deviceID:connection:channels:)`。表单还没有声道选择，多路接口上的话筒（第 5、6 路）选不了。
3. `App/Sources/Settings/InputSettingsPanel.swift` 的来源摘要没显示映射（W2-A2 只做了编译跟改：两处 `switch` 多一个 `_`）。
复现步骤：Add Input → 纯音频设备 → 选内置麦克风 → 确定 → 这一路 state 是 error「不支持的输入类型」，调音台没有它的电平。
严重级：S1（界面里加不了纯音频输入；节目能继续）

## 做法

**1. 工厂（约 6 行）**

```swift
case .audio:
    // W2-A2：Core Audio IOProc 取样（回调零分配），泵线程写环；设备不在 = noSignal + 文案，权限被拒 = error
    let ring = CAudioRing(channelCount: 2)
    let input = try AudioDeviceInput(config: config, audioRing: ring)
    return MadeInput(input: input, audioRing: ring, audioBlockFrames: 1024)
```

`audioBlockFrames` 是给混音器算就绪年龄的生产者块大小：设备 IO 块（`AudioInputDevices.list()` / `AudioHAL.devices()` 里的
`bufferFrameSize`，本机都是 512）；走采样率转换时每块多约 9%（44.1 k → 48 k 是 557–558 帧）。拿不准就像摄像头 / DeckLink 一样给 1024。

**2. 不用管帧槽**：`InputRuntime.add` 照旧给每路建一个 `LockFreeFrameSlot` 并 `registerInput`——纯音频输入从来不往里推，
引擎挑帧恒为 nil，渲染画黑，这正是定下来的口径（见下）。`AudioDeviceInput.videoSlot` 是 nil，**不要强制解包它**。

**3. Add Input 表单（提案 014）**
- "纯音频设备"页：设备列表现在用的是 `AudioHAL.devices()`（SwitcherAudio），uid 就是 Core Audio 的 `kAudioDevicePropertyDeviceUID`，与
  `AudioDeviceInput` 要的一致，可以继续用；也可以换 `SwitcherInputs.AudioInputDevices.list()`（多了 `supports48k` / `transportType` /
  `isDefaultInput` / `bufferFrameSize`，以及 `observeChanges(queue:onChange:)` 设备插拔时刷新列表，记得 `stop()`）。
- 设备输入声道数 > 2 时显示"取第几路"：两个下拉（左 / 右），或一个"单声道：第 N 路"开关。写进 `.audio(deviceUID:channels:)`：
  `[4, 5]` = 第 5、6 路；`[4]` = 单声道话筒插在第 5 路（两个声道都取它）；空 = 取前两路。口径见 `docs/CONTRACTS.md` §2.4"声道映射"。
- DeckLink 页同理（内嵌音频 1–16 路，卡不告诉你有几路有信号，给 1–16 让用户选）；`DeckLinkInput` 会按映射自动多开内嵌音频路数（2 / 8 / 16）。
- 空串 uid = 跟随系统默认输入（系统设置里换了默认输入会自动重建），可以作为列表第一项"系统默认输入"。

**4. InputSettingsPanel 的来源摘要**：`.audio(let uid, let channels)` 在 `channels` 非空时加"（第 5、6 路）"之类；DeckLink 同理。

**5. 纯音频输入的界面口径（W2-A2 报告 §4 第 2 条，用户 2026-09-23 定；契约 `Input.videoSlot` 注释、CONTRACTS.md §2.4）**
- 能被选进 Program / Preview / 叠加，画面按"没帧"画黑场，音频照常按每路 AFV 走（切到它就出它的声）——引擎和渲染器今天就是这样，App 不用拦；
- 输入条 / 缩略图里它没有画面：画一个占位（名字 + 电平表 + 话筒图标之类），不要显示成"无信号"的黑块；
- 多画面里的占位格见 `W2A2-w3-compositor2-multiview-audio-only-cell.md`（渲染器那边）。

**6. 权限文案**：麦克风权限被拒时 `state = error("麦克风权限被拒。打开 系统设置 › 隐私与安全性 › 麦克风，允许本程序后会自动恢复，不用重启。")`，
App 的 Info.plist 要有 `NSMicrophoneUsageDescription`（摄像头自带麦克风已经在用，应该已有，核一下）。
