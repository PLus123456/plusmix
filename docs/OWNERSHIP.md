# 目录归属（会话 → 只准动的目录）

照 docs/plan/导播台落地方案.md §2 的表抄，并把各会话 prompt 里"只准动"一行落成可机器检查的路径。
`scripts/check-ownership.sh <分支>` 读**下表的"允许的路径"列**，检查该分支相对 `main` 的改动是否越界；`make lint` 会自动带上当前分支。

## 表格格式（脚本按这个解析，别改列顺序）

- 第 3 列是分支名，反引号包住。第 4 列是路径 token，每个反引号包住、空格分隔：
  - `dir/`（以 `/` 结尾）= 该目录下全部文件；`path/file` = 单个文件；可以带 `*`（bash 模式匹配，`*` 也能跨 `/`）。
  - `!path` = 排除（即使被更宽的 token 覆盖也不许动）。
  - `~prefix:N` = 胶水额度：`prefix` 下的改动本来不许，但检查点会话允许每个子目录（`Packages/*` 按包、`App/` 整体）改动 ≤ N 行（增 + 删）。
- 所有分支另外都允许：`reports/<分支名>.md`（分支名里的 `/` 换成 `-`）、`reports/issues/`、`docs/contract-changes/`。这三条写在脚本里，不用写进表。
- `main` 只有 P0 用，不检查。

## 表

| 编号 | 会话 | 分支 | 允许的路径 | 备注 |
|---|---|---|---|---|
| P0 | 仓库初始化 | `main` | 根、`docs/`、`scripts/`、各 `Package.swift` 骨架、`project.yml`、`Makefile` | 唯一直接在 main 上做的会话，不检查 |
| P1 | 契约冻结 | `p1-contracts` | `Packages/SwitcherCore/Sources/SwitcherContracts/` `Packages/SwitcherCore/Tests/SwitcherContractsTests/` `docs/CONTRACTS.md` `Packages/SwitcherCore/Package.swift` | Package.swift 只许为 Contracts 加 C 辅助 target（见下"补充规则"） |
| W1-A | 测试工装 | `w1-testkit` | `Packages/SwitcherTestKit/` `Tools/frameprobe/` `Tests/Fixtures/` | Fixtures 放 ≤ 5 MB 的回归样例 |
| W1-B | 核心逻辑 | `w1-core` | `Packages/SwitcherCore/Sources/SwitcherEngine/` `Packages/SwitcherCore/Tests/SwitcherEngineTests/` `Packages/SwitcherCore/Package.swift` | Package.swift 只许为 Engine 加依赖 / 辅助 target |
| W1-C | 合成引擎 | `w1-compositor` | `Packages/SwitcherCore/Sources/SwitcherRender/` `Packages/SwitcherCore/Tests/SwitcherRenderTests/` `Tests/References/` `scripts/gen-references.sh` `Packages/SwitcherCore/Package.swift` | Package.swift 只许为 Render 加着色器资源 / 辅助 target |
| W1-D | 音频引擎 | `w1-audio` | `Packages/SwitcherAudio/` `THIRD_PARTY/` `scripts/check-rt-symbols.sh` | check-rt-symbols.sh 放 scripts/ 下会被 make lint 自动带上，不用改 Makefile |
| W1-E | 编码录制 | `w1-outputs` | `Packages/SwitcherOutputs/` `Tests/Fixtures/` | pattern.mov 进 Tests/Fixtures/ |
| G2 | M0 集成 | `g2-m0` | `Tools/switcher-headless/` `scripts/` `Makefile` `scenarios/` `reports/` `baselines/` `~Packages/*:50` | 各包只改"接口对不上"的胶水，每包 ≤ 50 行，超了写 issue 退回 |
| W2-A | 输入一期 | `w2-inputs` | `Packages/SwitcherInputs/` `!Packages/SwitcherInputs/Sources/DeckLink/` `!Packages/SwitcherInputs/Sources/NDI/` `!Packages/SwitcherInputs/Tests/DeckLinkTests/` `!Packages/SwitcherInputs/Tests/NDITests/` | DeckLink、NDI 是 W3-A 的 |
| W2-B | 显示与主界面 | `w2-app` | `App/` `Packages/SwitcherCore/Sources/SwitcherRender/MetalDisplayView*` | W1-C 的显示视图允许在此完善 |
| W2-C | 控制一期 | `w2-control` | `Packages/SwitcherControl/` `!Packages/SwitcherControl/Sources/VMixCompat/` `!Packages/SwitcherControl/Tests/VMixCompatTests/` `Tools/switcher-headless/` `scripts/apitest/` `docs/api.md` | headless 只加 --api 参数；scripts/apitest/ 是 C 系列的客户端脚本，docs/api.md 由 switcher-apidoc 生成（prompt 32 测试段点名的位置，用户 2026-09-15 定） |
| W2-D | 推流与 NDI 发送 | `w2-stream` | `Packages/SwitcherOutputs/Sources/Streaming/` `Packages/SwitcherOutputs/Sources/NDISend/` `Packages/SwitcherOutputs/Tests/StreamingTests/` `Packages/SwitcherOutputs/Tests/NDISendTests/` `Packages/SwitcherOutputs/Package.swift` `scripts/netem.sh` `scripts/mediamtx.yml` | Package.swift 只许加这两个 target 和它们的依赖 |
| W2-E | 音频集成 | `w2-audio-integ` | `Packages/SwitcherCore/Sources/SwitcherEngine/Audio*` `Packages/SwitcherCore/Tests/SwitcherEngineTests/Audio*` `Packages/SwitcherAudio/Sources/Integration/` `Packages/SwitcherAudio/Tests/IntegrationTests/` `Packages/SwitcherAudio/Package.swift` | Package.swift 只许加 Integration target |
| G3 | M1 M2 M3 M5 集成 | `g3` | `Tools/` `scripts/` `Makefile` `scenarios/` `reports/` `baselines/` `~Packages/*:50` `~App/:50` | 同 G2 规则，App 里只许接线胶水 |
| W3-A | 输入二期 | `w3-inputs2` | `Packages/SwitcherInputs/Sources/DeckLink/` `Packages/SwitcherInputs/Sources/NDI/` `Packages/SwitcherInputs/Tests/DeckLinkTests/` `Packages/SwitcherInputs/Tests/NDITests/` `Packages/SwitcherInputs/Package.swift` | Package.swift 只许加这两个可选 target |
| W3-B | 合成二期 | `w3-compositor2` | `Packages/SwitcherCore/Sources/SwitcherRender/` `Packages/SwitcherCore/Tests/SwitcherRenderTests/` `Tests/References/` | |
| W3-C | 输出二期 | `w3-outputs2` | `Packages/SwitcherOutputs/Sources/External/` `Packages/SwitcherOutputs/Sources/VirtualCamera/` `Packages/SwitcherOutputs/Sources/ISO/` `Packages/SwitcherOutputs/Tests/ExternalTests/` `Packages/SwitcherOutputs/Tests/VirtualCameraTests/` `Packages/SwitcherOutputs/Tests/ISOTests/` `Packages/SwitcherOutputs/Package.swift` `CameraExtension/` `App/` `project.yml` | App 里只做对应窗口与设置入口；project.yml 只加扩展 target |
| W3-D | 控制二期 | `w3-control2` | `Packages/SwitcherControl/Sources/VMixCompat/` `Packages/SwitcherControl/Sources/Tally/` `Packages/SwitcherControl/Tests/VMixCompatTests/` `Packages/SwitcherControl/Tests/TallyTests/` `Packages/SwitcherControl/Package.swift` `Tools/streamdeck-plugin/` `docs/integrations/` | |
| W3-E | 界面二期 | `w3-app2` | `App/` | |
| G4 | M4 M6 集成 | `g4` | `Tools/` `scripts/` `Makefile` `scenarios/` `reports/` `baselines/` `~Packages/*:50` `~App/:50` | 规则同 G2 / G3 |
| W4-A | 长稳与性能 | `w4-soak` | `scripts/soak/` `scripts/perf/` `baselines/` `reports/` `Tools/switcher-headless/` | headless 只加参数 |
| W4-B | 发布工程 | `w4-release` | `scripts/release/` `.github/` `project.yml` `App/Resources/` `docs/release/` | |
| W4-C | 文档样例 | `w4-docs` | `docs/` `!docs/spec/` `!docs/plan/` `Samples/` `README.md` | |
| G5 | 发布门槛 | `release/0.1` | `reports/` `docs/KNOWN_ISSUES.md` `project.yml` `Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift` | "版本号"= project.yml 的 MARKETING_VERSION + Version.swift 的 SwitcherVersion.current，lint 校验一致 |

