# Switcher 仓库约定

Apple Silicon 原生多机位导播台，代号 Switcher。Swift 6（严格并发）+ Metal，Apache-2.0。交流用中文。
规格在 docs/spec/，执行计划和每个会话的 prompt 在 docs/plan/。**每个 Claude 会话 = docs/plan/prompts/ 里的一个文件**，开工前先读它和 docs/plan/prompts/00-通用前言.md。

## 先读什么（只读需要的节）

- docs/spec/导播台设计方案.md：架构 §2、线程与时钟 §3、数据模型 §4、工程结构 §11、决策记录 §12
- docs/spec/导播台测试标准.md：指标 §1、工装 §2、测法 §3、阈值 §4、stats.jsonl 字段 §7
- docs/CONTRACTS.md + Packages/SwitcherCore/Sources/SwitcherContracts/：共用类型（P1 之后存在）
- docs/OWNERSHIP.md：你这个会话只准动哪些目录
- docs/plan/导播台落地方案.md：拆分 §2、检查点 §4、会话怎么跑 §5、硬件阻塞 §6

## 铁律（docs/plan/prompts/00-通用前言.md，这里是抄本，以那边为准）

1. 只动本会话指定的目录，其他包只读。改契约（SwitcherContracts 任何公开类型、JSON 字段名、测试图案布局）不许直接改：在 docs/contract-changes/ 写提案，然后停下来问用户。
2. 先写测试，再写实现。测试函数名带测试 ID（`testV6_cutLandsOnExactTick`）。测不了的写 XCTSkip 并注明 BLOCKED-硬件 / BLOCKED-SDK / BLOCKED-签名。
3. 热路径规则（设计方案 §3.2、§3.5）：渲染线程每帧零分配；音频回调内无锁、无分配、无日志、无系统调用、无 Swift ARC 抖动，热路径用 C。违反的代码不许合并。
4. 统计只有一份：所有数字进 Stats（测试标准 §7 的 stats.jsonl 字段），UI、API、测试三方读同一个结构。
5. 所有帧和音频块在入口换算成 host time（mach_absolute_time）打戳；编码 PTS 用拍点时刻。
6. 不出现竞品的名字、图标、文案、默认快捷键表；不复制 GPL 代码。用词按设计方案 §1.1。`make lint` 会扫代码树里的禁词，唯一例外是模块名 `VMixCompat`。
7. 在独立的 git worktree 和分支上工作，小步提交，提交信息写"为什么"。不 push、不 merge，合并由检查点会话做。
8. 结束前写 reports/<分支名>.md，固定格式见下。
9. 做不到就直接说。不许为了让测试过而放宽阈值、跳过断言、改测试图案。阈值只有用户能改。
10. 不确定的 API 行为（macOS 26 上的 AVFoundation / ScreenCaptureKit / VideoToolbox / CMIO），先写 20 行探针程序验证，结论写进报告，再写正式代码。

## 目录（设计方案 §11）

```
Packages/SwitcherCore      SwitcherContracts（契约）/ SwitcherEngine（时钟、帧槽、状态机）/ SwitcherRender（Metal）
Packages/SwitcherInputs    各输入；DeckLink、NDI 独立可选 target
Packages/SwitcherAudio     混音（C 热路径）、重采样、效果、表
Packages/SwitcherOutputs   编码、录制、推流、NDI 发送、虚拟摄像头桥
Packages/SwitcherControl   命令、HTTP/WS、快捷键、MIDI、Tally；VMixCompat 独立 target 默认关
Packages/SwitcherTestKit   合成源、帧号解码、Stats 采集、场景执行器
App/                       AppKit 主程序（XcodeGen：project.yml → Switcher.xcodeproj，生成物不入库）
CameraExtension/           CMIO 系统扩展（W3-C）
Tools/switcher-headless    命令行跑引擎        Tools/frameprobe  分析输出文件里的帧号 / 闪光 / click
Tests/Fixtures  Tests/References   跨包共用的测试素材 / 参考图（仓库根，不属于任何包）
scenarios/  baselines/  reports/  reports/issues/  docs/contract-changes/   各自有 README
```

