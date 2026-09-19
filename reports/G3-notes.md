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
- G3 自己的提交（各包 0 行、App 0 行）：3ac3f8c（check-rt-symbols 适配 Xcode 27）、e329516（headless 换 AudioEngine、--iso-audio、--preset g3）、d7099fa（gate3 工具）、
  0dc2b0f（清单、提案改号、到达余量裁定）、dfd7c85 / e97fe51（报告）、10942e4（netem 单实例锁）、fc55f97（第一次 gate 结论、收尾时序修正、E2 不适用判定）、
  以及第二次 gate 结果的提交。
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
| 4 | w2-stream | 绿 | SwitcherOutputs `--skip MediaMTXTests`（它要 release frameprobe，BLOCKED-Metal）：W1-E 18/18（434 s）、StreamingTests 21/21、NDISendTests 8 个（2 跳过：人工 Studio Monitor、"无 SDK"用例——SDK 已装）全绿 | HaishinKit 2.2.5 首次解析 |
| 5 | w2-app | check-ownership 报 `docs/OWNERSHIP.md`（冲突解决算 G3 手改，G3 行没有 docs/；见 §7 第 1 条） | App：BLOCKED-Metal | — |

4.6 整仓 `make test`（用户装好 Metal 工具链后于 18:4x 跑，Xcode 27.0 / Swift 6.4；SwitcherCore、SwitcherInputs 由 G3 在 22:2x 再跑一遍核对）：全绿。

| 包 / 目标 | 结果 |
|---|---|
| SwitcherCore | 148 个：SwitcherContractsTests 48、SwitcherEngineTests 73（含 W2-C 提案 003 的 4 个、W2-E AudioBridge 10 个）、SwitcherRenderTests 27，0 失败 |
| SwitcherInputs | 28 个，4 跳过（摄像头 3 个 BLOCKED-权限：xctest 的责任进程没有相机用途说明；S5 BLOCKED-硬件），0 失败 |
| SwitcherAudio | 87 个（W1-D 52 + W2-E 35），5 按环境跳过（真设备 / 回环），0 失败 |
| SwitcherOutputs | W1-E 18（434 s）+ StreamingTests 21 + NDISendTests 8（2 跳过：人工 Studio Monitor、"无 SDK"用例）；MediaMTXTests 单独由 gate3-net 跑 |
| SwitcherControl | 28，0 失败 |
| SwitcherTestKit | 49，0 失败 |
| 两个工具冒烟 | switcher-headless 0.1.0 / frameprobe 0.1.0 |
| App（xcodebuild test） | 14 / 14 通过（xcresult `.build/DerivedData/Logs/Test/Test-Switcher-2026.09.15_18-52-24-+0800.xcresult`） |

`xcodebuild` 全程刷 `DVTCoreDeviceCore` 加载失败 / `CoreSimulator is out of date (1051.55.0 < 1171.7.0)` 的红字：Xcode 27 的首次启动任务没做（`xcodebuild -checkFirstLaunchStatus` 返回 69），
CoreSimulator 框架还是 26.x 的；只影响模拟器，macOS 测试不受影响。想清掉：`sudo xcodebuild -runFirstLaunch`。

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
8. **E7–E9 第一次跑（19:01–19:12）E8 失败，是工装问题不是推流问题**：下午 15:06 起的 `sudo scripts/netem.sh serve` 一直没关（另一个终端），晚上按 G3 说明又起了一个，
   两个代理循环抢同一个 `netem.request`——一个读到完整行、另一个读到被截断的空文件（跑了空命令、回了用法文本），两个 `pfctl` 同时装规则（`DIOCADDRULE: Resource busy`），
   第 4 次封端口没封上 → 30 s 没判断线 → 该次"重连"记成 20.23 s；其余 9 次 0.10–1.12 s，E7（邻路 0 丢帧）、E9（误差 0.00%）都过。
   证据：代理终端日志里的空 `收到：` 行与用法文本、`ps` 里 15:07 起的代理进程。修：`netem.sh serve` 单实例锁 + 原子认领请求（10942e4），`gate3-net.sh` 数到多于一个代理就拒跑。
   **用户 2026-09-18 杀掉旧代理后重跑 `make gate3-net`：E7 / E8 / E9 3 / 3 通过**，E8 10 / 10 重连，放开后 0.08–1.10 s（断线判定 9.0–9.2 s）（reports/G3-net.md）。
