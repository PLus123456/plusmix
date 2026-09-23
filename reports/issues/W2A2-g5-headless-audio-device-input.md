# W2-A2 → 检查点（headless）：让节目文件里的纯音频输入在 headless 里也能跑

归属会话 / 分支：`Tools/switcher-headless/` 的归属（检查点 G 会话；W4-A 行只许"加参数"）→ 下一个检查点或用户指派
发现于：W2-A2（分支 `w2-inputs-2`，2026-09-23）
现象：`HeadlessRun.swift` 的输入表只接合成源 / 图片 / NDI，其它一律 `throw CLIError("headless 只接合成源 / 图片 / NDI：…")`。
节目文件里有 `.audio(deviceUID:…)` 的输入，headless 起不来。纯音频设备的**端到端** A2（设备采到的 click 与 PGM 闪光对齐，
见 `W2A2-user-manual-hardware-tests.md` 第 5 条）要靠它跑。
复现步骤：在 `scenarios/*-show.json` 的 inputs 里加 `{"number": 9, "name": "话筒", "source": {"audio": {"deviceUID": "BuiltInMicrophoneDevice"}}}` →
`switcher-headless run --show …` 报上面那句错。
严重级：S2（有绕过办法：App 里跑；headless 只是测试 / 长稳用）

## 做法（补丁要点，约 20 行）

1. 输入表的 `switch cfg.source` 加一支：
   ```swift
   case .audio:
       let ring = CAudioRing(channelCount: 2)
       let input = try AudioDeviceInput(config: cfg, audioRing: ring)   // 声道映射（提案 014）从 case 取
       engine.registerInput(number: cfg.number, slot: slot)              // 空槽：纯音频永远挑不到帧，画黑（契约 Input.videoSlot 注释）
       otherInputs.append(input)
       deviceAudioInputs.append((cfg.number, ring))
   ```
2. 第 2 步注册环：`deviceAudioInputs` 逐个 `audioEngine.registerInput(number:ring:hints:)`，`hints.producerBlockFrames = 1024`
   （设备 IO 块本机 512，走采样率转换时约 558；给 1024 稳妥，同 App 的摄像头 / DeckLink）。
3. 录制器 / NDI 发送 / `--iso-audio` 里判"有没有音频"的 `audioInputs.isEmpty` 换成"合成音频和设备音频都为空"；
   `--iso-audio` 的编号表把设备音频也算进去（或者只取合成源，看 A4 要什么）。
4. 启动 / 停止跟着 `otherInputs` 走就行（`AudioDeviceInput.start()` 不阻塞，stop 会还原它改过的设备采样率）。
5. 真设备跑的时候注意：`AudioDeviceInput` 会在设备不是 48 kHz 时试着把它设成 48 kHz（停的时候还原）；不想动设备就
   `AudioDeviceInput.Options.forceSampleRate48k = false`（走泵线程上的采样率转换）。
