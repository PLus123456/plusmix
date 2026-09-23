# W2-A2 → 用户：要插拔设备 / 改系统设置 / 接线才能测的几项

归属会话 / 分支：用户手动（会话里没法替用户插拔设备、在系统设置里点权限、接回环线）；代码和测试都在分支 `w2-inputs-2`
发现于：W2-A2（2026-09-23）
现象：下面五项在 W2-A2 里是 XCTSkip / 没有硬件，代码路径有单元测试或合成测试覆盖，但真机没验。
严重级：S2（都有代码与单元测试兜着；真机验完才算闭环）

## 1. S4 纯音频设备热插拔（BLOCKED-硬件）

要一台能反复插拔的 USB 声卡 / 音频接口（本机能拔的只有 HP Thunderbolt 坞站上的耳麦，要拔整个坞站）。

```bash
SWITCHER_AUDIO_HOTPLUG_UID='AppleUSBAudioEngine:Generic:USB Audio:201604140001:1' swift test --package-path Packages/SwitcherInputs --filter testS4_audioDeviceUnplugGoesNoSignalThenRecovers
```

uid 换成要测的设备（`AudioDeviceProbe.deviceLines()` 或探针 `audio-device` 列出来的）。按提示拔 → 期望 `noSignal` + 文案
「音频输入设备「X」已断开，等待重新连接」；插回 → 期望 **≤ 3 s** 回 `live`，编号不变、不重建输入对象。默认 20 次（`SWITCHER_AUDIO_HOTPLUG_CYCLES` 可改），
最后打印最大 / 平均恢复时间表。阈值同摄像头 S5（≤ 3 s，目标 ≤ 1 s）。

## 2. 麦克风权限被拒 = error（本进程有权限，测试 XCTSkip）

在 系统设置 › 隐私与安全性 › 麦克风 里关掉跑测试的那个程序（从 Claude 跑是 Claude；从 Terminal.app 跑是 Terminal）：

```bash
swift test --package-path Packages/SwitcherInputs --filter testPermission_microphoneDeniedIsError
```

期望：`start()` 不抛不崩，5 s 内 `state = error`，文案含"麦克风权限""系统设置""自动恢复"；`stop()` 后回 `noSignal`。
再打开权限 → 同一个输入对象 ≤ 2 s 回 `live`（轮询每秒一次，和摄像头 S6 同一段代码）。测完记得把权限开回去。

## 3. 多于 2 路的真设备声道映射（提案 014；没有硬件）

本机输入设备最多 2 路。有 4 / 8 路的接口时：节目里加 `.audio(deviceUID: <uid>, channels: [4, 5])`，往第 5、6 路分别送不同的信号
（或只接一路），看环里左右声道是不是那两路；`[4]` 应该两个声道都是第 5 路。合成数据的等价测试已过
（`AudioCaptureFIFOTests.testIOProc_shortChannelMapRepeatsLastEntry_outOfRangeIsClamped`，含非交错的两个 buffer 各 4 路的布局）。

## 4. DeckLink 内嵌音频的声道映射（提案 014；BLOCKED-硬件，同 W3-A 的其它 DeckLink 实机项）

有卡 + 带 8 路内嵌音频的 SDI 信号时：`.decklink(deviceID: …, channels: [5, 2])` → 期望内嵌音频开 8 路（`DeckLinkInput` 自动从 2 升到 8），
环里左 = 第 6 路、右 = 第 3 路。对着 Fake 的等价测试已过（`DeckLinkChannelMapTests.test014_deckLinkFake_eightChannelEmbeddedAudio_mappedIntoRing`）。

## 5. 纯音频设备的端到端 A2（回环线；先要 `W2A2-g5-headless-audio-device-input.md`）

W2-A2 的 A2 测的是"块上打的是设备的 mHostTime"（d 的标准差 0.077 ms）。真正的 A2 口径（输出里闪光 vs click）要一条回环：
音频接口的**线路输出 → 线路输入**，headless 用合成源出 PGM + click 到这个输出设备（`--audio-device <uid>`），同时把这个接口的输入
作为一路纯音频输入录进 ISO 音轨；frameprobe 对 ISO 音轨里的 click 与 PGM 闪光配对。期望：偏移 = 接口的输出 + 输入硬件延迟
（固定值，可由 `InputAudioSettings.delayMs` 补掉），标准差 ≤ 1 ms，10 分钟斜率 × 8 h ≤ 16 ms（A3）。
要的东西：一台有线路输入输出的接口 + 一根线；headless 接上纯音频输入（上面那张单子）。