9. **第一次 10 分钟 gate（22:39–23:02，reports/G3-run-10min-run1.md）V4 差 1 帧、E2 量不出，都不是切换 / 编码的问题**：
   - V4：设计外 1 帧全在 stats 最后一行（tick 35999）。headless 的等待循环 100 ms 看一次时钟，最后一拍派完到停视频源之间 60 fps 的源又推了 5 帧，
     3 格候选表挤掉 2 帧记成 dropped（8 号输入 pushed 36005 / consumed 36000 / dropped 2；4、6、7 号各 1，在 +1 帧余量内；5 号的 3 次 drop 在 102 / 269 / 435 s，是 +100 ppm 的设计内）。
     frameprobe 在播段口径 0。修：最后 30 拍改 2 ms 轮询、最后一拍派完立刻停视频源（Tools/，各包 0 行），重跑见下一节。
   - E2：灰底合成源整段只压出 0.101 Mbps（设定 6 Mbps），VideoToolbox 不会往目标码率填充，"误差 98.9%"没有可判的对象。E2 的判定以 W1-E `VideoEncoderTests`（0.57% / 1.067×）
     和 W2-D `MediaMTXTests.testE2E3`（0.61% / 1.050×，噪声内容，本次 `make test` 里跑过）为准；gate3-report 对"平均码率 < 25% 设定"标"本场景不适用"，不改阈值；
     合成源加噪声底纹的单子 `reports/issues/G3-w1-testkit-synthetic-noise-for-E2.md`（W1-A，契约要加 Background case → 提案 006）。
   - E5（信息项）：音轨比视频长 169 ms（第二次 24.1 ms；运行间差来自摘消费者的时机），就是第 2 条 W1-E 的越界块问题；20 ms 线只差 4 ms，W1-E 加"预告停止拍"即可归零。
   - S2（信息项，10 分钟整段拟合）：RSS 820 → 834 MB（第二次 818 → 839），其中 +9 MB 在前 90 s（预热）、+4 MB 落在 C4 的 12000 条命令期间（240–270 s），之后 300 s 平的；
     停机后 736 MB。要判 S2 得等 W4-A 的 8 小时；C4 期间的 +4 MB 提醒 W2-C 看一眼命令日志 / 回执历史是否有界。
   - 其余 15 项都过：A2 整秒闪光 379 对均值 0.000 ms（G2 时 −18.3 ms，W2-E 的对齐延迟 / PTS 修正生效）、A4 五个文件 click 极差 0.188 ms、
     V6 恰在第 1000 拍且 147 次 Cut 全干净、V7 曲线 0.344 帧 / T-bar 映射误差 ≤ 0.78%（目标 1% 也过）、C1 50/50 max 16.98 ms、C3 35795 帧 0 不一致、C4 12000/12000。
10. **App 一期只接了合成源**：摄像头 / 文件 / 录制 / 推流 / 音频 / API 的 App 接线约 170 行，超过检查点的 `~App/:50`，没做（§7 第 3 条）；人工清单里给了 headless 等价物。

## 7. 对契约 / 流程的疑问（用户 2026-09-18 拍板："四个拍板按照你的方案来"）

**拍板结果与落地**（提交在 g3 分支）：
- 第 1 条 docs/ 归属：docs/OWNERSHIP.md G3 / G4 行加 `docs/checklists/` `docs/OWNERSHIP.md` `docs/plan/prompts/`，补充规则 5 改成脚本实际的算法、加规则 6（检查点可写清单 / 改归属表 / 加续做 prompt）。
- 第 2 条 契约提案：001（A + B）、004、005 标已批，与已批的 002 一起由契约会话 P2 落地——prompt `docs/plan/prompts/41-P2-契约落地.md`，OWNERSHIP 加 P2 行；006（合成源噪声底纹）新写，待批。
- 第 3 条 App 接线：开 W2-B2 会话——prompt 43，分支 `w2-app-2`，OWNERSHIP 加行。
- 第 4 条 到达余量：裁定生效，W1-B2 会话——prompt 42，分支 `w1-core-2`，含提案 005 的引擎侧。
- 顺带落成 prompt 的续做（用户可选开）：44 W1-A2（噪声底纹 + frameprobe 三个修正）、45 W1-E2（录制器收尾 / 编码器崩溃，E5 才能过）、46 W1-D2（混音器收口 / 就绪年龄 / tap 点）。
- 续做分支都从 G3 合入后的 main 开；P2 先于 42 / 44 更顺（字段先有）。