## 补充规则（P0 加的，落地方案里没写明；不同意就改这里）

1. **Package.swift**：落地方案把"各 Package.swift 骨架"划给 P0，但 P1 / W1-D / W2-D / W3-A 等会话按各自 prompt 必须加 target 或依赖，所以上表把所属包的 `Package.swift` 也给了它们，限制是"只加自己 target 的东西，不动别人的 target"。这一条脚本查不了，检查点会话合并时人工看 diff。
2. **共享测试素材目录**在仓库根：`Tests/Fixtures/`（W1-A、W1-E 产出，W2-A 消费）和 `Tests/References/`（W1-C、W3-B 的参考图）。放包外是因为它们跨包共用，且不会被 SwiftPM 当成 target。
3. **THIRD_PARTY/**：W1-D 内嵌 libsamplerate / libebur128 时放许可证的地方（它的 prompt 要求）；之后谁再内嵌第三方源码谁加目录。
4. **挂进 make lint 的新检查**：把脚本放在 `scripts/` 下、名字以 `check-` 或 `lint-` 开头，Makefile 会自动带上（`scripts/check-rt-symbols.sh` 就是这么进来的），不用改 Makefile。
5. 脚本只看**已提交**的改动（merge-base(main, 分支) → 分支顶）；加 `--include-working-tree` 可以把未提交的也算上，方便会话提交前自查。
