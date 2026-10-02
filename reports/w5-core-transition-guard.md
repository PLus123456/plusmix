# W5-E 转场进行中拒收 setPreview / setProgram —— 报告（分支 w5-core-transition-guard）

日期 2026-10-01。prompt 90（第五波 · 止血；Q66 默认 (a)，用户 2026-09-29 批开）。机器 Apple M5 Max / macOS 27.0（26A428）/ Xcode 27，接电源（AC，电池 95%）；
同机有别的第五波会话在并行编译、跑测试（`uptime` 负载 4–11，W5-D 同时在跑 MediaMTX 推流用例），实时类、推流类用例的结果按这个背景看。
worktree `.claude/worktrees/w5-core-transition-guard-e2ff9a`，分支 `claude/w5-core-transition-guard-e2ff9a`（桌面端自动起的名），从 `main`（25af61f）开；
**`w5-core-transition-guard` 这个分支名指向同一个 HEAD**（`git branch -f w5-core-transition-guard`，同 W3-D 先例），`make lint BRANCH=w5-core-transition-guard` 与 G6 合并用它。
提交：`git log main..w5-core-transition-guard`。动了 prompt 指定的两个文件（MixerReducer.swift、ReducerTests.swift）；所有分支都允许的
`docs/contract-changes/023-小口径收口.md`、`reports/issues/` 三张单子和本报告；另按用户 2026-10-01 的指定（"W5-E 现在改"）动了目录外两个文件：
`Packages/SwitcherControl/Tests/SwitcherControlTests/APIServerTests.swift`（一行注释 + 两行断言）和 `docs/OWNERSHIP.md`（只改 W5-E 那一行，认领前者）。SwitcherContracts、docs/CONTRACTS.md、App 一个字没动。

## 1. 做了什么

| prompt 交付 | 落点 | 说明 |
|---|---|---|
| 1 reducer | `Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift` | `.setPreview` / `.setProgram` 的 guard 前面加 `!s.transition.isActive`：转场进行中原样返回 state（不改任何字段，状态机据此把回执 applied 置 false，API 仍是 200）。文件头补一段整套口径：进行中拒收 fade / setTransition / setTransitionParams / autoTransition / setPreview / setProgram，cut（立即完成）与 tbar（接管）照收 |
| 1 T-bar 推到一半算不算 active | 同上（注释）+ `testV6_tbarPartialCountsAsActive` | **算，而且现有定义已经包含，不用补**：契约里 `isActive = progress > 0 \|\| startTick != nil`，T-bar 没有 startTick，推杆在 (0, 1) 时 progress > 0。拉回 0 = 取消（progress 0、无 startTick），不算；推到 1 = 提交（对调并回到 0），不算。auto 转场从应用命令那一拍（progress 0、startTick 已记）到对调前一拍都算；对调那一拍状态机先 advance 再应用该拍的命令，所以排在那一拍的 setPreview 照常生效。契约的 isActive 一个字没改 |
| 2 契约文字 | `docs/contract-changes/023-小口径收口.md`（新建） | 第一节"转场进行中 setPreview / setProgram 拒收"：改什么（CONTRACTS.md §8 两行、§2.5 TransitionState 一句、`Command.swift` 两处注释的原文与改后）、为什么、影响谁、怎么迁移；表头给 P5 留了二–四节（container 废弃 / effects 口径 / InputConfig.color）。**状态：已批**（用户 2026-10-01："批，P5 落地"），由 P5 改 CONTRACTS.md / Command.swift 注释，本会话没动 |
| 用户指定：改必红用例 | `Packages/SwitcherControl/Tests/SwitcherControlTests/APIServerTests.swift`、`docs/OWNERSHIP.md` W5-E 行 | 用户 2026-10-01 选"W5-E 现在改"：`testAPI_wsEvents_helloSnapshotStatsReceiptAndTally` 在 Fade 进行中经 WS 发 setPreview，两行断言改成 applied = false、PVW 仍 1（顺带在 API 层覆盖新规则，对旧 reducer 会红），注释写明为什么；OWNERSHIP.md 的 W5-E 行认领这个文件和 OWNERSHIP.md 本身（自记，同 W1-A3 / W3-C2 / W4-D / UIA 先例） |
| 3 App 提示 | 本报告 §5 第 1 条 | 格子上以后的"转场 / Cut"按钮（94）和 Shift 点击在转场中置灰或提示"转场进行中"，reducer 已兜底；组合命令的坑一并写了 |
| 测试 | `Packages/SwitcherCore/Tests/SwitcherEngineTests/ReducerTests.swift` | 4 条带 ID 的用例 + 表驱动两行（auto 进行中拒 setPreview、T-bar 推到一半拒 setProgram）。先写、对着旧 reducer 跑：5 条红（断言失败 68 + 68 + 10 + 3 + 2 处），别的 15 条照旧绿；加两行 guard 后 20 / 20 绿。其中三条带状态机路径（回执 applied、快照、对调那一拍的边界） |
| 调用方排查 | — | 谁会在转场中发这两条（规则一变结果就变）：scenarios/m0、g3、g4.json 按状态机的顺序（每拍先 advance 再应用）模拟一遍，**0 处**；switcher-headless 的 M0 / G3 / G4 / soak 时间线都在转场结束后 d + 1 拍才发 setPreview；scripts/apitest 的 C1 在 x.7 s 相位发（G4 的转场 24 拍 = 0.4 s 内结束）；各包与 App 用例逐个看过、再全量跑。查出两处：SwitcherControl 一条 WS 用例必红、兼容层 / 批量的"setPreview + cut"组合结果变了（各一张问题单） |
| 问题单 | `reports/issues/` | `W5E-w2-control-apiserver-ws-setpreview-mid-fade.md`（规则带出来的必红用例；已按用户指定由本会话改掉，单子标了"已修"）、`W5E-w3-control2-compat-cut-input-mid-transition.md`（组合命令在转场中落不到点名的那一路）、`W5E-w3-compositor-3-multiview-meters-strict-reference-drift.md`（与本会话无关的环境红，干净的 main 上同样红） |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