原疑问原文：

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

## 10. 出口条件结论（G3 prompt 第 4 条：M1 切换 / M2 音频 / M3 输出 / M5 控制）

数值以 reports/G3.md 自动部分为准：10 分钟 G3 场景第二次运行（23:1x–23:3x，提交 fc55f97）= 正式记录，**19 项自动判定 18 项通过、E2 本场景不适用**；
第一次运行留档为 G3-run-10min-run1.md（V4 差 1 帧的收尾时序问题已修，第二次 0）。基线 baselines/g3-m5max.json 取第二次。

| 里程碑 | 指标 | 结论 | 依据 |
|---|---|---|---|
| M1 切换 | V6 | 通过 | Cut 恰在第 1000 拍、前后无混合帧；全程 147 次 Cut 全干净（硬性） |
| M1 切换 | V7 | 通过 | Fade 30 拍曲线最大偏差 0.344 帧（≤ 1）；T-bar 25 / 50 / 75% 映射误差 ≤ 0.78%（≤ 2%，目标 1% 也过） |
| M1 切换 | V1–V5（回归） | 通过 | 第二次：V1 avg 1.78 / p99 2.04 ms、V2 0、V3 p99 0.037 ms、V4 精确核算设计外 0（两个口径）、V5 0；第一次 V4 差 1 帧是收尾时序（§6 第 9 条），修后为 0 |
| M2 音频 | A1 | 通过 | dropouts + underruns 0（硬性）；泵线程流式不连续 0；正式离线口径待 W1-A 把检测器搬进 frameprobe |
| M2 音频 | A2 | 通过 | 整秒闪光 379 对均值 0.000 ms（≤ 16.7，目标 5） |
| M2 音频 | A3 | 通过（10 分钟外推） | 斜率 × 8 h 0.00 ms；W2-E 真设备 60 分钟 0.20 ms；8 小时归 W4-A |
| M2 音频 | A4 | 通过 | PGM + 4 路 ISO 音轨同一事件 click 极差最大 0.208 ms（第一次 0.188；≤ 16.7，目标 1） |
| M2 音频 | A5 | BLOCKED-硬件 | 需要音频接口回环线；W2-E 脚本 `testA5_monitorLatency_loopback` 就绪；默认对齐延迟 42.67 ms 与 ≤ 20 ms 目标冲突（W1-D 3-4） |
| M2 音频 | A6 | 通过 | W1-D：响度 0.007 LU / 真峰值 +0.02 dB（EBU 3341 / 3342） |
| M2 音频 | A7 | 通过 | W1-D 离线 10 min + 真设备 1 min、W2-E 全部实时用例 0 违规（硬性）；check-rt-symbols 绿 |
| M3 输出 | E1 | 通过 | PGM + 4 路 ISO 录制器 skipped 0 |
| M3 输出 | E2 | 通过（专项用例） | L2 场景灰底压不出码率（不适用，§6 第 9 条）；W1-E VideoEncoderTests 0.57% / 1.067×、W2-D testE2E3 0.61% / 1.050× 都在本次 make test 里过 |
| M3 输出 | E3 | 通过 | 299 个关键帧间隔全部恰好 120 |
| M3 输出 | E7 | 通过 | 邻路网络丢帧 0 / 0、编码器跳帧 0（硬性）；第一次 gate3-net 已过 |
| M3 输出 | E8 | 通过 | 重跑（2026-09-18，单代理）：10 / 10 重连，放开后 0.08–1.10 s（断线判定 9.0–9.2 s），≤ 15 s（目标 ≤ 5 s）全部满足；第一次 9 / 10 是双代理工装问题（§6 第 8 条） |
| M3 输出 | E9 | 通过 | 5 分钟 70% 带宽，软件报告丢帧与落盘缺帧误差 0.00%（≤ 5%，目标 1%） |
| M5 控制 | C1 | 通过 | 50 / 50，max 16.87 ms（≤ 1 拍 + RTT） |
| M5 控制 | C2 | 通过 | 相对拍点 p99 0.39 ms；纯传输 p99 0.87 ms（≤ 50，目标 20） |
| M5 控制 | C3 | 通过 | 35795 帧 0 不一致（硬性） |
| M5 控制 | C4 | 通过 | 12000 / 12000，0 空洞 0 乱序（硬性） |
| — | S5 | BLOCKED-硬件 | 无 USB 摄像头 / UVC；docs/checklists/G3.md 第 6 条，`hotplug-timer.sh` 就绪 |

