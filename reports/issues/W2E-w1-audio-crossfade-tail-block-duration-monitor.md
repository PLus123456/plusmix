# 混音器交叉淡变的两个收口小问题、就绪年龄不可指定、耳机 / ISO tap 与对齐延迟

归属会话 / 分支：W1-D / `w1-audio`（`CSwitcherAudioRT/sw_mix.c`、`SwitcherAudio/AudioMixer.swift`）
发现于：W2-E / `Packages/SwitcherAudio/Tests/IntegrationTests/AFVTests.swift`（离线搭台，逐块电平对等幅曲线）

## 现象

1. **淡变时长只收块数**（`SW_CMD_CROSSFADE` 的 `i2` = 块，`duration_frames = blocks × default_block_frames`）：30 拍 @60 = 500 ms → 94 块 = 501.33 ms（+0.27%）。
   起点是样本精确的，所以误差全落在尾部：`cos` 的相对误差 = tan(θ)·dθ，p > 0.94（增益 < −20 dB）处 0.5–0.9 dB
   （实测：≥ −20 dB 的 173 块最大 0.36 dB；−20…−40 dB 尾巴最大 0.84 dB）。W2-E 的 AFV 用例只能把 ≤ 0.5 dB 的判据下限放在 −20 dB。
2. **淡变结束那一块的 afv 被覆盖**：`sw_xfade_block` 在时长走满时写 `afv = 0 / 1`，但它在 `sw_process_input` 之前跑，后者随后用
   `xfade_gain[frames − 1]`（cos(π/2·255/256) = 0.0061）覆盖 `slot->afv`；下一块 `slot_xf` 为 NULL，就从 0.0061 按 3 ms 一阶平滑到 0 ——
   Cut（1 块短淡）之后 from 路留一条 −44 dB 起、τ = 3 ms 的尾巴（实测块 1 RMS 7.8e-4、块 2 1.4e-4、块 3 2.3e-5）。听不见，但 "Cut 后严格为 0" 不成立。
3. **就绪年龄不可指定**：`sw_slot_prime` 从 `write_index − back` 开始消费，年龄 = 703 + 相位 [0, 256) 帧（P 256），每次就绪随机。
   W2-E 只能就绪后读 `ageSetpoint` 再用延迟线补到统一的 2048 帧（对齐延迟）。
4. **耳机 / 输入 tap 都在延迟线之后**：对齐延迟（默认 42.67 ms）一并进了 Headphones 总线与 ISO tap；A5（麦克风入口到耳机出口 ≤ 20 ms）
   只能靠"对齐延迟 0 + 目标 1 块 + buffer 128"的低延迟配置达到，与节目对齐不能同时要。ISO tap 在 AFV 增益之后，AFV 开着时非 PGM 的 ISO 音轨是静音。

## 复现步骤

`swift test --package-path Packages/SwitcherAudio --filter AFVTests`（把判据下限改回 0.01 就能看到 1、2）。

## 严重级

S3（听感无影响；影响测试判据与 A5 / ISO 的可达性）。

## 建议

- 1：`SW_CMD_CROSSFADE` 的 `i2` 改成帧数（或另加一条帧数命令），Swift 端 `crossfade(from:to:durationFrames:startHostTime:)`；W2-E 侧一行改动。
- 2：`sw_xfade_block` 最后一个样本的 p 用 `(elapsed + i + 1) / dur`，或把"走满 → 写 afv"移到 `sw_process_input` 之后。
- 3：`SW_CMD_ATTACH_INPUT` 加"目标年龄（帧）"参数：就绪时 `start` 按 stamp 外推到 `host_time − 目标年龄` 对应的帧，而不是 `write_index − back`；
  这样各路年龄天然一致，W2-E 的对齐延迟线只处理年龄 > 目标的残差。
- 4：给耳机送一个"延迟线之前 / 之后可选"的分支；输入 tap 加"推子前"来源（`SW_INPUT_TAP_BASE` 之外再一段），ISO 才不受 AFV 门控。
