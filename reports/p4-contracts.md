# P4 契约落地三报告（分支 p4-contracts，worktree 分支 claude/p4-contracts-cleanup-be4431，同一提交）

prompt：docs/plan/prompts/67-P4-契约落地三.md。从 main `67d0f6b`（G4 第二批续做合入 + 017 落地之后）开。
**没有加改任何公开类型与 JSON 键**：改的是两处契约函数的行为（`Show.migratingLegacyKeys()`、reducer 的四条命令）、注释与文档。`Show.schemaVersion` 不升。

开工时问了用户三处 prompt 没写死、又牵涉契约口径的地方，用户 2026-09-27 三条都选了推荐项：

| 问题 | 用户定的 | 落点 |
|---|---|---|
| prompt 第 3 条"`MixerState.validate()` 也查它"怎么落（validate 现在只查结构，PGM / PVW / 叠加引用都不查） | **不动 validate()**：Stinger 与 PGM / PVW / 叠加引用同口径，只由 removeInput 清；另在搬迁里清掉 P4 之前存下的悬空 Stinger 引用 | 不加 `MixerStateError` 的 case；`Show.migratingLegacyKeys()` 多一步；CONTRACTS.md §2.5 写明"validate 不查引用" |
| 搬迁清死数据：停用的 border 格要不要一并清 | **全清**：搬完之后效果链里不再有任何 `border` 格 | `Show.migratingLegacyKeys()` |
| API 的 loadShow 也不经过 `Show.load`，要不要一并先搬迁 | **loadShow 也搬迁** | reducer 的 loadShow |

---

## 1. 做了什么

| # | prompt 交付 | 做了什么 | 提交 |
|---|---|---|---|
| 1 | 017 只核对 CONTRACTS.md §2.7 那一句与 `Stats.swift` 注释 | 两边**不一致**，按实现对齐：§2.7 键名表 `inputs{n:{peak_db}}` 漏了 `rms_db`（测试标准 §7 与 `InputMeter.jsonKeys` 都有）、`peak_db, rms_db` 多一个空格；017 那条挂在"P2 加的字段"下面，挪到自己一节"G4 续做落地的字段（提案 017）"并补上 [L, R]、20·log10(rms)、IEC 积分时间；`Stats.swift` 的 `rmsDb` 注释补上"下限 −120（`Meters.floorDb`）、C 热路径只累均方、开方与 dB 在 Swift 侧"，`Meters` 的总注释把 RMS 列进"20·log10、下限 floorDb"那一串。实现核过：`AudioEngine.statsMeters` = `decibels(fromLinear: sqrt(meanSquare))`，与注释一致 | aba8051、78f4999 |
| 2 | 契约注释 / 文档过期处（只改文字） | `FrameSlot.latest(atOrBefore:)`：单消费者 = 引擎的渲染线程，或分支槽（`SwitcherISO.InputFrameTee.addBranch`）的唯一读者（ISO tap / Aux 显示在显示刷新上读），`FrameSlotStats.consumed` 与协议头一句跟着改；`Show.migratingLegacyKeys()` 删"渲染器的后备路径还认它"、CONTRACTS.md §2.4 删"渲染器保留读它一个版本作后备"（§2.8 同类的"渲染器与 ExternalDisplaySpec 仍保留后备"一并改成现状：只剩 App `OutputExtras.displayNumber` 一处，归 W3-E3）；`MultiviewLayoutSettings.meters` 改成真实电平的口径（输入格画该路、PGM = Master、PVW = 当前 PVW 那路；纯音频格总是画、不看开关）；kind = multiview 的 `OutputState.enabled` = 要不要把多画面 NV12 送给下游、布局与它无关（`OutputState` / `Command.setOutputEnabled` / `RenderedFrame.multiview` 注释、CONTRACTS.md §2.5 / §3 / §8、命令目录）；`OverlayBorder.width` 加"界面只给到 0.05，0.05–0.1 只能从 API / 节目文件给"。顺带：CONTRACTS.md §2.4 的"多画面占位格与 App 接线待做"改成已做（W3-B2 / W3-E2）；文件头与变更记录补 015 / 016 / 017 / P4 | aba8051、78f4999、41ecaa2 |
| 3 | reducer 两条小规则（各一条用例） | ① `removeInput` 删掉 Stinger 用的那一路时 `transition.stinger.input` 置 nil（换底拍不动，删别的输入不碰）；② `addOutput` / `setOutputSettings` 进来的 `OutputSettings` 先过 `migratingLegacyKeys()`，**loadShow 整份先过 `Show.migratingLegacyKeys()`**（用户定）。命令校验器没改：搬迁不碰 `validate()` 查的结构，"校验器拒的 reducer 也原样返回"照旧成立（`testValidator_agreesWithReducer` 过）。`Command` 的注释、CONTRACTS.md §8、命令目录与 `docs/api.md`（switcher-apidoc 重新生成）同步 | 39acff6、aba8051、41ecaa2 |
| 4 | 搬迁遗留的死数据 | `Show.migratingLegacyKeys()` 搬完把 `border` 格**一律清掉**（没有叠加通道用到的、停用的、通道已有正式边框而没搬的；用户定全清）；另清掉 P4 之前 removeInput 留下的悬空 `transition.stinger.input`（用户定）。P3 那条"效果格留着"的断言按新口径改（prompt"用例跟着改"），新用例在 `ContractsP4Tests` | 3e67a4f |
| 5 | 提案状态、CONTRACTS.md 各表同步；schemaVersion 不升 | 010 / 013 / 016 / 017 加"后续："一行（后备删除、P4 的收口）；018 的"测试标准还没加 undelivered"改成已由 G4 加上；CONTRACTS.md §2.3 / §2.4 / §2.5 / §2.7 / §2.8 / §3 / §8 各表与段落；`Show.currentSchemaVersion` 仍是 1 | c598c1b、78f4999 |