人工检查（docs/checklists/G3.md）未做：App 接线归 W2-B2（prompt 43）做完再按清单走；清单里的 headless 等价物现在也能做。

**G3 结论：通过。** 自动项（V1–V7、A1–A4、E1、E3、E7–E9、C1–C4）全部通过，E2 以专项用例通过；A5 / S5 BLOCKED-硬件；人工清单等 W2-B2 接线后走。
合并 g3 → main 由用户裁定（同 G2，`git merge --no-ff g3`）。

## 11. 续做分支合入（G3 检查点，2026-09-19；用户："看一下你安排好的那些吧，合并一下"）

g3 先 fast-forward 到 main 2fdf52d（G3 + P2 合入后），再按 `--no-ff` 合入五个续做分支（都从 2fdf52d 开，文件集两两无交集，**零冲突**）：

| 合并提交 | 分支（prompt） | 提交数 | 报告 | 关键结果（数字出自各自报告） |
|---|---|---|---|---|
| 36c68c9 | `w1-core-2`（42 W1-B2） | 4 | reports/w1-core-2.md | 到达余量 7 条裁定全部落地（初值 d₀ + 保护带、饿死保护、上限 d_min + 一帧 + 保护带随时生效、保护带按抖动跨度、8 × 1 s 时间窗 + 每块 8 个最大样本 + 起流块作废、每路参数、提案 005 引擎侧）。真机内置相机 L1：修前 avg 2.3–4.1 帧 / p99 4.1–5.1 → 修后 avg 0.3–1.5 / p99 0.4–2.2 / max ≤ 2.3 帧，起流 nil 拍 15 次全 0；`per_input.latency_ms` 与 W2-A 参考差 ≤ 0.002 ms；gate2 / gate3 各跑 V4 精确核算全 0。SwitcherEngineTests 86 个 |
| 8d288e2 | `w1-outputs-2`（45 W1-E2） | 4 | reports/w1-outputs-2.md | 录制器自己截两轨到边界拍：E5 停止边界 封口 85–86 ms、两轨差 0.00–0.04 ms（阈值 20 ms）；预告停止拍 `setStopTick` 两轨差 0.00；`stop(atTick:)` 可在边界前调、越界块入口就丢并计数；E6 max 0.803 s；`AudioEncoder.finish()` 空喂不崩。SwitcherOutputsTests 25 个（E1 过喂加 8× 档） |
| 5ec282c | `w1-audio-2`（46 W1-D2） | 5 | reports/w1-audio-2.md | W2-E 退回单 3-1…3-5 全部落地：淡变收帧数、走满精确 0 / 1（AFV 尾巴 0.843 → 0.109 dB，判到 −40 dB；Cut 后严格 0）；就绪目标年龄 10 次 959.00（真设备 1263 ± 1）、延迟线残差 0；耳机可绕过对齐延迟线（默认绕过，A5 预算 ≈ 17 ms，仍 BLOCKED-硬件）；ISO tap 推子后 AFV 前；A7 离线 10 min + 真设备 1 min 0 违规。SwitcherAudioTests 62 + IntegrationTests 39 |
| 2bc6a49 | `w1-testkit-2`（44 W1-A2） | 4 | reports/w1-testkit-2.md | 噪声底纹 GPU 生成（逐像素等于契约 `TestPattern.draw`）：每帧 GPU 0.13 ms / CPU 0.04 ms（CPU 参考实现 1.1–1.7 ms）；8 路 1080p60 真管线进程 CPU 20.7%（CPU 版 65.6% 超 S3）；噪声源 E2 6.000 Mbps = 100% 设定、10 s 滑窗 1.34%、峰值 1.082×。frameprobe av：推流落盘文件 A2 +64.000 → 0.000 ms（容器偏移 + priming）、A2 按整秒拍配对判、`--discontinuities`（A1 第三项）。SwitcherTestKitTests 62 |
| eb04184 | `w2-app-2`（43 W2-B2） | 5 | reports/w2-app-2.md | G3 清单末表七个接缝全接（InputFactory / 命令总线 + 快捷键 / API + MIDI / AudioEngine / Recorder / StreamOutput / StatsPublisher，约 1000 行 App）。xcodebuild test 26 个：25 过、1 跳（内置摄像头，BLOCKED-权限）；录 5 s 两轨 5.0000 s；API cut applied true；音频引擎起停 20 次 RSS 平；推流 10 s 645 帧 0 丢。越界 1 处：project.yml 4 行（见下裁定 1） |

