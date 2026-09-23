# W2-A2 留给检查点汇总的清单（用户 2026-09-23："没做的先归档，到检查点汇总之后我一个一个统一做"）

归属会话 / 分支：W2-A2 / `w2-inputs-2`（桌面端分支 `claude/w2-inputs-audio-device-2ef9a9`，同一提交）
发现于：W2-A2 全程；每一条的详情在对应问题单里，这里只列"是什么、归谁、分级、不做会怎样"。
分级：**必须** = 不做 W2-A2 的交付在产品里用不上或合并出错；**建议** = 有用但可以推后；**可选** = 看用户。

## 〇、合并本分支之前（检查点自己）

| # | 事 | 分级 | 说明 |
|---|---|---|---|
| 0-1 | **先合 P3（`p3-contracts`），再合 `w2-inputs-2`** | 必须 | 提案 014 改的是 P3 刚改过的 `InputSource`，本分支因此叠在 P3 的 `ca1baa5`（`claude/p3-contracts-phase-2-86a7c4`）上。P3 之后如果**改写了历史**（amend / rebase），先把本分支 rebase 到 P3 的最终提交上再合；只是追加提交就直接合。本分支动过的 P3 文件只有 `Input.swift`、`DeckLinkInput.swift`、`CONTRACTS.md`、`InputSettingsPanel.swift`、`OWNERSHIP.md`（都是 014 与归属的改动） |
| 0-2 | P3 合入 main 之前查本分支归属：`scripts/check-ownership.sh w2-inputs-2 --base claude/p3-contracts-phase-2-86a7c4` | 必须 | `make lint BRANCH=w2-inputs-2` 以 main 为基线，会把 P3 的 74 个文件算成本分支的改动；P3 合入 main 之后就照常。本会话跑过：26 个改动文件都在允许范围内 |
| 0-3 | OWNERSHIP 的 W2-A2 行多了 7 个文件 | 知会 | 用户批 014 时指定本会话落地（"014 批了，你来做"），行里逐个列出、备注写明 |

## 一、App（W3-E2 / `w3-app-3`）

| # | 事 | 分级 | 不做会怎样 | 详情 |
|---|---|---|---|---|
| 1-1 | `InputFactory` 的 `.audio` 分支接 `AudioDeviceInput`（6 行） | 必须 | Add Input 选了纯音频设备也只有占位输入、没声音 | `W2A2-w3-app-3-audio-device-input-wiring.md` 第 1、2 条 |
| 1-2 | Add Input 的纯音频 / DeckLink 页加声道选择（提案 014），来源摘要显示映射 | 建议 | 多路接口上第 5、6 路的话筒选不了 | 同上第 3、4 条 |
| 1-3 | 纯音频输入在输入条 / 缩略图里画占位（名字 + 电平表），不显示成"无信号" | 建议 | 看不出这一路是没画面还是掉了 | 同上第 5 条 |

## 二、渲染器（多画面；W3-B 的目录，会话已结束）

| # | 事 | 分级 | 不做会怎样 | 详情 |
|---|---|---|---|---|
| 2-1 | 多画面里纯音频输入的格子画占位（深灰底 + 名字 + 电平表位置），电平表不受 `meters` 开关影响 | 建议 | 格子是黑的，和"摄像头掉了"一样 | `W2A2-w3-compositor2-multiview-audio-only-cell.md` |

## 三、检查点胶水（`Tools/`、探针目录）

| # | 事 | 分级 | 不做会怎样 | 详情 |
|---|---|---|---|---|
| 3-1 | `switcher-input-probe audio-device` 子命令接线（~15 行，实现已在 harness） | 可选 | 探针缺一个入口，测试里能调 | `W2A2-w2-inputs-probe-audio-device-subcommand.md` |
| 3-2 | headless 接纯音频输入（~20 行） | 建议（端到端 A2 的前提） | 节目文件里有纯音频输入时 headless 起不来 | `W2A2-g5-headless-audio-device-input.md` |

## 四、用户手动 / 硬件

| # | 事 | 分级 | 详情 |
|---|---|---|---|
| 4-1 | S4 纯音频设备热插拔 20 次（要能拔的 USB 声卡） | 建议 | `W2A2-user-manual-hardware-tests.md` 第 1 条 |
| 4-2 | 麦克风权限被拒 = error、授权后自动恢复 | 建议 | 同上第 2 条 |
| 4-3 | 多于 2 路的真设备声道映射 | 可选 | 同上第 3 条 |
| 4-4 | DeckLink 内嵌音频声道映射（有卡时） | 可选 | 同上第 4 条 |
| 4-5 | 纯音频设备的端到端 A2（回环线，先要 3-2） | 建议 | 同上第 5 条 |

## 五、别的会话的测试

| # | 事 | 分级 | 详情 |
|---|---|---|---|
| 5-1 | NDI 回环的音频块间隔断言在整包负载下偶发超阈值（25.34 > 24.667 ms，单独跑稳过） | 建议（检查点跑 `make test` 可能撞上） | `W2A2-w3-inputs2-ndi-audio-interval-flaky-under-load.md` |

## 已经不用做的（本会话里定了 / 做了）

- 提案 014：用户批，本会话落地（契约 + 测试 + CONTRACTS.md + 纯音频设备 / DeckLink 从 case 取映射 + App 两行编译跟改）。
- 纯音频输入进 Program / 多画面的口径：用户定为"能切进 Program（画黑、音频按 AFV 走），多画面画占位格 + 电平表"，写进契约
  `Input.videoSlot` 注释与 CONTRACTS.md §2.4 / §3；引擎和渲染器今天已满足"画黑 + 音频照走"，剩下的是上面 1-3、2-1 两条界面活。
