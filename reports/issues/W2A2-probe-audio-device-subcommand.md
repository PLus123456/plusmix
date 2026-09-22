# W2-A2 → 检查点：`switcher-input-probe` 的 `audio-device` 子命令差最后 3 行接线

日期 2026-09-23。提出会话 W2-A2（分支 `w2-inputs-2`）。

## 是什么

prompt 64 交付 4 要 `switcher-input-probe` / SwitcherInputsHarness 加 `audio-device` 子命令。
实现全在 **SwitcherInputsHarness**（`Sources/SwitcherInputsHarness/AudioDeviceProbe.swift`，本会话可改的目录）：

- `AudioDeviceProbe.deviceLines()` —— 设备清单（uid / 名字 / 声道 / 采样率 / 可选采样率 / 48k / IO 块 / 传输 / 在线 / 厂商）；
- `AudioDeviceProbe.run(uid:seconds:channelCount:options:log:)` —— 建环（`HarnessAudioRing`）+ `AudioDeviceInput`，跑 N 秒，
  自带一个按 48 kHz 节奏读环的消费者；
- `AudioDeviceProbe.report(_:)` —— 块数、断裂、hostTime 单调性、块间隔分布、d / w 延迟、IOProc 计数。

测试 `AudioDeviceInputTests.testAudioDeviceProbe_listsDevicesAndRunsOne` 已经把这三个都跑过一遍。

## 差什么

命令行入口 `Packages/SwitcherInputs/Sources/switcher-input-probe/main.swift` **不在 W2-A2 的可改目录里**
（docs/OWNERSHIP.md 的 W2-A2 行只有 `Sources/SwitcherInputs/`、`Sources/SwitcherInputsHarness/`、
`Tests/SwitcherInputsTests/`、`Tests/Fixtures/`），所以没接。差这一段（放在 `case "hotplug":` 之前即可）：

```swift
case "audio-device":
    if let uid = opts.string("uid") {
        let seconds = opts.double("seconds", 10)
        var audioOptions = AudioDeviceInput.Options()
        if opts.has("no-force-48k") { audioOptions.forceSampleRate48k = false }
        if opts.has("no-convert") { audioOptions.convertSampleRate = false }
        let run = try AudioDeviceProbe.run(uid: uid, seconds: seconds, channelCount: opts.int("channels", 2),
                                           options: audioOptions) { print("[\(stamp())] \($0)") }
        for line in AudioDeviceProbe.report(run) { print(line) }
        exit(run.breaks == 0 && run.nonMonotonic == 0 && run.state == .live ? 0 : 2)
    } else {
        for line in AudioDeviceProbe.deviceLines() { print(line) }
    }
```

顶上的用法注释同时加一行：

```
//   switcher-input-probe audio-device [--uid <deviceUID> --seconds N] [--channels 2] [--no-force-48k] [--no-convert]
//                                             纯音频设备输入：列设备 / 跑 N 秒报块数、断裂、hostTime 单调性、块间隔分布
```

## 谁来做

哪个会话拿到 `Packages/SwitcherInputs/Sources/switcher-input-probe/` 的归属就顺手加（W3-A 的 `w3-inputs2` 行也没有它；
最省事的是下一个检查点用胶水额度，或者在 OWNERSHIP 的 W2-A2 行补上这个目录）。不接也不影响本会话的测试和交付。
