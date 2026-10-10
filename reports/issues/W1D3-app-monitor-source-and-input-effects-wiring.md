# App 接线：耳机听所选总线（提案 026）、借 Master 声道（X09）、每路效果"已生效"的两个用例、压缩器简单模式

归属会话 / 分支：App 会话（下一个动 `App/Sources/UI/MixerPanelView.swift`、`App/Sources/Engine/AudioRuntime.swift`、`App/Sources/Settings/AudioSettingsPanel.swift` 的会话），或 G8 胶水（每项都 ≤ 50 行）
发现于：W1-D3（prompt 102，分支 `w1-audio-3`）——引擎侧做完了，App 只许翻 `AudioEffectsSupport.inputEffectsApplied` 一个常量
严重级：S2（界面上的开关已在但不起作用 / 两个 App 用例要跟着翻）

## 现象 / 要改什么

1. **耳机听所选总线（J7，提案 026）**：引擎已按 `AudioState.monitorSource` 把耳机出口换成所选总线（`AudioEngine` 每个控制周期对快照 diff，
   `AudioMixer.setMonitorSource`；有独听时仍只听独听的）。App 侧 `MixerModel.listenToOtherBusSupported = false`（`UI/MixerPanelView.swift:240`）仍把
   Master / Bus A / Bus B 三项灰着，`MixerModel.listen(_:)` 只改本地 `listenBus`。改法：
   - `listenToOtherBusSupported = true`；`listen(_ bus:)` 改成 `send?(.setMonitorSource(bus: bus))`（契约命令，P5 已落地），`listenBus` 从快照 `audio.monitorSource` 读
     （菜单里的"耳机总线（现在）"一项：契约不允许 monitorSource = headphones，这一项该去掉或灰掉，见本单 §疑问）；
   - `App/Tests/AudioSettingsRevampTests.swift:113` 的 `XCTAssertFalse(MixerModel.listenToOtherBusSupported, …)` 翻成 True。
2. **借 Master 声道（X09）**：引擎新加 `AudioEngine.borrowMasterForMonitor: Bool`（任意线程；开着且有独听时 Master 出口放耳机总线，录制 / 推流拿的 Master 不受影响）。
   App 侧：`AudioRuntime` 建好引擎后 `engine.borrowMasterForMonitor = settings.borrowMasterForMonitor`，设置页改了开关时再设一次；
   `Settings/AudioOutputSettings.swift` 音频设备页上"尚未生效"那句删掉。
3. **每路效果已生效**（本会话已翻 `AudioEffectsSupport.inputEffectsApplied = true`）：两个 App 用例写着"102 接上时翻"，要跟着改：
   - `App/Tests/HonestUITests.swift:15`：`XCTAssertFalse(AudioEffectsSupport.inputEffectsApplied, …)` → True，输入设置"音频效果"页的横幅期望 nil；
   - `App/Tests/AudioEffectsTests.swift:13`：同上。
   合入本分支后 `make test-app` 这两条会红，直到 App 会话 / G8 胶水翻过来（与 88 当时对 87 的处理一样，reports/w5-audio-bus-effects.md §5 第 8 条）。
4. **压缩器简单模式**（提案 024 (b)，reports/w5-app-panels.md §1 交付 4）：契约 id `compressor`（阈值 / 比例 / 拐点 / 起音 / 释放 / 补偿）引擎已实现，
   总线与每路都能装（与 `dynamicsProcessor` 二选一占同一格）。音频设置窗的压缩页可以换成"阈值 + 比例 + 输出增益"写 `compressor`，
   `AudioEffectParams.swift` 加它的范围（= `SwitcherAudio.EffectParameterRanges.table["compressor"]`：阈值 −60…0、比例 1…20、拐点 0…24、起音 0.0001…0.2、释放 0.01…3、补偿 0…24）；
   "延迟自测"一行读 `AudioEngineStatus.BusEffects.compressorMeasuredLatencyFrames` / `InputEffects.compressorMeasuredLatencyFrames`（按设计 0；≠ 自报时 `effectNotes` 有一条）。
   `peakLimiter.ceilingDb`（−20…0）也已实现，限幅页可以给"天花板"滑块。

## 引擎侧给 App 的入口（都在 SwitcherAudioIntegration，已合进 `w1-audio-3`）

| 入口 | 用处 |
|---|---|
| 状态机命令 `.setMonitorSource(bus:)` → 引擎自动落到混音器 | J7 |
| `AudioEngine.borrowMasterForMonitor` | X09 |
| `AudioEngineStatus.monitorSource` / `.borrowMasterForMonitor` | 调音台头部 / 设置页回显 |
| `AudioEngineStatus.InputStatus.effects`（`InputEffects`：eqEnabled / eqBands / dynamicsKind / dynamicsEnabled / latencyFrames / compressorMeasuredLatencyFrames / ignored） | 输入设置窗的效果页回显、"延迟自测"行 |
| `AudioEngineStatus.BusEffects.compressorMeasuredLatencyFrames` | 总线压缩页"延迟自测"行 |
| `AudioEngine.effectNotes` | 钳位 / 没装上 / 延迟 ≠ 自报的日志（每条一次） |

## 疑问（给用户 / App 会话定）

- 提案 026 的契约把 `monitorSource = headphones` 判无效（reducer 拒收），所以 W5-K 菜单里的"耳机总线（现在）"（= 只听每路 `routing.headphones` 送出的那条）在 026 之后没有入口：
  耳机出口 = 所选总线（默认 Master），有独听时 = 独听的路。`BusRouting.headphones` 这一位现在只在耳机总线的录制轨 / 消费者 tap 里可见。要保留"听耳机总线自己"，得让 026 允许 headphones（契约改），见 reports/w1-audio-3.md §4。
