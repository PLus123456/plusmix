# P5-8 报告：契约落地十一——`StreamURLRedaction` 搬进 SwitcherContracts（提案 035 已批方案 A1 的第 ① 步）（prompt 136，分支 `p5-contracts-8`，2026-10-31）

工作树 `.claude/worktrees/p5-contracts-8`，分支就叫 `p5-contracts-8`，从 main c7d441a（= g12 头）开。不 push、不 merge：做完交 G13（prompt 140）。
提交：914c502 红用例 + 金样 → 2ff784f 搬迁 → 1304572 文字 → （本报告）。契约改动按提案 035 的裁定做（用户 2026-10-25 批方案 A1，三步里的第 ① 步），没有新的契约问题要问。

## 1. 做了什么

顺序按 prompt：① 先写用例、看着红 → ② 搬 → ③ CONTRACTS.md 一句往返规则（写明 137 落地后生效）→ ④ 提案 035 文末落地记录 → ⑤ Core 整包 / StreamingTests / App ReleaseTests / check-deps / lint → ⑥ 本报告。

| 交付 | 落地 | 提交 | 文件 |
|---|---|---|---|
| **金样（搬迁前的输出）** | 用 main c7d441a 上 SwitcherStreaming 版本的 `StreamURLRedaction.swift`（git blob 9960823…）**直接编译**（`swiftc` + 一个 60 行生成器，在会话 scratchpad）跑出 1041 个地址 + 10 段文字的输入 → 输出：NS12 编码参数名、NS09 路径末段、拆法六条、**差分表 5 × 17 × 11 = 935 种全部**、userinfo / SRT / 不是地址（StreamAuthTests.testE）、诊断包 R8、名单 11 个名字原样 / 大写、边角 16 + 15 条、文字 10 段。一条一行、键排序、不转义斜杠 | 914c502 | `Packages/SwitcherCore/Tests/SwitcherContractsTests/Fixtures/redaction-035/StreamURLRedaction-premove.json` |
| **红用例（Contracts）** | `Contracts035Tests` 7 条：公开接口（名字 / 签名 / 默认值 / 名单 / 文件只 import Foundation）、NS12 全部输入、NS09 全部输入 + 拆法六条 + 诊断包 R7 的整条地址、差分代表 12 条（期望 = 搬迁前原文）、userinfo / SRT / 不是地址 + R8 + 边角、文字、金样逐条核对（并钉死差分输入 = 表里 935 种同一顺序、分组集合、条数） | 914c502 | `Packages/SwitcherCore/Tests/SwitcherContractsTests/Contracts035Tests.swift` |
| **红用例（Streaming）** | `StreamURLRedactionTests.test035_movedToContracts_sameTypeAndPremoveOutputsIdentical`：`SwitcherStreaming.StreamURLRedaction.self == SwitcherContracts.StreamURLRedaction.self`、这个包的文件只剩 typealias、同一份金样经推流包的名字再跑一遍。原四条不动（import 本来就有 `SwitcherContracts`，没改），文件头加一行注释 | 914c502 | `Packages/SwitcherOutputs/Tests/StreamingTests/StreamURLRedactionTests.swift` |
| **搬迁** | 整个文件**逐字节不变**地到 `Sources/SwitcherContracts/StreamURLRedaction.swift`（`git diff -C` 认 copy 100%，blob 还是 9960823…）；只用 Foundation；`marker` / `secretQueryParams` / `redact(url:marker:publishNameInPath:)` / `redact(text:marker:)` 的名字、签名、默认值一个不改；内部 `userinfoRange` / `publishNameRange` / `redactQuery` 跟着搬（仓库里没有别处用它们）。umbrella `SwitcherContracts.swift` 文件一览加一行 | 2ff784f | `Packages/SwitcherCore/Sources/SwitcherContracts/StreamURLRedaction.swift`、`SwitcherContracts.swift` |
| **typealias** | 推流包原文件只剩 `public typealias StreamURLRedaction = SwitcherContracts.StreamURLRedaction`（外加两行注释）。推流日志 / 错误文字（StreamDestination、RTMPAdobeAuth、HaishinKitTransport、TransportErrorText）、App 的 ShowRedaction（诊断包）/ StreamAddress（地址框）/ BottomBarView（底栏提示）/ OutputRuntime（invalidURL 文案）、用例 StreamAuthTests / TransportErrorTextTests / App PlaybackStatusTests **一行不改**，全部编得过（Outputs 测试包 + App build-for-testing 都过） | 2ff784f | `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift` |
| **CONTRACTS.md** | 标题 / 变更记录加 P5-8；新 **§2.11 推流地址打码**（`StreamURLRedaction` 的类型行 + 提案正文第 1–4 条的"API 对外打码与往返规则"：`streamKey` → `<redacted>`、`url` 的 userinfo / 密钥类查询参数 / 密钥栏空时的路径末段换标记；`setOutputSettings` 收到打码值 = 保留原值；`addOutput` / `loadShow` 带标记 → 400；原文要 `?secrets=1` + token），**每处都写"137 W2-C6 落地后生效，现在 API 还是原文"**；§2.5 `StreamSettings` 行与 §3 速查各加一句指过去 | 1304572 | `docs/CONTRACTS.md` |
| **提案 035 落地记录** | 文末"落地记录（第 ① 步）"：搬了什么、哪些调用点没动、用例名、CONTRACTS.md 改了哪、交出去的 | 1304572 | `docs/contract-changes/035-api-state-stream-credentials.md` |

