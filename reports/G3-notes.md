# G3 检查点报告：M1 切换 + M2 音频 + M3 输出 + M5 控制（分支 g3）

人工部分。自动部分（每次 `scripts/gate3.sh` 运行一节）由 `scripts/gate3-report.py` 追加在本文件之后拼成 `reports/G3.md`；E7–E9 由 `scripts/gate3-net.sh` 出 `reports/G3-net.md`。

## 1. 版本 / 提交号

- 分支 `g3`（harness 分支名 `claude/g3-checkpoint-3e1078`，worktree `.claude/worktrees/wonderful-fermi-40fe5f`），从 `main` 2290b4e 开。
- 合入的五个分支（都从 main 2290b4e 开，各自报告在 reports/w2-*.md）：

| 顺序 | 分支 | 顶 | 提交数 | 合并提交 |
|---|---|---|---|---|
| 1 | w2-inputs（W2-A） | 2807b05 | 7 | 57bedb4 |
| 2 | w2-control（W2-C） | 3d20d92 | 14 | 43cbdf9 |
| 3 | w2-audio-integ（W2-E） | 14cdeda | 12 | 95b22e4 |
| 4 | w2-stream（W2-D） | 0f29596 | 10 | 89a36e4 |
| 5 | w2-app（W2-B） | ecff7bf | 6 | c448a5e |

- 合并全部零代码冲突：五个分支改动的文件两两无交集，唯一重叠是 `docs/OWNERSHIP.md`（W2-B 改 W2-B 行的 token、W2-C 改 W2-C 行，相邻两行 → git 判冲突），解决 = 两行各取各的。
- 版本号 0.1.0 不动（G5 的事）。

## 2. 机器 / macOS / 电源 / 温度

- Apple M5 Max，18 核，128 GB；macOS 26.6.2 (25G83)。电源适配器。
- **工具链换了**：2026-09-15 14:43 本机 Xcode 由 26.6（Swift 6.3.3）换成 **27.0 (27A266a，Swift 6.4)**。五个 W2 分支的数字都是 26.6 上跑的；G3 的所有构建 / 测试 / gate 在 27.0 上。
  - Xcode 27 的 SwiftPM 默认用 `swiftbuild` 构建系统（`native` 已标 deprecated）：`.build/` 布局变成 `.build/out/Products/<Config>/`（`.build/debug` 是指向它的符号链接）、
    目标文件在 `.build/out/Intermediates.noindex/<包>.build/<Config>/<target>-t.build/Objects-normal/arm64/*.o`。`scripts/check-rt-symbols.sh` 已适配两种布局（提交 3ac3f8c）；
    用 `--show-bin-path` 的脚本不受影响。
  - **Xcode 27 的 Metal 工具链是单独下载的组件，本机没装**（`xcodebuild -showComponent MetalToolchain` → uninstalled，需要的版本 27A266a；老的 17F109 资产是 26.x 的）。
    所有依赖 SwitcherRender 的包（SwitcherCore、SwitcherInputs、SwitcherTestKit、两个工具、App）编 `Compositor.metal` 时失败：
    `cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain`。解锁：用户跑 `xcodebuild -downloadComponent MetalToolchain`（约 688 MB 下载）；
    `xcodebuild -checkFirstLaunchStatus` 也返回 69（首次启动任务未做），可能还要 `sudo xcodebuild -runFirstLaunch`。
- 机器负载：合并期间 load 2.0，只有桌面端 Claude 在用 CPU；跑 gate 前再看。

## 3. 场景

- 节目 `scenarios/g3-show.json`（`switcher-headless make-show --preset g3`）：1080p60，8 路合成源——1 号 30 fps 灰 64 +音频（进 Master），2 号 60 灰 192 +音频（+100 ppm，只进 ISO），
  3 / 4 号 59.94 灰 96 / 128 +音频（−100 / +50 ppm，只进 ISO），5 号 60 +100 ppm、6 号 60 −100 ppm、7 号 60 ±3 ms、8 号 60；Overlay 1 = 8 号右下角 28% 画中画（cut 进出）；一路录制 H.264 6 Mbps + AAC。