依赖方向只允许 `SwitcherContracts ← SwitcherCore ← {Inputs, Audio, Outputs, Control} ← TestKit ← Tools / App`；
SwitcherCore 内 Engine 和 Render 互不依赖，只见 Contracts。`scripts/check-deps.sh` 用 `swift package dump-package` 读真实依赖图拦反向依赖。

## make 目标

| 目标 | 做什么 |
|---|---|
| `make gen` | XcodeGen 生成 Switcher.xcodeproj。Team ID：`DEVELOPMENT_TEAM=XXXXXXXXXX make gen`；不设则 ad-hoc 签名 |
| `make build` | 六个包 + 两个工具 `swift build`，App `xcodebuild build` |
| `make test` | 六个包 `swift test`，两个工具跑一次冒烟（输出版本），App `xcodebuild test` |
| `make lint` | `scripts/lint-rules.sh`（禁词、版本号一致、Package.swift 约束）+ `scripts/check-deps.sh` + `scripts/check-ownership.sh <当前分支>` + `scripts/{check,lint}-*.sh`（会话自加的检查自动挂上） |
| `make clean` | 删所有 .build 和生成的工程 |

- 检查别的分支：`make lint BRANCH=w1-core`。提交前自查未提交改动：`scripts/check-ownership.sh <分支> --include-working-tree`。
- Claude 的 Bash 是非登录 shell：Makefile 已把 /opt/homebrew/bin 加进 PATH；自己在 shell 里调 brew 工具先 `eval "$(/opt/homebrew/bin/brew shellenv)"`。
- macOS 自带 make 3.81 定位命令用它启动时的 PATH，Makefile 里 brew 工具要写全路径（`$(XCODEGEN)` 就是这么处理的）。

## 分支与 worktree

分支名在各会话 prompt 第一行（`p1-contracts`、`w1-core`、`g2-m0`……），全部从 `main` 开：

```bash
git worktree add ../plusmix-<分支名> -b <分支名> main
```

功能会话只在自己分支提交；检查点会话（G2–G5）合并、跑测试、写报告，不写功能。检查点里单个包超过 50 行的改动不许做，写 reports/issues/ 退回原会话（`check-ownership.sh` 的胶水额度就是这条）。

## 报告格式（reports/<分支名>.md，分支名里的 / 换成 -）

固定五段：
1. 做了什么
2. 每个测试 ID：数值 / 阈值 / 通过否（测不了的写 BLOCKED-xxx 和解锁条件）
3. 没做的和原因
4. 对契约的疑问
5. 下一个会话需要知道的坑

检查点报告（reports/G2.md 等）按测试标准 §7 模板：版本 / 提交号、机器 / macOS / 电源 / 温度、场景文件、每个指标的数值 · 阈值 · 通过否 · 与上一版本的差、崩溃日志 / Instruments / stats.jsonl 的路径、已知问题与放行说明。

## 契约变更流程

1. 任何会话发现契约要改：在 docs/contract-changes/ 写 `NNN-<主题>.md`（改什么、为什么、影响谁、怎么迁移），**然后停下来问用户**，不要自己改 SwitcherContracts。
2. 用户批了：由 P1 会话（或新开的契约会话）在 SwitcherContracts 里改，其他分支 rebase。
3. 提案文件留着当决策记录，不删。

## 版本号

只在两处：`project.yml` 的 `MARKETING_VERSION` 和 `Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift` 的 `SwitcherVersion.current`。lint 校验一致；改它们是 G5 的事。

## 写代码时

- Swift 6 语言模式、严格并发，所有包 `platforms: [.macOS(.v15)]`。
- 实时线程不用 actor / async / DispatchQueue.sync / 任何分配（设计方案 §3.2、§3.5；W1-B、W1-C、W1-D 的 prompt 有细则）。
- 不用 CVDisplayLink（已弃用），显示用 `NSView.displayLink(target:selector:)`。
- 第三方库按设计方案 §11 选型表，LGPL 的动态链接，GPL 的不碰；内嵌源码的许可证放 THIRD_PARTY/。