新口径一句话版（CONTRACTS.md §2.5"输入引用的口径"）：状态里四处引用输入编号（program、preview、overlays[k].input、transition.stinger.input），
removeInput 把前两个置 0、后两个置 nil；`validate()` 只查结构不变量、不查引用；渲染器对不存在的输入按"没有这路"画；引用在命令入口由 `CommandValidator` 查。

---

## 2. 测试 ID：数值 / 阈值 / 通过否

（本会话不涉及任何阈值；下面"阈值"一栏是断言本身。）

| 测试 | 断言 | 结果 |
|---|---|---|
| `ContractsP4Tests.testP4_migrationClearsDeadBorderEffectSlots` | 五路输入各一种情形：启用 + 叠加用到 → 搬进通道；没人用的、停用的、通道已有正式边框的 → 不搬；**五路的 `border` 格一个不剩**、别的格原样且顺序不变；没有 border 格的输入一个字节不动；幂等；`Show.load` 读带 border 格的文件结果相同，写出再读回不变 | 通过 |
| `ContractsP4Tests.testP4_migrationClearsDanglingStingerReference` | `validate()` 对悬空 Stinger 不抛（不查引用）；搬迁后 `input` = nil、`cutAtTick` 与转场类型不动；指向存在的输入不动；幂等；`Show.load` 读老文件清掉 | 通过 |
| `ContractsP3Tests.testP3_migratingLegacyKeysIsIdempotentAndPrefersOfficialFields` | 末段"没有叠加通道用那路输入时效果格留着"改成"清掉"（prompt 交付 4"用例跟着改"），其余断言一条没动 | 通过 |
| `ReducerTests.testP4_removeInput_clearsStingerReference` | 删别的输入不碰 stinger；删 stinger 那路 → 只多 `stinger.input = nil`（与"原规则 + 这一条"的期望状态逐字段相等）；删完照当前 stinger 发 setTransitionParams 改 Wipe 生效 | 通过 |
| `ReducerTests.testP4_outputSettingsFromCommands_migrateLegacyKeys` | addOutput 带 `extra["layout"]` → `multiview` 正式字段、旧键清掉、别的 extra 键（`ndi.groups`）留着、结果 = `OutputSettings.migratingLegacyKeys()`；setOutputSettings 带 displayID / fallbackToMain → `display`；搬完与现状相同 → 原样返回（回执 applied = false）；正式字段已有值时旧键不覆盖；loadShow 老节目（输出旧键 + 叠加用到的 border 格）= `show.migratingLegacyKeys().makeState()` | 通过 |
| 017：`Contracts017Tests.test017_rmsDbRoundTripsAndMissingKeyDecodesToEmpty`、`StatsP2Tests` 的 jsonKeys 快照（`BusMeter` 8 键含 rms_db、`InputMeter` = [peak_db, rms_db]）、写出写全 | 往返、缺键 = 空数组、键名快照 | 通过（G4 写的，本会话只跑） |
| `CommandBusTests.testValidator_agreesWithReducer` | 校验器拒的命令 reducer 也原样返回 | 通过 |
| `CommandCatalogTests`（含 docs/api.md 与生成器同步） | 34 条、api.md 逐字等于 switcher-apidoc 输出 | 通过 |
| SwitcherRenderTests 的 V8 参考图 | 017 已由 G4 落地（新图 `v8-multiview-meters-rms.png`，`v8-multiview-meters.png` 没重生成）；本会话没动渲染器与参考图，只跑。**PGM / PVW 类 18 张 PSNR ∞；7 张多画面图 PSNR 58.3–60.2 dB（≥ 40 dB 的比对过），`MultiviewMetersTests` 里三处"逐像素相同"断言红**——本机 2026-09-25 升了 macOS 27，名字标签的中文字形变了；**main 67d0f6b 同样复现、本分支与 main 渲染结果逐像素相同**，不是 P4 引入。没改参考图也没放宽断言（铁律 9），问题单 `reports/issues/P4-w3-compositor-multiview-cjk-labels-macos27.md` | **红（环境，main 同样）** |
| 整仓测试（最终提交 3d2ba59；`make test` 在 SwitcherCore 红了就停，其余包 / 工具 / App 逐个补跑，见 §6） | 六个包 693 个用例：**红 4**——SwitcherRenderTests 3 处中文字形逐像素断言（环境，上一行）、TestKit `testW1A_syntheticVideo_60fps10s…` 平均唤醒延迟 0.546 ms > 0.5 ms（整包负载下偶发：单独重跑 3 / 3 过，0.006–0.009 ms）；跳 26（都是原有的 BLOCKED / 人工项，另 5 条"没有编好的 frameprobe"见 §6 补跑）。两个工具冒烟过。App 71 个：67 过、2 跳、**红 2**——`MultiviewSettingsTests.testThumbnails_ignoreLegacyLayoutKeyLikeRenderer`（**P4 预期内的行为变化**：API 带旧键的 addOutput 现在被搬成 3x3，用例的前提"旧键被忽略"不成立了；改法在本机验证过（只合 P4 / 连 w3-app-4 一起合两种各一份），App/ 不归本会话，交合并检查点：`reports/issues/P4-w3-app-4-legacy-layout-thumbnail-test.md`）与 `DiskProtectionAppTests.testS7_…` missed_render 1（整包负载下偶发：单独重跑 2 / 2 过） | 见左 |
| `git branch -f p4-contracts HEAD && make lint BRANCH=p4-contracts` | 禁词 / 版本号 / Package.swift 约束、依赖方向（8 个包）、归属（改动文件全在 P4 行内，没用胶水额度）、check-rt-symbols | **全绿**（exit 0） |