- 场景 `scenarios/g3.json`（`make-scenario --preset g3 --minutes 10`）：第 1000 拍 Cut（V6）、第 3000 拍 Fade 30（V7 曲线）、3600 / 3660 / 3720 拍 T-bar 25 / 50 / 75%（各停 60 拍，V7 映射）、
  3780 拍推到 1 提交；120 s 起每 5 s Cut（切完 1 拍把 PVW 推到下一路，PGM 1 → 8 循环）；122.5 s 起每 30 s 开 / 关 Overlay 1。
- C 系列客户端（scripts/apitest）：C1 从 t0 + 150 s 起 50 次 cut（相位避开 5 s 切换点 ±0.4 s），随后 C4 两客户端 × 100 条/s × 60 s；C2 / C3 用整段快照。
- 与 M0 的差别写在 `Tools/switcher-headless/Sources/switcher-headless/Factories.swift` 的 `G3Factory` 注释里；两个 JSON 由工具生成后入库（scenarios/README.md 规矩）。

## 4. 合并记录：每合一个跑了什么、结果

工具链没有 Metal 工具链（§2），依赖 SwitcherRender 的包在合并当天编不了；所以"每合一个 make test"退化成"每合一个 make lint + 能编的包的 swift test"，
合并全部完成后再补整仓 `make test`（等 Metal 工具链装上；结果记在 §4.6）。

| 步 | 合入 | lint | 测试 | 备注 |
|---|---|---|---|---|
| 1 | w2-inputs | 绿（禁词 / 版本 / Package / 依赖方向 / 归属）；check-rt-symbols 需先修布局（3ac3f8c） | SwitcherInputs：**BLOCKED-Metal**（编 Compositor.metal 失败） | — |
| 2 | w2-control | 绿 | SwitcherControl 28/28 绿（Swift 6.4，5.9 s） | Hummingbird 依赖首次解析 |
| 3 | w2-audio-integ | 绿 | SwitcherAudio 87 个（52 + 35）全绿，5 个按环境跳过（真设备 / 回环）；SwitcherEngineTests（AudioBridge 10 个）BLOCKED-Metal（同包有 Render） | — |
| 4 | w2-stream | 绿 | SwitcherOutputs（去掉 MediaMTXTests：它要 release frameprobe，BLOCKED-Metal）：见 §4.6 | HaishinKit 2.2.5 首次解析 |
| 5 | w2-app | check-ownership 报 `docs/OWNERSHIP.md`（冲突解决算 G3 手改，G3 行没有 docs/；见 §7 第 1 条） | App：BLOCKED-Metal | — |

4.6 整仓 `make test`（Metal 工具链装上后）：待补。

## 5. G3 自己改了什么（只准动的目录：Tools、scripts、Makefile、scenarios、reports、baselines；各包 / App 胶水 ≤ 50 行）

各包 0 行，App 0 行（接线超额，见 §7 第 3 条）。

- `scripts/check-rt-symbols.sh`：适配 Xcode 27 SwiftPM 的目标文件布局；核对的目标文件数必须等于源文件数，否则报错（之前新布局下会因为文件名不带 `.c` 而静默通过）。
- `Tools/switcher-headless`：按 `reports/issues/W2E-g3-headless-audio-engine-wiring.md` 的补丁换用 W2-E 的 `AudioEngine`（删 `AudioPump.swift`；Package.swift 加 `SwitcherAudioIntegration` 产品；
  `extension Recorder: AudioBlockConsuming {}`；封口前等含边界的块送到再摘消费者）；`--iso-audio N`（A4）；`--preset g3`（G3Factory：节目 + 场景）。叠在 W2-C 的 `--api` / `StatsPublisher` 接线之上。
- `scripts/apitest/apitest.py`：`run --c1-start <秒>`（C1 延后开始，避开 V6 / V7 / T-bar 段）。
- `scripts/gate3.sh`、`scripts/gate3-report.py`、`scripts/gate3-net.sh`；Makefile `gate3`（L0 + L1 + 10 分钟场景）/ `gate3-run` / `gate3-1h` / `gate3-net`。
- `scenarios/g3-show.json`、`scenarios/g3.json`（工具生成）；`baselines/g3-m5max.json`（gate3 写）。
- `docs/checklists/G3.md`（人工清单；docs/ 不在 G3 行里，§7 第 1 条）。
- `docs/contract-changes/002-stats-per-input-latency.md` → `005-…`（W2-A 与 W2-D 撞号；W2-D 的 002 已批且被引用，改 W2-A 的），`reports/w2-inputs.md` 里的引用同步改。
- `reports/issues/W2A-w1-core-arrival-pacing-vs-camera-latency.md` 末尾加"G3 复核与裁定"（对 W1-B 的修法要求与验收标准）。

