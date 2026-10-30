# NDI 发送（源 = 输入 m）：输入 m 换来源时新来源的音频注册走了延后重试，这路 NDI 之后一直没声音

归属会话 / 分支：App 会话（`App/Sources/Engine/OutputRuntime.swift` 的 NDI 发送接线：`attachNDI` 自 W3-E4，`followInputAudioSlots` 是 W5-Q 加的），由 G12 分派。
不是 W3-A 的 NDI 输入：prompt 133 第 3 条以为在 `Packages/SwitcherInputs/Sources/NDI/`，Codex 那条用例看的其实是 NDI **发送**端的音频挂件。
发现于：W2-A6（prompt 133 第 3 条，核 Codex 2026-10-22 审查"保留线索"里的"NDI 换源等待音频重试后是否漏重挂"）。读的是 main bf149e2（= g11）；
w5-app-closeout-2（6b3d03f）上 `attachNDI` 同样写法。**只做了静态确认，没有动态复现**（App 用例不归本路）。

现象（代码链）：
1. `SwitcherSession.pollSnapshot` 先 `inputs.reconcile`、后 `outputs.reconcile`（SwitcherSession.swift:349–351）。
2. `InputRuntime.replaceSource`（InputRuntime.swift:170–192）：`audio?.unregister(number:)` → `old.input.stop()` → 建新输入 → `audio.register(number:ring:)`。
   `AudioEngine.unregisterInput` 只把旧槽标成 removing、淡出 `removalFadeBlocks`（约 16 ms）后才由控制循环摘掉（SwitcherAudio AudioEngine.swift:232–240），
   这期间 `slots[n]` 还在，新的 `registerInput` 撞 `inputAlreadyRegistered`，`AudioInputRegistration` 30 ms 后重试（AudioInputRegistration.swift:62–77）；
   重试成功之前 `registered` 里没有 n。旧输入的 `stop()` 比淡出快就会走到重试（推测：纯音频设备换设备、文件输入这类）；`stop()` 慢的（合成源要等一帧、
   摄像头 `stopRunning`）撞不上。Codex 的宿主探针用的是合成源，`registerRetries = 0`、音频块 193 → 381，所以当时没命中重试窗口。
3. `OutputRuntime.reconcileNDI`（OutputRuntime.swift:784–787）：源输入换了来源 → `detachNDI`（摘掉音频挂件、从 `inputAudio` 删掉）→ `attachNDI`：
   `audioSource = registeredInputs.contains(m) ? .input(number: m) : nil`（:852）。重试还没成功就是 nil，**不建 AudioAttachment**。
4. 30 ms 后重试成功 → `registration.onRegistered` → `followInputAudioSlots`（:694）。它只遍历 `inputAudio` 里已有的挂件，这路 NDI 没有挂件，所以什么都不做。
   结果是这路 NDI 发送此后不再有音频块（`entry.audio` 为 nil），直到这路输出被重新对一次（关了再开、改设置、再换一次来源）。
   对照：ISO 录制换来源时不摘也不挂（W5-P：tee 不换），挂件一直在 `inputAudio` 里，重试成功后由 `followInputAudioSlots` 跟上，没有这个问题。

复现步骤（给 App 会话写成用例）：
- 搬 Codex 的 `testNDI_SourceReplacementMustRestoreAudioAfterRegistrationRetry`（reports/codex-bug-audit-20261022-tests/Audit20261022AppTests.swift.txt:66），
  把被换的输入改成 `stop()` 快的来源（例如两路合成 PCM 驱动的纯音频输入），先断言 `session.audio.registerRetries` 涨了（真进了重试窗口，不然用例测不到），
  再断言 `ndiSenders[n]?.audio?.token != nil`、`audioBlocksSent` 接着涨。
- 预期修前：`registerRetries ≥ 1`，`audio == nil`，`audioBlocksSent` 不涨。

严重级：S1（功能错，节目能继续；NDI 收看端没声音，要关开这路输出才回来）。按测试标准 §6 字面定，等用户改口。

建议改法：`onRegistered` 里 `followInputAudioSlots` 之后，再给在跑、源是 `.input(n)`、`audio == nil` 的 NDI 发送补挂（`entry.audio = attachAudio(sender, source: .input(number: n))`）。
这时新来源已经注册上，槽位就是新的，不会挂到还在淡出的旧槽上（W5-Q D06 边角的口径）。另一种做法是 `attachNDI` 对 `.input(m)` 一律建挂件（token 先空着）、交给
`followInputAudioSlots`，但重试窗口里 `slot(forInput:)` 还是旧槽，`addConsumer` 会挂到旧槽的 tap 上，要另外处理。纯视频来源（图片等，没有环、永远不注册）
两种做法下都不发音频块，与现在一样。