---

## 3. 没做的和原因

1. **App 那条过渡键缩略图用例没改**：P4 的 reducer 搬迁让它的前提失效（见 §2），App/ 不在 P4 的归属里（胶水额度只给 Packages/*）。
   两份补丁都在本机验证过、验证完已还原：A = 只合 P4（main + P4），B = W3-E3 的 w3-app-4 也合了（它改了同一条用例的缩略图算法）。交合并检查点，
   **合入 P4 时必须同时打其中一份**（`reports/issues/P4-w3-app-4-legacy-layout-thumbnail-test.md`，各十几行）。
2. **多画面参考图没重生成、断言没放宽**：macOS 27 下中文标签字形变了（main 同样复现），铁律 9 + OWNERSHIP（渲染器与参考图只为 017 动）→
   `reports/issues/P4-w3-compositor-multiview-cjk-labels-macos27.md`，交合成会话 / 用户定（钉字体 / 在 27 上重生成 / 掩标签三条路）。
3. **`MixerState.validate()` 不查 Stinger 引用**：用户 2026-09-27 定（见开头）。要查就得给 `MixerStateError` 加 case（公开类型变更），而且 PGM / PVW / 叠加引用 validate 也都不查，单查 Stinger 口径不一。
4. **`setInputSettings` / `addInput` 带进来的 `border` 效果格**：reducer 不搬也不清（prompt 只要 OutputSettings 与整份节目）。它们在状态里是死数据，存盘再读（`Show.load`）时被清掉。见 §4 第 1 条。
5. **几处不归本会话的过期文字，只记下没改**（归属外；胶水额度只给"必要的胶水"）：
   - `App/Sources/Settings/OutputSettingsPanel.swift:217` 的注释"没经过 Show.load 的内存状态（API 直接 addOutput 的老写法）可能还带过渡键"与那两处 `s.migratingLegacyKeys()`：
     P4 之后状态机里的状态不会再有输出的过渡键，调用成了多余（幂等、无害）。W3-E3（w3-app-4，已完成未合并）删了 `OutputExtras` 的后备但这两处还在——
     归下一个 App 会话或合并检查点（问题单"顺带"一节）。
   - `Tools/switcher-headless/Sources/switcher-headless/G4Factory.swift:14`"安全框 + 电平表占位"：W3-B2 之后是真实电平（headless 每秒 `setMeters`）——归检查点。
   - `Packages/SwitcherCore/Tests/SwitcherRenderTests/MultiviewLayoutTests.swift:252` 注释里的例子"API 直接 addOutput 的"：P4 之后 API 进不来了，用例本身（渲染器忽略旧键）仍成立——下一个合成会话顺手改（OWNERSHIP 的 P4 行写明渲染器测试只为 017 动）。
   - `Packages/SwitcherControl/Sources/SwitcherControl/SwitcherControl.swift:8`"27 个 case 的目录"（现在 34）：不在 CommandBus/ 下，留给控制会话。

---

## 4. 对契约的疑问

1. **输入效果链里的 `border` 格从命令进来还是死数据**：`setInputSettings` / `addInput` 带 `EffectSlot(id: "border")` 的，reducer 原样存（没有叠加通道的上下文就不好搬），渲染器不读，直到下次 `Show.load` 才清。
   现在没有任何客户端这么写（App 早就改写 `OverlayState.border`），所以没做。要收的话两种：reducer 对这两条命令也剥掉 border 格（行为变更，要有人拍板），或者校验器拒（改 API 行为）。建议 W4 / G5 一起定。
2. **`migratingLegacyKeys()` 的名字比它做的事窄了**：现在还清悬空 Stinger 引用与 border 格（都是"老版本写出来的数据变成新版本的样子"）。改名是公开 API 变更，不值得；注释写清了。
3. **validate 不查引用 → API 的 loadShow 带悬空引用照收**：PGM = 99 之类的节目文件能载入，渲染按"没有这路"画黑。`CommandValidator` 对 loadShow 只跑 `validate()`。要更严的话得给 `MixerStateError` 加 case，走提案。
4. P3 报告 §4 第 4 条（Command 按字段加 case 越来越多，建议将来收成 `setOverlaySettings` 之类的整体替换）：本会话没加 case，仍是 34 个；那是破坏性的 wire format 变更，要走提案，留给有需要的会话。

---

## 5. 下一个会话需要知道的坑

1. **`make lint` 要显式给分支名**（同 P3）：worktree 分支是 `claude/p4-contracts-cleanup-be4431`，OWNERSHIP 里是 `p4-contracts`，所以 `git branch -f p4-contracts HEAD && make lint BRANCH=p4-contracts`。
2. **reducer 的 loadShow 现在先搬迁**：拿 `reduce(.loadShow(show))` 与 `show.makeState()` 比的用例，节目里要是带过渡键 / border 格 / 悬空 Stinger 就不相等了——比 `show.migratingLegacyKeys().makeState()`。现有用例的节目都不带，全过。
3. **将来谁要给 `validate()` 加引用检查**：校验器（loadShow 只跑 validate、不搬迁）与 reducer（先搬迁、再 validate）会对"悬空 Stinger"判得不一样，`testValidator_agreesWithReducer` 那条不变量就破了——要么校验器也先搬迁，要么 reducer 先 validate 再搬。
4. **`border` 这个效果格 id 被搬迁永久占用**：`Show.load` 会无条件剥掉 `InputSettings.effects` 里 id = "border" 的格。以后真要做输入级的视频效果，别用这个 id。
5. **App 里 OutputSettingsPanel 的两处 `migratingLegacyKeys()` 现在是死路径**（状态机里的状态不会再有输出的过渡键；`OutputExtras.displayNumber` 的后备 W3-E3 在 w3-app-4 上已删）：删的时候不用担心 API 客户端。
   **合并顺序**：P4 与 w3-app-4、w3-outputs-4 两两 `git merge-tree` 无冲突、没有共同改动的文件；但 App 那条过渡键缩略图用例两边都动了语义——先合谁都行，按问题单选补丁 A（只合 P4）或 B（w3-app-4 也合了）。
6. **本机 2026-09-25 升了 macOS 27.0（26A428）+ CLT 27.0**：7 张多画面参考图的中文标签字形变了（问题单见 §3 第 2 条），整仓测试在这台机器上不会全绿，别当成新代码的回归。
   `make test-packages` 遇到第一个红的包就 `exit 1`（SwitcherCore 排第一），后面五个包、工具、App 都不跑——要逐个补跑（本会话的做法见 §6）。
7. **新 worktree 里 Outputs 有 5 条要 release 版 frameprobe**（`MediaMTXTests` 四条 + `ISOAlignmentTests.testA4_…`），没编就 XCTSkip（"BLOCKED-工具"），不会红：
   先 `swift build -c release --package-path Tools/frameprobe`（本机 49 s）再跑。
8. **两条计时用例在整包负载下偶发**：TestKit `testW1A_syntheticVideo_60fps10s…` 的平均唤醒延迟（< 0.5 ms）与 App `DiskProtectionAppTests.testS7_…` 的 missed_render 不增；
   本会话各单独重跑 3 次 / 2 次全过。红了先单独重跑再下结论。
9. 跑测试时本机没有别的会话在跑重活、盖子开着、屏幕没锁，ExternalTests 14 个（跳 1 人工）这次都跑成了（G4 锁屏时没跑成的那组）。

---

## 6. 运行记录

机器：Apple M5 Max / **macOS 27.0（26A428，2026-09-25 升级）** / Xcode 27.0；接电、盖子开着、屏幕没锁，内建屏 + 外接 2560×1440；跑的时候本机没有别的会话在跑重活（开跑前 `pgrep` + `lsof -d cwd` 查过）。
所有测试都套 `caffeinate -u -i -d -s`。日志在本会话的 scratchpad（不入库）。

| 什么 | 命令 | 提交 / 时间 | 结果 |
|---|---|---|---|
| 新用例先红 | `swift test --package-path Packages/SwitcherCore --filter 'ContractsP4Tests\|ContractsP3Tests/testP3_migratingLegacyKeys\|ReducerTests/testP4'` | 实现前，09:40 | 按预期红（5 条用例：4 条新的 + P3 改断言的那条，共 16 处断言） |
| 实现后 Contracts + Engine | `swift test --package-path Packages/SwitcherCore --filter 'SwitcherContractsTests\|SwitcherEngineTests'` | 39acff6 前后，09:41–09:43 | Contracts 81（跳 1 原有）/ 0，Engine 93 / 0 |
| 命令目录 / 校验器 | `swift test --package-path Packages/SwitcherControl --filter 'CommandCatalogTests\|CommandBusTests'` | 41ecaa2，09:49 | 2 / 0、6 / 0（含 api.md 同步、`testValidator_agreesWithReducer`） |
| 整仓第一轮 | `make test` | c598c1b，09:50–09:58 | SwitcherCore：Render 93 红 4（3 处中文字形逐像素 + `testDisplay_maxFrameRateCapsThumbnailBlits`）、Engine 93 / 0、Contracts 81 / 0；**make 在这个包停了**（exit 2） |
| main 上复现 | `git worktree add --detach <scratch>/main-check main` → 同样四条 → `git worktree remove` | 67d0f6b，10:0x | **同样 4 处红**；main 与本分支渲染出的 `v8-multiview-meters(-rms).png` 逐像素相同；main 与参考图差 819 像素（PSNR 59.49 dB） |
| 其余包逐个补跑 | `swift test --package-path Packages/<包>` × 5 | 3d2ba59，10:01–10:42 | Inputs 55（跳 6）/ 25（跳 2）/ 25（跳 3）全过；Audio 63（跳 2）/ 41（跳 3）全过；Outputs 9 / 25 / 28（跳 4）/ 8（跳 2）/ 7（跳 1）/ 14（跳 1）全过；Control 25（跳 1）/ 3 / 28 全过；TestKit 70 红 1（唤醒延迟 0.546 ms，见 §2） |
| 工具冒烟 | `make test-tools` | 3d2ba59，10:42–10:43 | switcher-headless 0.1.0、frameprobe 0.1.0 |
| App | `make test-app` | 3d2ba59，10:43–10:47 | 71 个：67 过、2 跳、红 2（过渡键缩略图 = P4 预期内、S7 = 偶发，见 §2） |
| SwitcherCore 最终一轮 | `swift test --package-path Packages/SwitcherCore` | 3d2ba59，10:48–10:55 | Render 93 红 3（只剩中文字形那 3 处；显示那条这轮过了）、Engine 93 / 0、Contracts 81（跳 1）/ 0 |
| 两条计时用例单独重跑 | TestKit 那条 × 3；App S7 `-only-testing` × 2 | 3d2ba59，10:56–11:00 | 3 / 3 过（唤醒延迟平均 0.006–0.009 ms）；2 / 2 过 |
| App 过渡键用例的补丁 A | 临时改 `App/Tests/MultiviewLayoutTests.swift` → `xcodebuild test -only-testing:SwitcherTests/MultiviewSettingsTests` → `git checkout` 还原 | 3d2ba59 + 补丁，10:5x | 2 / 2 过；diff 进问题单，分支不含 App/ 改动 |
| App 过渡键用例的补丁 B（w3-app-4 也合了之后） | 临时 detached worktree：w3-app-4 `merge --no-ff p4-contracts` → `make gen` → 同上只跑这个类，打补丁前后各一次 → 删 worktree | ec648ee + 678556d，11:13–11:18 | 不打补丁红 1、打了 2 / 2 过；没动任何分支 |
| 要 release frameprobe 的 5 条 | `swift build -c release --package-path Tools/frameprobe`；`swift test --package-path Packages/SwitcherOutputs --filter 'MediaMTXTests\|ISOAlignmentTests/testA4'` | 3d2ba59，11:00–11:12 | MediaMTX 整组 6 条（E2/E3 67 s、E7 76 s、E8 172 s、E9 337 s、RTMP、SRT）与 ISO A4 全过 |
| lint | `git branch -f p4-contracts HEAD && make lint BRANCH=p4-contracts` | 3d2ba59，11:1x | 全绿 |

**汇总（最终提交 3d2ba59）**：六个包 693 个用例，红 4（3 处环境 + 1 处负载偶发），跳 26（原有 BLOCKED / 人工项；另 5 条 frameprobe 项补跑全过）；工具冒烟 2 / 2；App 71 个红 2（1 条 P4 预期内、补丁已验证，1 条负载偶发）。
**本分支自己的改动没有引起任何非预期的红**：唯一与 P4 相关的红（App 过渡键缩略图）是 prompt 要的行为变化本身。
