# G3 检查点会话报告（分支 g3 = harness 分支 claude/g3-checkpoint-3e1078；文件名 g3-session.md，因为 reports/g3.md 与 reports/G3.md 在 APFS 大小写不敏感的盘上是同一个文件）

日期 2026-09-15。机器 Apple M5 Max 128 GB / macOS 26.6.2 / **Xcode 27.0 (27A266a) / Swift 6.4**（会话开始时本机 Xcode 刚被换掉，Metal 工具链组件未装，见 §3）。
worktree `.claude/worktrees/wonderful-fermi-40fe5f`，从 main 2290b4e 开；`g3` 引用打在 HEAD 上给 `check-ownership.sh` 用。
检查点正式报告（§7 模板）是 `reports/G3.md`（= `reports/G3-notes.md` 人工部分 + gate 自动部分）；本文件是会话自己的五段式报告。

## 1. 做了什么

1. 按 prompt 顺序 `--no-ff` 合并 w2-inputs → w2-control → w2-audio-integ → w2-stream → w2-app（57bedb4 / 43cbdf9 / 95b22e4 / 89a36e4 / c448a5e）。零代码冲突；唯一冲突 `docs/OWNERSHIP.md` 相邻两行（两边各取各的）。
2. 每合一个 `make lint`（全绿，除 OWNERSHIP.md 归属一条，见 §4）；能编的包的 `swift test`（SwitcherControl 28/28、SwitcherAudio 87 个全绿 5 跳过；SwitcherOutputs 去掉 MediaMTXTests 的结果见 reports/G3.md §4）。
   依赖 SwitcherRender 的包 BLOCKED-Metal（§3）。
3. `scripts/check-rt-symbols.sh` 适配 Xcode 27 SwiftPM 的 swiftbuild 布局（之前会静默通过）。
4. headless 接线：W2-E 的 AudioEngine 补丁（删 AudioPump；封口前先摘消费者；`--iso-audio N`）叠在 W2-C 的 `--api` / StatsPublisher 之上；`G3Factory`（`--preset g3` 节目 + 场景）。
5. `make gate3`（L0 + L1 + 10 分钟 G3 场景：V1–V7、A1–A4、E1–E3、C1–C4 一次出）、`gate3-run`、`gate3-1h`、`gate3-net`（E7–E9，用户 sudo 起 netem 代理后跑）；
   `scripts/gate3.sh`、`gate3-report.py`（硬性项 V6 / A1 / C3 / C4 不可放行）、`gate3-net.sh`；`apitest.py run --c1-start`。
6. `docs/checklists/G3.md`；`reports/G3-notes.md`；提案 002（W2-A）改号 005；摄像头到达余量问题单加检查点裁定（对 W1-B 的修法要求 + 验收标准）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

以 `reports/G3.md` 的判定表为准（gate 跑完自动填）。会话结束时的状态：

| 组 | 状态 |
|---|---|
| L0 / L1 整仓 `make test`（Xcode 27.0，Metal 工具链装好后） | 全绿：SwitcherCore 148（Contracts 48 / Engine 73 / Render 27）、SwitcherInputs 28（4 跳过：摄像头权限 ×3、S5 硬件）、SwitcherAudio 87（5 跳过：真设备 / 回环）、SwitcherOutputs 18 + 21 + 8（2 跳过）、SwitcherControl 28、SwitcherTestKit 49、两个工具冒烟、App 14 / 14 |
| L2 10 分钟（V1–V7、A1–A4、E1–E3、C1–C4） | 第二次运行 **18 / 19 通过、E2 本场景不适用**（灰底合成源压不出码率，以 W1-E / W2-D 噪声用例为准）：V1 1.78 ms、V2 0、V3 0.037、V4 设计外 0、V5 0、V6 恰第 1000 拍 147 次 Cut 全干净、V7 曲线 0.344 帧 / T-bar ≤ 0.78%、A1 0、A2 0.000 ms、A3 0、A4 0.208 ms、E1 0、E3 精确、C1 50/50 max 16.87 ms、C2 p99 0.39 ms、C3 0、C4 12000/12000（reports/G3.md） |
| E7–E9 | 第一次（09-15 19:01）E8 ❌ 是工装（两个 netem 代理同时在跑）；修单实例锁后用户 09-18 重跑：**3 / 3 通过**，E8 10 / 10 重连，放开后 0.08–1.10 s（断线判定 9.0–9.2 s） |
| A5、A6、A7 | A5 BLOCKED-硬件（W2-E 脚本在）；A6 W1-D 测过（0.007 LU）；A7 W1-D / W2-E 的实时用例 0 违规（SwitcherAudio 全绿即含） |
| S5 | BLOCKED-硬件（无 USB 摄像头）；docs/checklists/G3.md 第 6 条 |

## 3. 没做的和原因

- `sudo xcodebuild -runFirstLaunch`（清掉 xcodebuild 的 CoreSimulator / DVTCoreDeviceCore 红字）：用户的 sudo。
- **App 接线**（摄像头 / 文件 / 录制 / 推流 / 音频 / API，约 170 行）：超过检查点 `~App/:50` 额度，没做；选项见 reports/G3-notes.md §7 第 3 条。人工清单里给了 headless 等价物。
- **契约提案落地**（001 / 002 / 004 / 005）：不是检查点的事；建议一次契约会话一起落地（G3-notes §7 第 2 条）。
- **W2-E 退回 W1-D / W1-E / W1-A 的修改**：写在 G3-notes §7 第 5 条，等用户定。

## 4. 对契约 / 规则的疑问

见 reports/G3-notes.md §7：用户 2026-09-18 已按 G3 方案拍板四条（docs/ 归属、提案 001 / 002 / 004 / 005 落地、App 接线开 W2-B2、到达余量裁定交 W1-B2），
落地为 docs/OWNERSHIP.md 的新行与规则 6、提案文件状态、docs/plan/prompts/41–46 六个续做 prompt、提案 006（待批）。

## 5. 下一个会话需要知道的坑

见 reports/G3-notes.md §9。补两条会话过程里的：
- 自动模式的分类器会拦长的多命令 `git merge … && git merge …` 链和提交信息里带"契约改动 / 用户指示"字样的 merge；一次一条、信息写事实就过。
- Bash 工具的后台任务用 `( … ) &` 包一层会让工具立刻报"完成"，真正的进程还在跑；要看结果得盯日志文件。
- **`reports/g3.md`（会话报告）和 `reports/G3.md`（检查点报告）在 macOS 默认的大小写不敏感 APFS 上是同一个文件**：gate3-report 写 G3.md 时把会话报告覆盖了（fc55f97 里的 reports/g3.md 其实是检查点报告的内容），
  会话报告改名 `reports/g3-session.md`、从 e97fe51 恢复后补回。G4 / G5 起分支名别和检查点报告只差大小写。
- bash 3.2（macOS 自带）下 `"${arr[@]}"` 空数组在 `set -u` 时报 unbound variable，写 `${arr[@]+"${arr[@]}"}`；`git mv` 对未跟踪文件会 fatal 并中断 `&&` 链。
