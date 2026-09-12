# Switcher

Apple Silicon 原生的多机位导播台：PGM / PVW 范式，Cut / Fade / Wipe / Zoom / Stinger 转场，四条音频总线，录制 / 推流 / NDI / 虚拟摄像头输出。Swift 6 + Metal，macOS 15+，Apache-2.0。

现在是 **P0 骨架**：目录、包、工程、lint 都在，业务代码还没有。规格在 [docs/spec/](docs/spec/)，怎么一步步做在 [docs/plan/导播台落地方案.md](docs/plan/导播台落地方案.md)。

## 环境

- Xcode 26.x（`xcode-select` 指向它，license 已接受，Metal 工具链已装）
- Homebrew：`brew install xcodegen jq ffmpeg mediamtx gh`
- 检查：`xcodebuild -version && swift --version && xcodegen --version && ffprobe -version | head -1 && mediamtx --version`

完整清单（含 W2 / W3 之前要装的 NDI SDK、DeckLink SDK、Apple Developer Program、硬件）见 [docs/plan/prompts/01-P0H-环境清单-人工.md](docs/plan/prompts/01-P0H-环境清单-人工.md)。

## 跑起来

```bash
make gen build test lint
```

| 目标 | 做什么 |
|---|---|
| `make gen` | XcodeGen 由 `project.yml` 生成 `Switcher.xcodeproj`（不入库）。要用真实签名：`DEVELOPMENT_TEAM=你的TeamID make gen` |
| `make build` | 六个包、两个命令行工具、App 全部编译 |
| `make test` | 包的 `swift test`、工具冒烟、App 的 `xcodebuild test` |
| `make lint` | 禁词 / 版本号 / 包约束、依赖方向、目录归属 |

单独跑一个包：`swift test --package-path Packages/SwitcherCore`。单独跑工具：`swift run --package-path Tools/frameprobe`。

## 权限

- 摄像头、麦克风：Info.plist 已带用途说明，首次访问时系统会弹窗。
- 屏幕录制（ScreenCaptureKit）**没有** usage key，不会自动弹窗：要在 **系统设置 → 隐私与安全性 → 屏幕与系统音频录制** 里手动把 Switcher 加进去。
- 没设 `DEVELOPMENT_TEAM` 时 App 是 ad-hoc 签名，每次重新编译签名都变，上述授权会反复问；要稳定授权就设 Team ID。
- 虚拟摄像头（系统扩展）和公证需要付费开发者账号，W3-C / W4-B 才用到。

## 目录

```
Packages/SwitcherCore      引擎：SwitcherContracts / SwitcherEngine / SwitcherRender
Packages/SwitcherInputs    输入          Packages/SwitcherAudio     音频
Packages/SwitcherOutputs   输出          Packages/SwitcherControl   控制
Packages/SwitcherTestKit   测试工装
App/                       AppKit 主程序  CameraExtension/           CMIO 扩展（W3-C）
Tools/switcher-headless    无界面跑引擎   Tools/frameprobe           分析输出文件
Tests/Fixtures  Tests/References  scenarios/  baselines/  reports/   各自有 README
docs/spec 规格   docs/plan 计划与 prompt   docs/OWNERSHIP.md 谁能动哪   docs/contract-changes 契约提案
scripts/                   lint-rules.sh · check-deps.sh · check-ownership.sh
```

依赖方向只允许 `SwitcherContracts ← SwitcherCore ← {Inputs, Audio, Outputs, Control} ← TestKit ← Tools / App`，`make lint` 会拦反向依赖。

## 怎么开始下一个会话

每个会话就是 [docs/plan/prompts/](docs/plan/prompts/) 里的一个文件，顺序和依赖见落地方案 §2–§3。下一个是 **P1 契约冻结**（`03-P1-契约冻结.md`，分支 `p1-contracts`）。

1. 新开一个 Claude Code 会话，把 `docs/plan/prompts/00-通用前言.md` 全文贴在前面，再贴该会话文件全文，开头加一句"请在独立的 git worktree 里工作"。
2. 会话自己会建 worktree：`git worktree add ../plusmix-<分支名> -b <分支名> main`。
3. 会话只动 [docs/OWNERSHIP.md](docs/OWNERSHIP.md) 里允许的目录，结束前写 `reports/<分支名>.md`（五段固定格式，见 [CLAUDE.md](CLAUDE.md)）。
4. 功能会话不 push、不 merge；同一波次的会话可以各开一个窗口并行。检查点会话（G2–G5）负责合并、跑门槛测试、写报告；不过就退回。
5. P1 之后你做 G1 人工复审（15 分钟，落地方案 §4），过了才开 W1 的五个并行会话。

仓库约定全在 [CLAUDE.md](CLAUDE.md)（每个会话都会自动读）。
