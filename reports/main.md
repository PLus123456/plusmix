# P0 仓库初始化 —— 报告（分支 main）

日期 2026-09-12。机器：Apple M5 Max / 128 GB / macOS 26.4；Xcode 26.6 (17F113)，Swift 6.3.3，macOS 26.5 SDK；xcodegen 2.46.0，jq（系统自带），make 3.81，/bin/bash 3.2。
提交：`89b7ca3` … 本报告所在提交，共 6 个。

## 1. 做了什么

1. `git init -b main`。规格三份 + UI 稿 zip → `docs/spec/`（zip 解压到 `docs/spec/ui-mock/`，原 zip 保留）；落地方案 + `prompts/` → `docs/plan/`。LICENSE = Apache-2.0 原文；`.gitignore` 覆盖 Xcode / SwiftPM / DerivedData / `reports/**/*.jsonl` / `*.mov` `*.mp4`（`Tests/Fixtures/` 和 `Packages/*/Tests/Fixtures/` 放行，用 `git check-ignore` 逐条验过）。
2. 六个包（`Packages/Switcher{Core,Inputs,Audio,Outputs,Control,TestKit}`）+ 两个工具（`Tools/switcher-headless`、`Tools/frameprobe`），全部 swift-tools-version 6.0、`swiftLanguageModes: [.v6]`、`.macOS(.v15)`。SwitcherCore 预建 SwitcherContracts / SwitcherEngine / SwitcherRender 三个 target 和三个测试 target。每个包一个占位测试（`testP0_skeleton_*`），TestKit 的占位把六个下层模块全 import 一遍证明链接链完整；工具只打印版本。
3. `scripts/check-deps.sh`：`swift package dump-package` 读 8 个包的真实依赖，按层级（Core=1，四个功能包=2，TestKit=3，Tools=4；Core 内 Contracts=0，Engine / Render=1）拦反向依赖，包内传递闭包也算。
4. App：`project.yml` → `Switcher.xcodeproj`（不入库）；App target 依赖全部本地包；`App/Info.plist` 手写，带 `NSCameraUsageDescription`、`NSMicrophoneUsageDescription`；bundle id `com.example.switcher`；`DEVELOPMENT_TEAM` 走环境变量；`SwitcherTests` 单元测试 target 以 App 为宿主。CameraExtension 只有目录 + README。
5. Makefile：`gen` / `build` / `test` / `lint` / `clean`（另有 `build-*`、`test-*` 分目标）。`lint` = `lint-rules.sh` + `check-deps.sh` + `check-ownership.sh <当前分支>` + 自动发现的 `scripts/{check,lint}-*.sh`。
6. `CLAUDE.md`（铁律、目录、make、报告格式、契约流程）；`docs/OWNERSHIP.md`（落地方案 §2 的表 + 每个 prompt 的"只准动"落成路径 token + 补充规则）。
7. `reports/`、`reports/issues/`、`baselines/`、`scenarios/`、`docs/contract-changes/`、`Tests/Fixtures/`、`Tests/References/` 各一个 README。
8. 六次提交，提交信息写了为什么；包骨架那次注明来源于设计方案 §11。

## 2. 验收项：数值 / 阈值 / 通过否

P0 没有测试 ID，验收是"`make gen build test lint` 全绿"。

| 项 | 结果 | 通过 |
|---|---|---|
| `make clean && make gen build test lint` | 全绿，65 s（M5 Max，冷 .build） | ✅ |
| 包占位测试 | SwitcherCore 3 个、其余五包各 1 个，共 8 个，0 失败 | ✅ |
| 工具冒烟 | `switcher-headless 0.1.0`、`frameprobe 0.1.0` 正常输出 | ✅ |
| App `xcodebuild test` | 1 个测试：delegate 已挂、主窗口已建、链接到 TestKit / Contracts | ✅ |
| `lint-rules.sh` 反向验证 | 注入 `vMix` 注释、`"OBS Studio"` 字符串、`"vmixcompat"` 小写 → 三处全报；`VMixCompatBridge`（含合法 token）不报 | ✅ |
| `check-deps.sh` 反向验证（临时副本） | 注入 4 种反向依赖：Core 包依赖 Inputs；Contracts→CHelper→Engine 传递；Render→Engine；Inputs→Audio 同层 → 7 条违规全部列出 | ✅ |
| `check-ownership.sh` 反向验证（临时克隆） | 7 个场景：正常分支通过；越界两个文件全列；`!` 排除目录被拦；胶水额度 10/50 通过、60/50 拦下；`MetalDisplayView*` 通配；`release/0.1` 带斜杠分支名 → `reports/release-0.1.md`；`--include-working-tree` 抓到未提交越界 | ✅ |
| `.gitignore` | 9 条路径 `git check-ignore` 逐条符合预期 | ✅ |

## 3. 没做的和原因

