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
   **需要用户杀掉旧代理后重跑 `make gate3-net`**（E8 必须 10/10）。
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
| M3 输出 | E8 | **待重跑** | 第一次 9 / 10 且一次 20.2 s——两个 netem 代理同时在跑（§6 第 8 条，工装）；杀掉旧代理后 `make gate3-net` |
| M3 输出 | E9 | 通过 | 5 分钟 70% 带宽，软件报告丢帧与落盘缺帧误差 0.00%（≤ 5%，目标 1%） |
| M5 控制 | C1 | 通过 | 50 / 50，max 16.87 ms（≤ 1 拍 + RTT） |
| M5 控制 | C2 | 通过 | 相对拍点 p99 0.39 ms；纯传输 p99 0.87 ms（≤ 50，目标 20） |
| M5 控制 | C3 | 通过 | 35795 帧 0 不一致（硬性） |
| M5 控制 | C4 | 通过 | 12000 / 12000，0 空洞 0 乱序（硬性） |
| — | S5 | BLOCKED-硬件 | 无 USB 摄像头 / UVC；docs/checklists/G3.md 第 6 条，`hotplug-timer.sh` 就绪 |

人工检查（docs/checklists/G3.md）未做：App 接线未完成（§7 第 3 条），用户回来后按清单里的 headless 等价物做或先定接线归属。