## 6. 已知问题与放行说明

（gate 跑完后补数字；先列合并时已知的。）

1. **摄像头 L1 在产品配置下 2.5–3.9 帧、起流黑屏 4 s**（W2-A 实测；根因是引擎到达余量的三处实现缺陷）。归 W1-B，修法要求与验收标准在问题单末尾。G3 不在胶水里关到达余量。S1。
2. **录制音轨比名义时长多 54–150 ms**（W1-E 录制器在边界之后到达的块照写；`stop(atTick:)` 只能在边界之后调）：E5 的"音视频轨道差 ≤ 20 ms"预计不过（信息项，不在 G3 出口清单）。
   封口拖死的问题 headless 已用"先摘消费者"绕开。归 W1-E（`W2E-w1-outputs-recorder-drift-check-before-stop.md`）。S2。
3. **`AudioEncoder.finish()` 没喂过块会崩**（W2-D 发现，StreamOutput 已绕开）。归 W1-E。S2。
4. **`frameprobe av` 对无 priming 信息的推流落盘文件偏 44 ms + 起始偏移**（W2-D 发现）：E8"重连后 A2"只能按 ffmpeg 口径（W2-D 端到端 0.0 ms）。归 W1-A。S2。
5. **A1 的第三项（波形不连续）没有正式的离线口径**：Stats 只有 dropouts / underruns（提案 004 待批），headless 摘要里的"不连续"是 AudioEngine 泵线程的流式启发式；
   按已知 click 位置排除的离线分析（30 行）要搬进 frameprobe（归 W1-A）。G3 判 A1 用 dropouts + underruns（硬性 0），第三项按流式计数记录。
6. W1-D 淡变收口的两个小尾巴（−20 dB 以下 0.5–0.9 dB；Cut 后 −44 dB 尾巴）：听感无影响，W2-E 的 AFV 判据已按 −20 dB 以上判。归 W1-D。S3。
7. 契约提案 001 / 002（推流字段，已批）/ 004 / 005 都还没落地：Stats.encoder 仍只有 skipped / bitrate，推流的帧数 / 网络丢帧 / 重连 / 状态在 `StreamOutput.counters`，
   录制的帧数 / 丢帧 / 磁盘剩余在 `RecorderCounters`，表读数在 `AudioEngineStatus`，L1 在 W2-A 的 harness。E7–E9 的判定读的是 W2-D 测试自己打印的 `StreamCounters`（不违反"三方同一份"——它们还没有第二份）。
8. **App 一期只接了合成源**：摄像头 / 文件 / 录制 / 推流 / 音频 / API 的 App 接线约 170 行，超过检查点的 `~App/:50`，没做（§7 第 3 条）；人工清单里给了 headless 等价物。

## 7. 对契约 / 流程的疑问（等用户拍板）

1. **docs/ 归属**：G3 prompt 要求写 `docs/checklists/G3.md`，合并冲突解决又改了 `docs/OWNERSHIP.md`，两者都被 `check-ownership.sh g3` 报越界（G3 行只有 Tools / scripts / Makefile / scenarios / reports / baselines）。
   请把 G3 行（以及 G4 行）加上 `docs/checklists/` `docs/OWNERSHIP.md`，或授权本次例外；G2 §7 第 1 条的"补充规则 5 文字"也还没改。