**为什么用金样而不是只抄字面期望**：差分那 935 种原来逐条交给 `StreamDestination` 判"认出了发布名就不能剩"，契约测试见不到 SwitcherStreaming；要证明"搬迁前后逐字相同"，期望必须在搬之前从旧代码产出——所以先用旧文件直接编译跑出全部输出入库，搬完后两个包各核一遍。
口径以后变了：`SW_REDACTION_GOLDEN_WRITE=1 swift test --package-path Packages/SwitcherCore --filter SwitcherContractsTests.Contracts035Tests/test035_goldenPremove` 会按当前实现重写期望（输入不动），看 diff 再提交。

**探针（铁律 10）**：App 与 StreamingTests 都同时 `import SwitcherContracts` 和 `import SwitcherStreaming` 再裸写 `StreamURLRedaction`——枚举和指向它的 typealias 从两个模块进来会不会 ambiguous？写了三个模块的 20 行探针（A 定义 enum，B `public typealias Foo = A.Foo`，main 两个都 import 后 `Foo.f(...)`）：编得过、`Foo.self == A.Foo.self` 为 true。Swift 对解析到同一类型的多个结果不报歧义，所以调用点一行不用改；真实构建（Outputs 测试包、App）也证实了。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

契约类用例没有阈值，"通过"= 断言全过。"先红"是搬迁前（914c502 的树）真跑出来的结果，日志在会话 scratchpad `logs/red/`；绿灯日志在 `logs/green/`。

