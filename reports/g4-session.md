# G4 检查点会话报告（分支 g4；正式检查点报告在 reports/G4.md = G4-notes.md + 自动结果）

分支名 g4 的会话报告按规矩该叫 reports/g4.md，但 APFS 不分大小写会和 reports/G4.md 撞文件名（G3 踩过），所以叫 g4-session.md。
worktree `.claude/worktrees/g4-checkpoint-merge-b5a2dc`，分支直接改名 `g4`，从 main f1bd1ee 开，2026-09-20。

## 1. 做了什么

1. **合并前的交接项**（prompt 60 末节 1–2，58def8a）：撤 headless 第 8 步的封口绕法（引擎停后直接 `rec.stop(atTick: lastTick + 1)`，ISO 同样，消费者封口后再摘，摘要多印越界丢弃计数）；
   `G3Factory` 八路换 `.noise(level: 原灰度, amplitude: 24, seed: 输入号)` 并重新生成 scenarios/g3-show.json；gate3-report 去掉 E2"本场景不适用"分支、E5（ffprobe 无错 / 时长差 ≤ 1 帧 / 音视频差 ≤ 20 ms）从信息表进判定表。
   第 3 条（App `stopRecording` 简化）W3-C 已在自己分支做；第 4 条（启动停顿复核）见 §2。
2. **五个分支按顺序 `--no-ff` 合入**：w3-compositor2（9093bcc）→ w3-inputs2（3b744fe）→ w3-outputs2（d896d53）→ w3-control2（9b745c9，认领分支上按用户裁定改的 OWNERSHIP / lint-rules）→ w3-app2（b60019b，App/ 8 个文件冲突）。
   冲突解决口径 = prompt 54 / W3-E 报告 §3：运行表以 W3-C 为准、菜单与面板保留 W3-E 的；具体取舍表在 reports/G4-notes.md §4。
3. **合并后的 App 收口与胶水**（b5e4846、81ce204）：删 W3-E 的 AuxWindows.swift（同名 MultiviewWindowController 撞类名）、PanelCoordinator 转调 W3-C 的窗口、外部显示附加键对齐 W3-C 的 displayID；
   InputFactory 接 W3-A 的 NDI / DeckLink、ControlRuntime 按偏好设置起 W3-D 的兼容层、切换面板接通 Wipe / Zoom / Stinger、project.yml 加三个产品依赖；两条旧测试改对着合并后的行为。
4. **G4 工装**（99ab031）：headless `--compat*` / `--tally-port` / `--ndi-send` / `--ndi-jitter-frames`，节目里接图片（ImageInput）与 NDI（NDIInput）输入；`G4Factory`（g4 / g4-ndi 节目、g4 场景、Stinger PNG）；
   `frameprobe --blank-ticks`（TestKit 胶水 16 行）；scripts/gate4.sh / gate4-ndi.sh / gate4-matrix.sh；gate3-report.py `--checkpoint`；Makefile gate4 系列；check-ownership 的冲突文件单列。
5. docs/checklists/G4.md、reports/G4-notes.md、续做 prompt 55（W3-E2）/ 56（W1-A3）+ OWNERSHIP 行、问题单两张、baselines/g4-m5max.json（gate 跑完写）。

## 2. 测试与 gate（数值 / 阈值 / 通过否）

（gate 跑完填：L0 / L1 各包；App 53 个用例；10 分钟 L2 判定表结论；NDI 回环 L1；编译矩阵；启动停顿复核。）

## 3. 没做的和原因

- **W3-C 接进 App 的 39 处文案本地化**：超出检查点 App/ 的胶水额度、也不是接线；`testL10n_noHardcodedChineseInUISources` 红着 → prompt 55（W3-E2）。
- **切换面板的 Wipe 方向 / 软边、Stinger 参数控件、PVW 预览叠加开关**：W3-E 没做、G4 只接通按钮；参数来自节目文件 → prompt 55。
- **frameprobe 对转场合成帧的正式判法、Wipe / Zoom 的 V7 量法**：G4 用 `--blank-ticks` 从外部标掉转场拍段；L2 场景里 Wipe / Zoom 的 V7 只有 W3-B 渲染侧单元测试在判 → prompt 56（W1-A3）。
- **C5 真 Companion、虚拟摄像头激活 / FaceTime / L1、DeckLink 硬件项、外接屏、Stream Deck 端到端、慢 U 盘 S7**：BLOCKED（reports/G4-notes.md §7 有解锁条件）。
- **E7–E9 没重跑**：W3 五路没动推流，沿用 G3 的结果（reports/G3-net.md）。
- **纯音频设备输入**：W3-E 的 Add Input 有页，没人做运行实现；报告 §8 列为待定归属。
- **提案 008 / 009 / 010 / 012 / 007 都没落地**：契约会话的事（建议开 P3 一次做完）。

