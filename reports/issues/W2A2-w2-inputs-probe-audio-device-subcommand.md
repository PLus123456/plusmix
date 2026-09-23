# W2-A2 → 检查点：`switcher-input-probe` 的 `audio-device` 子命令差最后几行接线

归属会话 / 分支：`Packages/SwitcherInputs/Sources/switcher-input-probe/` 的归属（OWNERSHIP 的 W2-A 行，`w2-inputs`，会话已结束）→ 下一个检查点用胶水额度，或用户指派
发现于：W2-A2（分支 `w2-inputs-2`，2026-09-23）
现象：prompt 64 交付 4 要 `switcher-input-probe` 加 `audio-device` 子命令。实现全在 **SwitcherInputsHarness**
（`Sources/SwitcherInputsHarness/AudioDeviceProbe.swift`，W2-A2 可改的目录）：`deviceLines()` 列设备、`run(uid:seconds:…)` 建环 + 跑 N 秒、
`report(_:)` 出块数 / 断裂 / hostTime 单调性 / 块间隔分布 / d 与 w 延迟 / IOProc 计数；测试 `testAudioDeviceProbe_listsDevicesAndRunsOne` 跑过。
但命令行入口 `Sources/switcher-input-probe/main.swift` 不在 W2-A2 的可改目录里，所以 `switcher-input-probe audio-device` 现在报"不认识的子命令"。
复现步骤：`swift run --package-path Packages/SwitcherInputs switcher-input-probe audio-device` → `不认识的子命令 audio-device`。
严重级：S3（诊断工具缺一个入口；同样的功能测试里能调，节目不受影响）

## 做法（补丁，放在 `case "hotplug":` 之前）

```swift
case "audio-device":
    if let uid = opts.string("uid") {
        let seconds = opts.double("seconds", 10)
        var audioOptions = AudioDeviceInput.Options()
        if opts.has("no-force-48k") { audioOptions.forceSampleRate48k = false }
        if opts.has("no-convert") { audioOptions.convertSampleRate = false }
        if let map = opts.string("channels") { audioOptions.channelMap = map.split(separator: ",").compactMap { Int($0) } }
        let run = try AudioDeviceProbe.run(uid: uid, seconds: seconds, channelCount: opts.int("channels-in-ring", 2),
                                           options: audioOptions) { print("[\(stamp())] \($0)") }
        for line in AudioDeviceProbe.report(run) { print(line) }
        exit(run.breaks == 0 && run.nonMonotonic == 0 && run.state == .live ? 0 : 2)
    } else {
        for line in AudioDeviceProbe.deviceLines() { print(line) }
    }
```

顶上的用法注释加一行：

```
//   switcher-input-probe audio-device [--uid <deviceUID> --seconds N] [--channels 4,5] [--no-force-48k] [--no-convert]
//                                             纯音频设备输入：列设备 / 跑 N 秒报块数、断裂、hostTime 单调性、块间隔分布
```

`--channels` 是提案 014 的声道映射（设备声道下标，逗号分隔）。接完用内置麦克风跑一遍 `--uid BuiltInMicrophoneDevice --seconds 10`，
应当断裂 0、非单调 0、块间隔与块长的偏差 ≤ 0.01 ms（W2-A2 报告 §2 的探针那一行）。