| 用例 | 测什么 | 先红 | 结果 |
|---|---|---|---|
| `Contracts035Tests.test035_publicSurfaceUnchanged` | `marker` = `<redacted>`、名单 = 11 个名字、`redact(url:)` 的两个默认值、`redact(text:)` 的默认值、完整签名能赋给函数类型、契约文件只 `import Foundation` | 编译错 `cannot find 'StreamURLRedaction' in scope`（Contracts 里还没有） | ✅ |
| `…test035_NS12_encodedSecretParamNamesAreRedacted` | 搬迁前 testNS12 的全部输入 + 名单 11 个名字原样 / 大写 | 同上 | ✅ |
| `…test035_NS09_publishNameInPathRedacted` | 搬迁前 testNS09 的 20 条 + 拆法六条 + 默认 false 两条 + R7 整条地址 + `rtmpt://` 不算 | 同上 | ✅ |
| `…test035_NS09_differentialRepresentatives` | 差分表挑 12 种（大写协议 + userinfo + 端口、制表符开头 + `?pass=1 `、`%2f` 段 + 全角空格、`..` + CRLF、原文一段解码两段 + 片段、`%zz` + 换行、多字节、`;` 参数、`%2F` 段首 / 段尾、末段全是 `%2F` + 片段），期望 = 搬迁前原文 | 同上 | ✅ |
| `…test035_userinfoSRTAndNonURL` | StreamAuthTests.testE 的 7 条 + R8 的 3 条 + 边角 16 条（空串、`rtmp://`、`://`、空 userinfo、只有用户名、没 `=`、空值、`a=b`、空项、片段、大小写混合 + `pass%3D`、`x+y-z.1://`、IPv6 + 发布名、中文路径） | 同上 | ✅ |
| `…test035_textRedaction_everyAddressInText` | testE 的 Swift 打印原文、`NetConnection.Connect.Rejected see …`、停止字符 `" < > \ ^ ` { | }` 各一、换行 / 制表符分隔、`•••` 记号、没有地址、空串、没有协议名的 `://` | 同上 | ✅ |
| `…test035_goldenPremove_everyInputRedactsIdentically` | 金样 1041 个地址 + 10 段文字逐条 = 搬迁前输出；差分输入 = 表里 935 种同一顺序、全 `publishNameInPath`、默认标记；分组集合；条数 | 同上 | ✅ **1041 + 10 全部相同，0 条不同** |
| `StreamURLRedactionTests.test035_movedToContracts_sameTypeAndPremoveOutputsIdentical` | typealias 指向契约类型、推流包文件只剩别名、同一份金样经 `SwitcherStreaming.StreamURLRedaction` 再跑一遍 | 编译错 `module 'SwitcherContracts' has no member named 'StreamURLRedaction'` | ✅ |
| `StreamURLRedactionTests` 原四条（NS12、NS09、差分、拆法） | 照旧 | — | ✅ 5 条 0.016 s；差分照旧"935 种里 StreamDestination 认出发布名的 880 种全部遮住" |
| **Core 整包** `swift test --package-path Packages/SwitcherCore` | 三个模块 | — | ✅ SwitcherRenderTests 101 / SwitcherEngineTests 140 / SwitcherContractsTests 137（1 skip = 既有的 `StatsP2Tests.testP2_stats_oldGateFilesParse`，本机没有老 gate 文件）= 378 条 0 失败；339 s / 149 s / 40 s |
| **Outputs** `swift test --package-path Packages/SwitcherOutputs --filter 'StreamingTests\.'` | 整个 StreamingTests target（12 个 suite） | — | ✅ 78 条执行、68 过、**10 skip、0 失败**，855 s。skip：9 条 MediaMTX 端到端"BLOCKED-工具：没有编好的 frameprobe"（新工作树还没编 release frameprobe，见 §5）+ 1 条 `AMF0LimitTests.testNS04_haishinKitOwnParser_deepReply` BLOCKED-SDK（132 留的，HaishinKit AMF0 递归）。编好 frameprobe 后的复跑见下一行 |
| Outputs 复跑 `MediaMTXTests` / `StreamAuthMediaMTXTests`（`make frameprobe-release` 53 s 之后，`--filter` 不支持 `\|` 所以分两次） | 那 9 条 skip 的 | — | ✅ MediaMTXTests 8 / 8（735 s）、StreamAuthMediaMTXTests 5 / 5（75 s），0 skip 0 失败。合起来 StreamingTests target = **77 过、1 skip（BLOCKED-SDK）、0 失败** |
| **App** `xcodebuild … test-without-building -only-testing:SwitcherTests/ReleaseTests` | 诊断包 R7 / R8 / Release / NS09 / NS12（经 ShowRedaction → typealias）+ R9 / R10 / W4D | — | ✅ 8 / 8，2.87 s（`make gen` 后 build-for-testing 成功；xcodebuild 输出里 "CoreSimulator is out of date" 是噪音） |
| `scripts/check-deps.sh` | 契约不许 import 别的包 | — | ✅ 8 个包依赖方向正确 |
| `make lint BRANCH=p5-contracts-8` | 禁词 / 版本号 0.1.0 / Package.swift 约束 / check-deps / check-ownership（8 个改动文件都在允许范围内）/ build-help 18 文件 / check-links 224 个 md / check-rt-symbols | — | ✅ 全绿（`LC_ALL=en_US.UTF-8`）；`check-ownership.sh p5-contracts-8 --include-working-tree` 也过 |
| 探针：三模块 typealias 歧义 | 见 §1 | — | 不歧义（编得过、`Foo.self == A.Foo.self`） |

## 3. 没做的和原因