合入后（75257e9 之前的树）：`make build` 六个包 + 两个工具 + App 通过；**`make test` 全绿**（11:09–11:50）：

| 包 / 目标 | 结果 |
|---|---|
| SwitcherCore | Contracts 27 + Engine 86 + Render 58，0 失败 |
| SwitcherInputs | 28（4 跳过：摄像头 TCC） |
| SwitcherAudio | SwitcherAudioTests 62（2 跳过）+ IntegrationTests 39（3 跳过：真设备 / A5） |
| SwitcherOutputs | SwitcherOutputsTests 25 + StreamingTests 28 + NDISendTests 8（2 跳过）；W2-D 的 ThrottleProxy 用例这次没抖（问题单 W1E2-w2-stream-throttle-proxy-close-flaky.md 仍在） |
| SwitcherControl | 28 |
| SwitcherTestKit | 62 |
| 工具 | switcher-headless / frameprobe 冒烟通过 |
| App | 26：25 过、1 跳（摄像头，BLOCKED-权限） |

`make lint BRANCH=g3` 全绿（归属：合并提交只算手改，3 个手改文件 docs/OWNERSHIP.md、docs/checklists/G3.md、docs/plan/prompts/60）。

**合入后 10 分钟 gate3 复核**（`scripts/gate3.sh --minutes 10 --label 10min-followups --baseline baselines/g3-m5max.json`，12:0x–12:2x，load 2.8，机器上没有别的会话在跑；
产物 `.build/gate3/10min-followups/`，报告 reports/G3-run-10min-followups.md，基线不重打）：**自动项 18 / 19 通过、E2 本场景不适用**，与 G3 正式记录（fce834a 那次）同一结论，数值与基线的差在噪声内：

| 指标 | 合入后 | 与基线 g3-m5max.json 的差 | 说明 |
|---|---|---|---|
| V1 | avg 1.784 / p99 2.043 ms | +0.007 ms | W1-B2 在渲染线程多了每路 3 次原子写，看不出来 |
| V2 / V3 | 0 / 35940；p99 0.065 / max 0.100 ms | — / +0.028 ms | |
| V4 | 精确核算设计外 0（stats.jsonl 全程）/ 0（frameprobe 在播段）；帧号倒退 0 | — | 新的到达余量算法在合成源上与旧的一样是 0（8 路余量、dup / drop 与设计值逐路相符） |
| V5 / V6 / V7 | +0 帧；Cut 恰在第 1000 拍、147 次全干净；Fade 0.344 帧、T-bar ≤ 0.78% | — | |
| A1 / A2 / A3 / A4 | 0；整秒 379 对 0.000 ms；0.00 ms / 8 h；极差 0.208 ms | — | W1-D2 的混音器改动（帧数淡变、目标年龄、ISO tap 换来源）没动这些数；ISO 音轨照样有 click（tap 在推子后、总线路由之外） |
| E1 / E3 | 5 个录制器 skipped 0；299 个间隔全 120 | — | |
| E2 | 0.101 Mbps，本场景不适用 | — | G3Factory 还是灰底；换噪声归 G4（prompt 60 末节第 2 条） |
| C1 / C2 / C3 / C4 | 50 / 50 max 14.47 ms；p99 0.35 ms；35795 帧 0 不一致；12000 / 12000 | — | |
| E5（信息项） | 音轨 600.025 s，比视频多 24.7 ms（❌ 20 ms） | G3 正式记录那次 24.1 ms，同一现象 | **不是回归**：W1-E2 的录制器只裁 `stop(atTick:)` 之后到的块，headless 第 8 步的绕法（先等含边界的块送到、再 stop）反而把边界后 1.5 拍的音频先写进了文件；撤绕法后应 ≤ 1 块（G4 第 1 条） |
| S2（信息项） | 48.9 MB/h 拟合（RSS 819 → 844） | −19.6 MB/h | 10 分钟拟合仅供参考，G3 基线自己是 68.6 |
| S3 | CPU 50.5% / GPU 21.1% | +5.6% / +0.2% | CPU 含 apitest 客户端；噪声底纹换上后 G4 基线要重打 |