| 测试 ID | 口径 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| `testV6_setPreviewRejectedDuringTransition` | Fade 30 拍（第 100 拍起）：第 s + 0 … s + 29 拍每一拍 setPreview(3) 与 setPreview(0) 都原样返回；第 10 拍发 setPreview(3) 之后转场走完 PGM 2 / PVW 1；Wipe / Zoom / Stinger 20 拍走到第 5 拍同样原样返回、走完 PGM 2。状态机：第 110 拍 submit setPreview(3) → 回执 applied = false、appliedTick 110，快照 sequence 1、PVW 2、progress 1/3；第 130 拍 PGM 2 / PVW 1 | 全部断言过 | 原样返回、applied = false、快照 PVW 仍 2、结束 PGM = 2 | ✅ |
| `testV6_setProgramRejectedDuringTransition` | 同上换 setProgram(3) / setProgram(0)：每一拍原样返回；走完 PGM 2 / PVW 1（切出去的是开始时的 1 号，不是 3 号）；三种转场；状态机回执 applied = false、快照 PGM 仍 1，结束 PGM 2 / PVW 1 | 全部断言过 | 同上 | ✅ |
| `testV6_setPreviewAcceptedAfterTransitionCompletes` | 对调那一拍（第 130 拍）setPreview(3) / setProgram(4) 照收、只动对应字段；Cut 打断之后、T-bar 推到 1 提交之后照收。状态机：同一个 Fade，第 129 拍排的 setPreview(4) 被拒（PVW 仍 2）、第 130 拍排的 setPreview(3) 生效（PGM 2 / PVW 3），之后 submit setProgram(4) 回执 applied = true | 全部断言过 | 结束后照常生效 | ✅ |
| `testV6_tbarPartialCountsAsActive` | T-bar 1/127（MIDI 最小一格）、0.25、0.5、0.99：isActive 真、startTick nil，两条命令原样返回；T-bar 接管进行中的 auto 转场（0.7）后也拒；拉回 0：isActive 假、照收 | 全部断言过 | 推到一半算进行中 | ✅ |
| `testW1B_reduce_everyCommand_beforeAfterTable` 新增两行 | "setPreview auto 转场进行中拒绝（W5-E）""setProgram T-bar 推到一半拒绝（W5-E）"：前后状态逐字段相等 | 过（34 个 case 覆盖不变） | — | ✅ |
| ReducerTests 全部 | 20 个（原 16 + 新 4） | 20 / 20 | — | ✅ |
| SwitcherCore 全包 `swift test` | Engine / Contracts / Render 三个测试包 | Engine **100 / 100**；Contracts 82：81 过、1 跳（`testP2_stats_oldGateFilesParse`：读 .build/gate2、gate3 的老产物，新 worktree 里没有）；Render 97：95 过、**2 红**（`MultiviewMetersTests.testV8_multiviewMetersFromStats`、`testV8_multiviewMetersWithRMS` 的"逐像素相同"） | 全绿 | Engine ✅；Render 两条红与本会话无关：SwitcherRenderTests 只链接 SwitcherRender，碰不到 reducer；另起干净的 main（25af61f）只跑这组，**同样两条、同样三处断言红**，参考图与现在的渲染差 PSNR 50.8–51.7 dB（9-27 重生成后应是 ∞）。问题单 W5E-w3-compositor-3-… |
| 其它五包 `swift test`（第一轮，16:36–17:17，同机另有两套 App 用例、一次 gate4、W5-D 的 MediaMTX 用例在跑，负载到 11） | 全部链接 SwitcherEngine | Control 58：56 过、**1 红**、1 跳（原有人工用例）；TestKit **71 / 71**；Inputs 109：98 过、11 跳（原有 BLOCKED）；Audio 104：98 过、5 跳、**1 红**；Outputs 105：96 过、3 跳（原有人工 / 无 SDK）、**6 红**（Streaming 34 个里 5 个、ISO 10 个里 1 个；VirtualCamera 12、Outputs 25、NDISend 9、External 15 没有红）。六包合计 726：695 过、21 跳、10 红。Control 那一条是规则带出来的用例不一致：`APIServerTests.testAPI_wsEvents_helloSnapshotStatsReceiptAndTally` 在 Fade 进行中经 WS 发 setPreview(4)、断言 applied = true（:274 得 false、:277 快照 PVW 得 1），不是产品 bug，见 §3 第 4 条与问题单。其余 8 个红都与转场无关、是负载 / 端口类：Audio `IntegrationRealtimeTests.testLifecycle_nullDevice_addRemove100Times_A1Zero`（dropouts 1）；Streaming E2/E3、E7、E8（`bind/listen 31940: errno 48` 端口被占）、E9、`ThrottleProxyTests.testBlockStopsForwardingAndCloses`（已有问题单 W1E2-…-throttle-proxy-close-flaky）——当时 W5-D 在跑同一组 MediaMTX 用例；ISO A4（3 个文件 518 / 600 帧、跳 82 帧，编码跟不上）。**这 7 条 18:22–18:40 在安静机器上逐条单独重跑，7 / 7 过**（Audio 生命周期 21.7 s、ThrottleProxy 0.3 s、E8 172.2 s、E2/E3 67.8 s、E7 75.2 s、ISO A4 13.3 s、E9 338.3 s）。**Control 那条按用户指定改完后（20:50）SwitcherControl 全包 58：57 过、1 跳、0 红** | 全绿 | ✅（Control 改后全过；其余 7 条重跑过） |
| App `make test-app`（18:16–18:21，等机器安静才跑） | 全部 App 用例；计数用 `xcrun xcresulttool get test-results summary`（`make test-app` 的 -quiet 吞掉用例行） | **99 个：97 过、2 跳、0 红**。跳的两条是原有 BLOCKED：`testInputs_builtInCameraLiveWithin5sAndPictureShows`（内建摄像头）、`testL1_virtualCameraEgress_requiresSignedExtension`（签名）。跟转场有关的 7 条都过：回车 Fade 冒烟、T-bar 拖到顶、转场按钮（Wipe 24 拍）、时长预设、转场参数只在转场中延后、MIDI 学 T-bar、默认快捷键表 | 全绿 | ✅ |
| `make gate4-run` 第一次（17:25–17:48，6c6a491）：**作废** | 场景 g4.json（第 1000 拍 Cut、3000 拍 Fade 30、T-bar、120 s 起五种转场轮流）+ apitest C1–C4 | 同机至少还有一个别的会话的 switcher-headless 在跑（load.log 120 个采样里 18 个同时看得到两个 headless，而 load.log 还漏掉最忙的那一个，见 §5 第 4 条），另有 App 用例与 xcodebuild，负载 4.2–8.7：V1 avg 11.5 / p99 29.2 ms、V2 1233 帧（3.43%）、V5 −1233。V6 判 ❌，原因只是第 1000 拍之前已丢 84 帧：frameprobe 按文件帧序给的拍是 916，按 pts 是 16.6667 s = 第 1000 拍，前 / 中 / 后帧无混合，全程 90 次 Cut 不干净 0 次；V7（Fade / T-bar 的窗口按帧序取，整体错位，T-bar 0.25 量成 0.995）、C1（45 / 50，差的 5 次是生效那一拍的帧丢了）同因。A1–A4、E1–E3、E5、C2–C4、S2、S3 全过。对照：另一个会话 17:05 在同样拥挤的机器上跑的 gate4（6355fdb）V2 85 帧、V1 p99 31.4 ms，丢帧在第 1000 拍之后，它的 V6 判过 | V6：恰好第 n 拍、Cut 无混合帧（硬性） | 不作数（环境） |
| `make gate4-run` 第二次（17:59–18:15，6c6a491） | 等机器连续 1 分钟安静（没有别的引擎 / xctest / App 用例 / 检查点脚本、8765 空着、负载 < 4）再跑；跑的 10 分钟里负载 1.3–3.5（中位 2.1），没有第二个引擎 | **"G4 自动项全部满足"，退出码 0**。**V6**：第 1000 拍 Cut，新 ID 1 首次出现在文件第 1000 帧 / pts 16.6667 s（= 第 1000 拍），前 / 中 / 后帧混合 False / False / False；全程 90 次 Cut，不干净 0 次。顺带：V1 avg 1.921 / p99 4.643 ms、V2 0、V5 Δ 0（36000 帧 = 36000 拍）、V7 Fade 最大偏差 0.252 帧 / T-bar 最大映射误差 0.33%、A1–A4 / E1–E3 / E5 / C2–C4 / S3 过、C1 50 / 50、C3 0 不一致。S2 75.4 MB/h（10 分钟整段拟合，报告自己标"仅供参考"、不算自动项；第一次是 6.65 MB/h，噪声大，与已知的文件输入泄漏同一现象，归 W2-A） | V6：恰好第 n 拍、Cut 无混合帧（硬性） | ✅ |
| `make lint BRANCH=w5-core-transition-guard` | 禁词 / 版本号 / Package.swift 约束、check-deps、check-ownership、check-links、check-rt-symbols | 全部通过：禁词无、版本号 0.1.0 一致、8 个包依赖方向对、归属：本分支改的 9 个文件（含用户指定的 APIServerTests.swift 与 OWNERSHIP.md 的 W5-E 行）都在允许范围内、164 个 Markdown 链接都能解析、CSwitcherAudioRT 无违规符号 | 全绿 | ✅ |