2. **契约提案的批与落地**（都在 docs/contract-changes/，状态见各文件）：
   | 编号 | 提出 | 内容 | 状态 | G3 意见 |
   |---|---|---|---|---|
   | 001 | W1-E | Stats.encoder 加 frames / dropped / disk_free_mb；AudioBlockConsumer 升契约 | 待批 | A 建议批（002 已批且建立在它之上）；B 建议批（W2-D、W2-E 三方各有一份同签名协议，升契约后 headless 的空扩展删掉） |
   | 002 | W2-D | Stats.encoder 加 reconnects / state | **已批** | 与 001 一起由契约会话落地；落地后 headless 的 `EncoderStatsSource`、StreamOutput.statsEntry、StatsWriter / Summary 跟改 |
   | 003 | W2-C | CommandReceipt.applied、MixerSnapshot.publishedAt、issuedAt 口径、SnapshotObserver、StatsPublisher | **已落地**（用户指示 W2-C 直接改） | 合并零冲突，其他分支不用改；G3 的 headless 已用 StatsPublisher |
   | 004 | W2-E | Stats.audio 加 discontinuities / meters | 待批 | 建议批：W2-B 调音台的表、W2-C API、A1 第三项都要它 |
   | 005（原 002） | W2-A | Stats.per_input 加 latency_ms / latency_max_ms | 待批 | 建议批：L1 是 §4 正式指标，现在只有 harness 能量；引擎侧算法提案里已写 |
   建议一次契约会话把 001 A/B、002、004、005 一起落地（都是 Stats.swift 加字段 + jsonKeys 快照 + StatsWriter/Summary 多几列 + 各填数方），然后各功能分支 rebase。
3. **App 接线谁做**：见 docs/checklists/G3.md 末表（约 170 行）。选项：(a) 授权 G3 超额接线；(b) 开一个短会话在 W2-B 目录接（`w2-app` 分支续做）；(c) 归 W3-E。G3 建议 (b)：接线要真跑摄像头 / 声卡 / MediaMTX，不是检查点的 15–30 分钟人工时间能覆盖的。
4. **摄像头到达余量**：裁定见问题单末尾——归 W1-B，改初值 / 饿死保护 / 余量上限 = d_min + 一个节目帧 / 保护带按抖动跨度；验收 L1 avg ≤ 1.5 帧、p99 ≤ 2 帧、无黑屏，V4 仍 0。需要用户确认这个裁定并开 W1-B 的续做会话。
5. **W2-E 留给验收的其它决定**（`reports/issues/W2E-g3-pending-changes-checklist.md`）：对齐延迟 `alignmentFrames` 要不要进 Show（2-3）、每路 AFV 开关（2-4）、W1-D 的 3-1…3-5、W1-E 的 3-6…3-8、W1-A 的 3-9 / 3-10。
   G3 意见：3-6（录制器封口先查 stopTime）必须修、3-7（预告停止拍）建议修（E5 才能过）、3-9（不连续检测进 frameprobe）建议修；其余记入已知问题，W3 前不阻塞。
6. **G2 §7 的 7 条疑问**（V3 口径、合成源到达相位进测试标准 §2.1、V4 判法、GPU 占用口径、录制封口边界写进 CONTRACTS.md）仍待拍板；G3 沿用 G2 的口径。

## 8. 人工检查（用户做）

docs/checklists/G3.md。App 没接线的项按清单里的 headless 等价物做，或等 §7 第 3 条决定后再做。

## 9. 下一个会话需要知道的坑

- **Xcode 27**：Metal 工具链要单独下载（§2）；SwiftPM 布局变了，找目标文件 / 产物一律用 `swift build --show-bin-path` 或同时匹配两种布局；`swift test --skip <suite>` 可用来跳过要外部工具的用例。
- **合并顺序与冲突**：五个 W2 分支文件级无交集，只有 OWNERSHIP.md 相邻行冲突；提案 003 的契约改动（加字段带默认值）对其他分支零影响。
- **headless 的封口顺序**：引擎停 → 等含边界的音频块（边界 + 对齐延迟 + 2 块 + 6 ms）→ 摘消费者 → 录制封口 → 音频引擎停；W1-E 修好 3-6 后可以先 stop 再摘。
- **G3 场景里 2–4 号的音频只进 ISO 不进 Master**：四个满幅 click 同刻叠加会削波；输入 tap 在 `slot->post` 上、与总线路由无关（sw_mix.c），所以 ISO 音轨照样有 click。
- **C1 客户端要 `--c1-start 150`**：前 2 分钟是 V6 / V7 / T-bar 段，客户端的 cut / setPreview 会把它们打乱。
- **V7 的 T-bar 映射**：frameprobe 没有专门子命令，gate3-report 用 `frameprobe frames` 的中心灰度（(gray − 64) / 128）在三个停留窗的中段（+10 … +55 拍）取均值判 ≤ 2%。
- **提案编号**：001 W1-E、002 W2-D（已批）、003 W2-C（已落地）、004 W2-E、005 W2-A；下一个用 006。