### 11.1 G3 在合并时做的裁定（技术项，检查点职责内）

1. **W2-B2 的 project.yml（4 行）**：App 目标必须链接 `SwitcherAudioIntegration` / `SwitcherStreaming` 才能 import AudioEngine / StreamOutput，没有别的办法；给 W2-B2 行加 `project.yml`（备注"只加 App 对本仓库包产品的依赖"，同 W3-C），不算越界。`check-ownership.sh w2-app-2` 绿。
2. **到达余量的上限锚点**（W1-B2 §4 第 1 条）：**默认保持裁定原文 `.windowMinimum`**。W1-B2 同一相机交替各 3 次的对照：`.sustainedMinimum` 延迟更高（p99 2.4–2.5、max 3.1 帧超阈值）且提前帧每块都有时退化成窗口最小值照样迟到。`.sustainedMinimum` 留作可选项（不推荐、已测），不再动。双峰相机（抖动跨度 22–25 ms > 一个节目帧）上每 10 s 10–16 次 3-1 节奏是这种源的必然，不再追。
3. **ISO 音轨口径**（W1-D2 §4 第 1 条）：按 prompt 46 的"推子后、AFV 前"（含用户增益 / 静音 / 声像 / 延迟补偿）定，不改；要"推子前"再加来源。监听点留在 `AudioEngineConfiguration.monitorPoint`（默认延迟线前），要不要进 Show 与对齐延迟一起等用户（W2-E §4 第 1 条）。
4. **录制器的四个新计数不进 Stats.encoder**（W1-E2 §4）：同意——`dropped` 口径是视频帧，音频样本丢失是排障项；A1 看混音器输出。
5. **Stats.encoder 里 idle 的输出占一项、录制起止拍提前 10 拍**（W2-B2 §4 第 4 / 5 条）：保持——契约写"与 outputs 里带编码器的输出同序"；VT 会话创建 64–80 ms 期间 `VideoEncoder` 静默丢帧，提前量必须留（W1-E 的 start 前排队是另一个可选改进，不阻塞）。
6. **`per_input` 的 L1 统计排除引擎 t0 之前进槽的帧**（W1-B2 §4 第 3 条）：保持与 W2-A 参考实现一致。

### 11.2 交给 G4 的活（已写进 docs/plan/prompts/60-G4-输入叠加.md 末节）

撤 headless 第 8 步的封口绕法并把 gate 的 E5 按 ≤ 20 ms 判；G3 场景八路换噪声底纹（提案 006 + W1-A2 已合入）、gate3-report 去掉 E2"不适用"分支、G4 基线重打；App `OutputRuntime.stopRecording` 简化（约 15 行）；复核 App 启动停顿单（reports/issues/W2B2-w1-core-startup-stall-pacing-drops.md）；ThrottleProxy 抖动单。

### 11.3 原本等用户定的 → 用户 2026-09-19 授权按 G3 方案落地（"那些等我定的你也按你的方案来"）