## 3. 没做的和原因

1. **选项 (b)"收下、完成后再生效"**：prompt 明确不做（要在 TransitionState 里多记"转场用的两路"，契约 + 渲染器都要改）。
2. **渲染器、App**：prompt 明确不做。渲染器不用改：转场中 program / preview 不再变，它照当前快照画就是开始时的两路。
3. **CONTRACTS.md 与 `Command.swift` 注释**：铁律 1，写成提案 023 第一节；用户 2026-10-01 批了，由 P5（prompt 99）照提案里的"契约文字"落地，本会话不动。
4. ~~SwitcherControl 那条必红的用例~~：本来不在本会话目录里（铁律 1），停下来问了用户；用户 2026-10-01 指定本会话改，已改（§1 最后一行），不再是遗留。
5. **兼容层 / HTTP 批量的组合命令**：`Cut Input=n`、批量 `[setPreview(n), cut]` 在转场中 PGM 落在原来那次转场的目标上（之前会是 n），口径归兼容层的会话（W5-M）定，本会话只写问题单。
6. **手册 / API 文档里"转场进行中"的例子**：docs/user/概念.md:46 与 :61、故障排查.md:80、en 两份、docs/api/README.md:46、examples.md:138 可以加上 PVW / PGM，归文档会话；docs/KNOWN_ISSUES.md:33（X19）归 G6 挪表。提案 023 "影响谁"里列了。
7. **MultiviewMetersTests 的环境红**：不是本会话的东西，也不该由功能会话重生成参考图（要用户裁定），只写问题单。