## 4. 对契约的疑问

集中在 reports/G4-notes.md §8（等用户定的 7 条）。G4 自己没有新的契约需求；`--blank-ticks` 不改契约（工装选项），`extra["layout"]` / `displayID` / `border` 效果格都是各分支提案里的过渡口径。

## 5. 下一个会话需要知道的坑

1. **合并冲突的账**：check-ownership 现在把自动合并结果带冲突标记的文件单列不计额度；**删重复实现、改调用点仍算胶水**，这次 App/ 因此超额（约 380 行）——等用户认领或退回，别当成脚本坏了。
2. **`( … ) &` 包一层的后台任务在 Bash 工具里立刻报"完成"**，要盯日志文件里自己写的 `EXIT n` 行；`sleep 60` 这类等待会被工具拦，用 `until grep -q EXIT log; do sleep 5; done` 放后台。
3. **zsh 的 `=cmd` 展开**：`echo ====` 会报 "=== not found"，分隔线用引号包住；`$b:reports/...` 会被当修饰符。
4. **xcodebuild 会改已跟踪的 `Packages/SwitcherControl/Package.resolved`**，`swift build` 会生成未跟踪的 `Tools/frameprobe/Package.resolved`、`Packages/SwitcherOutputs/Package.resolved`、`Packages/SwitcherTestKit/Package.resolved`；`git add -A` 前先看。`scripts/*.py` 跑过会留 `scripts/__pycache__/`（这次误提交过一次，.gitignore 已加）。
5. **xcodebuild -quiet test 不印用例数**：从 `.build/DerivedData/Logs/Test/*.xcresult` 用 `xcrun xcresulttool get test-results summary --path` 读 totals 和 testFailures（failureText 是完整断言文案，本地化测试的 39 处清单就是这么拿的）。
6. **`swift build` 在这个 worktree 16 s 就"Build complete"**：Xcode 27 的 swiftbuild 后端复用了别的 worktree 的产物缓存；别据此判断编译干净，看 `--show-bin-path` 下的二进制时间戳和 `--version`。
7. **frameprobe 对转场帧的判法**（reports/issues/G4-w1-testkit-frameprobe-wipe-zoom-progress.md）：Wipe 硬边时 ID 块与帧号行在不同拍翻转、CRC-4 有 1/16 概率放过错号；Zoom 在 s ∈ [0.933, 1) 时 ID 采样区被新画面部分盖住。gate4 用 `--blank-ticks [t + 1, t + d]` 绕，第 t 拍保留（整秒闪光帧在那）。
8. **C1 相位**：G4 场景的非 Cut 转场 0.4 s，apitest 的 `--c1-phase 0.7` 让 cut 落在转场结束 0.3 s 后；改转场时长要一起改相位（apitest 的规则是离 5 s 切换点 ≥ 0.4 s）。
9. **NDI 回环的源名**：headless 把不含 "(" 的 `ndi(sourceName:)` 按本机发现列表的 " (名字)" 后缀解析（NDI 源名是 "机器名 (名字)"），发送端要先起（`--ndi-send` 在输入构造前 start）；发现列表 1.5 s 一轮、最多等 10 s。
10. **Stinger PNG 相对路径**：headless 相对节目文件所在目录解析；App 的 ImageInput 相对 cwd（Finder 起是 /），清单里让用户用 Add Input 选文件。
11. **W3-E 的 LocalizationTests 会扫 App/Sources 里所有中文字面量**（NSLog / print / 断言除外）：以后往 App 里加文案一律 `L("键")` + 两个 .strings 各一行，否则整条测试红。
12. **App 测试的 S7 磁盘满用例对负载敏感**（missed_render 必须 0）：第一次全量跑时（机器上还有 frameprobe / 编译在跑）红了 1 帧，单跑绿；跑 App 全量前让机器安静。