| 问题 | 来源 | G3 的裁定与落点 |
|---|---|---|
| `OutputState.enabled` 打开节目时的语义 | W2-B2 §4 第 2 条 | 文档里的 enabled 只对 headless 生效；App 打开任何节目文件（含 LastSession）都把 record / stream 的 enabled 清掉，输出只由用户动作起。**App 已做**：`ShowDocuments.stoppingOutputs`（load / loadAutosave 都过一遍）+ `testShow_openedFileDoesNotAutoStartOutputs`，App 胶水共约 35 行（额度 50）。写进提案 007 B-1 |
| A2 判"最大绝对值"还是"均值" | W1-A2 §4 第 1 条 | **最大绝对值**（更严；整秒配对）。测试标准 §3 A2 / §4 A2 改口径；`scripts/gate3-report.py` 改判 `a2_max`，均值 / 标准差照报；G3 三次运行都是 0.000，结论不变 |
| "整秒拍"的定义 | W1-A2 §4 第 3 条 | 闪光帧的节目拍号是标称整数帧率的倍数（60 → 整秒；59.94 → 每 1.001 s）；写进测试标准 §2.3 |
| 推流落盘文件的 A2 口径 | W1-A2 §4 第 2 条 | 按 ffmpeg 口径（音轨起点 = tfdt 偏移 + 加回 priming），AVFoundation 原生口径作对照；写进 §2.3 与 §3 A2 |
| `Stats.audio.discontinuities` 与离线口径 | W1-A2 §4 第 4 条 | A1 第三项以 `frameprobe av --discontinuities` 为准，stats.jsonl 的是流式信息项；写进 §2.3、§3 A1、§7 |
| `PacingOptions` 默认值 / 合成源到达相位进 §2.1 | W1-B2 §4 第 4 条、G2 §7 第 5 条 | 写进 §2.1（提前半帧到达、音频不提前；余量参数全套；噪声底纹） |
| V3 口径、V4 判法、GPU 口径 | G2 §7 第 3 / 4 / 6 条（G3 一直沿用） | 写进 §3 V1–V3、V4、S3 与 §7：V3 = jitter_ms（唤醒 − 拍点，每秒最大）p99 取各秒最大；V4 设计外按精确速率核算 +1 帧相位余量；GPU = IOKit Device Utilization |
| `per_input` 加 late 计数 | W1-B2 §4 第 2 条 | **不加**：只在 `PacingStats.lateFrames`（headless / 探针打印）；V4 的 dup / drop 看不见它是设计使然，gate 没有以它为判据的项 |
| 推流"x s 后重连"进 Stats | W2-B2 §4 第 3 条 | **不加**：底栏"重连中（第 n 次）"够用，退避秒数是 UI 装饰，不是指标 |
| 对齐延迟 / 监听点是否进 Show | W2-E §4 第 1 条、W1-D2 §4 第 2 条 | **进 Show**：`AudioState.alignmentFrames`（默认 2048）+ `monitorPoint`（默认延迟线前）——**提案 007**（待批 → 契约会话落地，W3-E 设置面板前） |
| `RecordSettings.directory` 相对路径相对什么 | W2-B2 §4 第 8 条 | headless 相对进程工作目录、App 相对 ~/Movies/Switcher（都已如此）；写进 CONTRACTS.md 字段注释——提案 007 B-2 |
| 录制停止边界写进 CONTRACTS.md | G2 §7 第 7 条 | W1-E2 已实现（`stop(atTick:)` 裁两轨、`setStopTick`、nil = 最后一帧的下一拍）；文字进 CONTRACTS.md——提案 007 B-3 |
| `Stats.encoder` idle 项、录制提前 10 拍、L1 排除 t0 前的帧 | W2-B2 §4 第 4 / 5 条、W1-B2 §4 第 3 条 | 保持（§11.1 第 5 / 6 条） |

测试标准的改动只有口径文字，**阈值一个没动**（文件头有修订说明；OWNERSHIP 的 G3 / G4 行加了这个文件，备注只准改口径）。W3-C / W3-E 的 prompt 末尾各加了一段"G3 定的"，G4 prompt 第 6 条改成已落地。
docs/contract-changes/ 本次新增 007（待批）。

合并后的 g3 → main 仍由用户做（`git merge --no-ff g3`）；之后 G4 从 main 开。