## 4. 对契约的疑问

1. **提案 023 第一节已批**（用户 2026-10-01）：只改契约文字（CONTRACTS.md §8 setPreview / setProgram 两行备注、§2.5 TransitionState 一句、`Command.swift` 两处文档注释），不加类型、不改 JSON、schemaVersion 不升；P5 落地。
2. **applied = false 不说为什么**：转场进行中被拒、目标已是该值、FTB 已到位都只是 applied = false。客户端要区分得自己看快照的 `transition.isActive`。要不要给 `CommandReceipt` 加个原因字段是契约变更，这次没提，只记一笔；兼容层回 "(no change)" 同理。
3. **转场中别的会改画面的命令没动**：removeInput 删掉正在转场的那一路会把引用置 0（切进来的变黑场）、setInputSource 换掉某一路的来源、loadShow 整体替换，都还会在转场中改画面。前两条是有意的（删掉的输入没法再画、换来源本来就是直播中用的），loadShow 会清瞬态；Q66 只问了 setPreview / setProgram，这里只列出来，不建议改。

## 5. 下一个会话需要知道的坑

1. **给 App 的提示（prompt 交付 3）**：
   - 格子上以后的"转场 / Cut"按钮（prompt 94）和 Shift + 点在转场中应置灰或提示"转场进行中"——reducer 已兜底（转场中这两条命令原样返回、回执 applied = false），界面不判也不会跳画面，只是按了没反应。判断用快照的 `state.transition.isActive`（T-bar 推到一半也算），不要自己按 progress 算。
   - 数字键 / Shift + 数字、点缩略图走的是同一条命令，转场中同样不生效；收到 applied = false 而快照 `transition.isActive` 为真时，状态行可以提示一下"转场进行中，PVW 未改"。
   - 格子上的"Cut"若做成 setPreview(n) + cut 发，转场中按下会是"setPreview 被拒、cut 把正在进行的那次做完"，PGM 落在原来那次的目标上，不是 n（见下一条）——所以这两个按钮在转场中必须置灰，不能只靠 reducer 兜底。
