归属会话 / 分支：W1-E / w1-outputs（SwitcherOutputs/Encoding/AudioEncoder.swift）
发现于：W2-D（w2-stream），StreamingTests.StreamOutputTests.testReconnectGivesUpAfterMaxAttempts，main 2290b4e
现象：`AudioEncoder.finish()` 在一块 PCM 都没喂过的情况下调用，`drain()` → `emit()` 里 `hostTime(ofFrame:)` 因 stamp 环为空返回 `.zero`，
      再减 priming 的 44 ms → `HostTime - HostDuration` 结果为负 → "Fatal error: Negative value is not representable"，进程崩。
复现步骤：`let e = try AudioEncoder(configuration: .init()); e.finish()`。
严重级：S2（推流 / 录制在音频还没来就 stop 的路径上会崩；W2-D 用 `framesIn > 0` 才 finish 绕开，StreamOutput.audioLoop 有注释）。
猜测原因：`emit` 里 priming 偏移的减法没有下限；stamp 为空时应直接不发包（`finishing && fifoWrite == 0` 就 return）。
建议修法：`finish()` 开头 `guard fifoWrite > 0 else { finishing = true; return }`；或 `emit` 里用 `HostTime.zero` 钳住。