1. **API 打码本身**（对外状态 / WS 快照 / 命令日志、`?secrets=1` 要 token、`addOutput` / `loadShow` 带标记 400）：第 ② 步，归 137 W2-C6（APIModels / StateFeed / APIServer + docs/api.md 重生成）。CONTRACTS.md 里的往返规则已写、标了"137 落地后生效"；KNOWN_ISSUES"推流凭据外泄两处"的 ② 到 137 再销号。
2. App 三处注释还写"推流包的 StreamURLRedaction"（`App/Sources/Release/ShowRedaction.swift:2 / :11`、`App/Sources/Settings/StreamAddress.swift:9`）：不在本会话归属，行为没错，只是出处过期——交 139 W5-S 或 137 顺手改。
3. 金样没放仓库根的 `Tests/Fixtures`（跨包共用素材的约定位置）：不在归属。放在 Contracts 测试目录，StreamingTests 那条按相对路径（`Packages/SwitcherOutputs/Tests/StreamingTests/` → `../../../SwitcherCore/Tests/SwitcherContractsTests/Fixtures/redaction-035/`）读，与 Contracts034Tests 用 `#filePath` 找夹具是同一做法。
4. `Packages/SwitcherCore/Package.swift` 没加 `exclude` / `resources`（不在归属）：SwiftPM 构建 SwitcherCore 时既有的告警 `'switchercore': found N file(s) which are unhandled; explicitly declare them as resources or exclude from the target` 从 main 的 8 个文件（034 的 audit-20261022 七份 + g4-show-before-p3.json）变成 9 个（多了本会话的金样）。不影响构建与测试；要消掉得在 `SwitcherContractsTests` 的 testTarget 上加 `exclude: ["Fixtures"]`（夹具都按 `#filePath` 读、不走 Bundle.module），交 G13 胶水或下一个契约会话。
5. 没动阈值、没加命令（仍 42 个 case）、JSON 形态不变、`docs/api.md` 不变。

## 4. 对契约的疑问

1. 本步按裁定只搬、不改口径。搬的时候把现有行为的几个边角钉进了用例（期望 = 搬迁前原文），**137 写 API 打码时值得知道**，要不要改由用户定：
   - 标记里带 `/ ? #` 时路径末段找不到（`redact(url: "rtmp://u:p@h/a/K", marker: "#", publishNameInPath: true)` → `rtmp://#@h/a/K`）：userinfo 先换成标记、再在换过的串上拆路径。真实标记 `<redacted>` / `•••` 不含这些字符，API 用默认标记不受影响。
   - 查询参数值连着后面的空白一起换：`…?pass=1 ` → `…?pass=<redacted>`（尾空白是值的一部分）；空 userinfo（`rtmp://@h/app`）也会换成 `rtmp://<redacted>@h/app`；`redact(text:)` 把没有协议名的 `://u:p@h` 也当地址打码。都无害。
2. CONTRACTS.md §2.11 / §3 / §2.5 三处"137 落地后生效，现在 API 还是原文"的字样，137 合入时要翻成现在时（137 的 prompt 没写这一句，G13 合并时留意）。
3. 128 P5-6（输出编号上限）与本路都动 SwitcherContracts 与 CONTRACTS.md 的标题 / 变更记录：128 叠在本分支头上开，或等 G13 合入本路后从 main 开（prompt 136 已写）；两路文件不重叠（128 在 MixerState / Command 一侧），只有 CONTRACTS.md 标题那一行会撞、好解。

## 5. 下一个会话需要知道的坑

1. **新工作树先 `make frameprobe-release`**，否则 StreamingTests 的 9 条 MediaMTX 端到端用例 skip "BLOCKED-工具：没有编好的 frameprobe"（各等 14–171 s 再跳，整个 target 跑 14 分钟）。本会话第一遍就撞上了。
2. 金样的条数在两个测试里都钉死（1041 / 10 / 差分 935）：改输入清单要同时改 `Contracts035Tests`（清单 + 条数）与 `StreamURLRedactionTests.test035_`（条数）；只改口径不改输入用 `SW_REDACTION_GOLDEN_WRITE=1` 重写期望即可。
3. `git log --follow` 跟不到新路径的历史：旧路径还在（变成了 typealias），git 认的是 copy 100% 不是 rename；要看历史用 `git log -C --stat` 或按 blob 9960823 找。
4. 两个模块都 import 再裸写 `StreamURLRedaction` 不歧义（同一类型的 typealias，探针 + 真实构建都过）；`@testable import SwitcherStreaming` 下模块限定写法 `SwitcherStreaming.StreamURLRedaction` 也能用。
5. 137 叠在本分支头上开时 `make lint BRANCH=w2-control-6` 要加 `--base p5-contracts-8`（check-ownership 默认对 main 比）。
6. `ls -t .build/DerivedData/Logs/Test/*.xcresult` 会列到包里的 Info.plist，取最新 xcresult 要 `ls -td …/*.xcresult | head -1`；不带 `-quiet` 的 xcodebuild 日志本身就逐条列用例（`Executed 8 tests`），本会话按日志计数。
7. 生成金样那种"把包里一个只依赖 Foundation 的文件直接 `swiftc` 编进探针"的办法很省事（不用起整个包），但顶层代码的文件必须叫 `main.swift`，否则 "statements are not allowed at the top level"。