2. **组合命令**：任何"先 setPreview(n) 再 cut / fade / autoTransition"的组合（兼容层 `Cut` / `Fade` 带 `Input`、HTTP 批量、以后 W5-J 的组合动作、94 的格子按钮），在转场中前一条会被拒；带 cut 的那种会把当前转场做完，PGM 不是 n。要"立刻切到 n"：先 cut、再 setProgram(n)（同一拍应用时画面直接是 n，但 AFV 会看到两次切换），或者转场中直接回"转场进行中"。
3. **边界拍**：auto 转场第 s 拍起就拒（那一拍 progress 还是 0，但 startTick 已记）；对调那一拍（s + d）已经照收。场景脚本要在转场后改 PVW，最早排在 s + d（现有时间线都排 s + d + 1，没问题）。
4. **`make gate4-run` 会改三个入库文件**：baselines/g4-m5max.json（`--write-baseline`）、reports/G4-run-10min.md、reports/G4.md（gate4.sh 写死）。功能会话跑完要 `git checkout` 还原，本会话就是这么做的（运行报告另存了一份，数字抄在 §2）。
   **多个会话同时在机器上跑时 gate4 不作数**：两个引擎、App 用例同时跑会把 V1 推到 10 ms 以上、V2 丢上千帧；而 V6 的判定要求 frameprobe 按文件帧序算出的拍 = 1000（gate3-report.py 的 `cut_1000.tick == 1000`），
   第 1000 拍之前只要丢过帧，切换本身再准也判 ❌——看 V6 时先看 V2 / V5，再看 pts 拍与 cleanCut。跑之前先看有没有别的引擎、8765 和负载（本会话第二次就是等安静才跑的）。
   - 查"别的引擎"别用 `pgrep -f switcher-headless`：别的会话的等待脚本命令行里就带着这几个字（本会话撞上过两个这样卡了 40 多分钟的 zsh），会误中；用 `ps -axo comm= | grep '/switcher-headless$'` 按可执行文件路径查。
   - gate4.sh 的 load.log 漏掉占用最高的那个进程：采样是 `ps -eo pcpu,comm | sort -rn | head -5 | tail -4`，`sort -rn` 把表头"%CPU"当 0 排到后面去了，`tail -4` 跳掉的是第一名而不是表头（本机实测：38% 的 switcher-headless 不在采样里）。看 load.log 时记得"最忙的那个不在里面"（scripts/ 归检查点，本会话没改）。
5. **MultiviewMetersTests 两条在当前系统上红**（main 上同样），G6 判全量时会撞上，别当成本分支的问题；问题单里有 PSNR 数字。
6. 读 swift test 输出：MixerState 的 XCTAssertEqual 失败会把整个状态打成一行（几 KB），`head` 截不住，用 `cut -c` / `awk` 截。整包跑时 Render 参考图的 PSNR 打印可能不出现在输出里，要看 PSNR 用 `--filter` 单跑。
7. 实时类用例（Audio 的 IntegrationRealtimeTests、Outputs 的 MediaMTX 推流）在同机多个会话并行时容易被挤红，红了先单独重跑再判。