- **业务代码**：一行没写，按 prompt "不做"。
- **CameraExtension target**：没建，需要付费开发者账号，按 prompt 留给 W3-C。
- **entitlements / hardened runtime / 沙盒**：没加。ad-hoc 签名下加了也没意义，且 hardened runtime 会干扰测试注入；W4-B 做发布工程时一起做。
- **`App/Resources/`**：目录没建（git 不跟踪空目录），project.yml 里已按 `optional: true` 引用，W4-B 放图标时直接建目录即可。
- **THIRD_PARTY/**：没建目录，只在 OWNERSHIP 里划给 W1-D。

## 4. 对契约 / 规则的疑问（等你拍板）

1. **各包 Package.swift 的归属**：落地方案 §2 把"各 Package.swift 骨架"划给 P0，但 P1（Contracts 要 C 头文件 target）、W1-D（内嵌 libsamplerate / libebur128 的 C target）、W2-D / W2-E / W3-A / W3-D（各自要加 target）按 prompt 都必须改所属包的 Package.swift。我在 OWNERSHIP 表里把所属包的 `Package.swift` 给了这些会话，限制"只加自己 target 的东西"。这条脚本查不了，靠检查点人工看 diff。不同意就改 `docs/OWNERSHIP.md`。
2. **Engine 与 Render 互不依赖**：prompt 只规定了包级方向，没规定 Core 内 Engine / Render 的关系。设计方案说两者通过 Contracts 里的 Renderer / FrameConsumer 协议见面，所以我在 `check-deps.sh` 里把它们设为同层（互相依赖就红）。这是 P0 加的约束，理由是 W1-B / W1-C 并行不能互相编译在对方上。
3. **禁词的唯一例外**：模块名 `VMixCompat` 这个 token 允许出现在代码任何位置（Package.swift 的 target 声明、`import VMixCompat`），其他任何形式（字符串、注释、`vmixcompat` 小写）都不行。App 里给这个兼容层做开关时，UI 文案得叫别的（例如"第三方 API 兼容"），否则 lint 红——W3-D / W3-E 那时要么改文案要么写提案。
4. **`Tests/References/` 与 `Tests/Fixtures/` 放仓库根**：W1-C 的 prompt 写"对应 Tests/、Tests/References/"，我理解为 `Packages/SwitcherCore/Tests/SwitcherRenderTests/` + 仓库根 `Tests/References/`（跨包共用，且放包外不会被 SwiftPM 当 target）。W1-A / W1-E 的 `Tests/Fixtures/` 同理。
5. **落地方案 §2 有两处 prompt 与表不一致**我按 prompt 走：W1-A 的 prompt 说 fixtures 进 `Tests/Fixtures/`，表里没提；W1-D 的 prompt 要 `THIRD_PARTY/` 和 `scripts/check-rt-symbols.sh`，表里只有 `SwitcherAudio/`。OWNERSHIP 里已加。
6. **G5 的"版本号"**落成两个文件：`project.yml` 的 `MARKETING_VERSION` 和 `SwitcherContracts/Version.swift` 的 `SwitcherVersion.current`，lint 校验一致。这让 G5 会碰 Contracts 目录里的一个文件；如果不想，改成根目录 `VERSION` 文件 + 构建脚本注入也行，但那要动 Makefile 和每个包的构建。

## 5. 下一个会话（P1）需要知道的坑

- **`@main` + NSApplicationDelegate 没有 nib 时 delegate 是 nil**（macOS 26.4 / Xcode 26.6 实测）：`applicationDidFinishLaunching` 根本不会被调。App 已改成 `main.swift` 显式挂 delegate。W2-B 别改回去。
- **XcodeGen 的 `${DEVELOPMENT_TEAM}`**：环境变量未设置时不替换成空，会把字面量写进工程。永远用 `make gen`（Makefile 保证它至少为空串），不要直接跑 `xcodegen`。
- **macOS 自带 make 3.81** 定位命令用它启动时的 PATH，`export PATH` 只对子进程有效。Makefile 里 brew 工具（xcodegen）写了全路径；以后加 ffprobe / mediamtx 调用时同样用 `$(BREW_PREFIX)/bin/...` 或放进脚本里调。
- **Claude 的 Bash 是非登录 shell**：在 Makefile 之外用 brew 工具先 `eval "$(/opt/homebrew/bin/brew shellenv)"`。
- **`check-ownership.sh` 只看已提交改动**（merge-base(main, 分支) → 分支顶）。提交前自查加 `--include-working-tree`。
- **`swift package dump-package` 有缓存**：第一次 ~1.5 s / 包，之后 <0.2 s；`check-deps.sh` 并行跑 8 个，正常 1 s 内。
- **`xcodebuild test` 会真的启动 App**（弹一个空窗口几秒钟再关），跑 `make test` 时别惊讶。
- **每个包各自 `.build`**：TestKit、两个工具各自重编一遍下层包，`make build` 冷启动约 40 s；后面包大了会更慢，G2 如果嫌慢可以考虑一个 umbrella workspace，但那会影响 check-deps 的解析方式，改之前先看 `scripts/check-deps.sh`。
- **P1 要加 C 头文件 target 时**（"只定协议和 C 头文件里的结构布局"）：在 `Packages/SwitcherCore/Package.swift` 加 `.target(name: "CSwitcherContracts", ...)` 让 `SwitcherContracts` 依赖它即可，`check-deps.sh` 对没登记层级的辅助 target 不设限，只查传递闭包不碰 Engine / Render。
- 报告文件名规则是 `reports/<分支名>.md`，所以本报告叫 `reports/main.md`。
