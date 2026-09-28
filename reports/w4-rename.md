# W4-D 产品改名 PlusMix——分支 w4-rename

prompt：docs/plan/prompts/75-W4D-产品改名PlusMix.md。从 main `c8e43cc` 开（W2-A3 合入之后）。机器：M5 Max，macOS 27.0（26A428），Xcode 27.0，xcodegen 2.46.0，NDI SDK for Apple 6.3.2，0 个代码签名身份（ad-hoc）。
用户 2026-09-28 定：产品名 **PlusMix**，bundle id 前缀 com.plusmix（G5 已切成 `com.plusmix.switcher`，本会话不动）。原则：**只改用户看得到的名字**；代码名 Switcher（模块、target、scheme、
`SwitcherVersion`、`switcher-headless` / `frameprobe`、Package 名、Stats 字段、Localizable 的键名、`.switcher.json` 后缀、bundle id）一律不动，不改契约，不做全仓库替换，docs/spec 与 docs/plan 不改，lint 禁词表不变。
提交：`0cfaeae` 先写测试 → `a548c0a` App → `b05311a` 扩展显示名 → `93e63cc` 发布脚本 → `fc19bd4` 文档与 Stream Deck 插件 → `18fa018` / `e376546` 两个 project.yml 补丁（TEST_HOST、PRODUCT_MODULE_NAME）→ 本报告与两份问题单（分支顶）。

## 1. 做了什么

先写测试（提交 `0cfaeae`，铁律 2），再按交付逐个提交：

### 1.1 App（交付 1，`a548c0a` + `18fa018` + `e376546`）

| 处 | 改成 |
|---|---|
| project.yml App target | `PRODUCT_NAME: PlusMix` → 产物 PlusMix.app、CFBundleName、可执行 Contents/MacOS/PlusMix；**加了两条钉住代码名的设置**：`PRODUCT_MODULE_NAME: Switcher`（Swift 模块名默认跟 PRODUCT_NAME 走，不钉 App/Tests 的 `@testable import Switcher` 就解析不到）、SwitcherTests 的 `TEST_HOST` / `BUNDLE_LOADER` 写死成 `$(BUILT_PRODUCTS_DIR)/PlusMix.app/Contents/MacOS/PlusMix`（XcodeGen 按宿主 target 名推 TEST_HOST、不看 PRODUCT_NAME）。工程名 `name: Switcher`、target / scheme `Switcher`、bundle id 都没动，Makefile 的 `-scheme Switcher` 不用改 |
| App/Info.plist | `CFBundleDisplayName` = PlusMix；`NSCameraUsageDescription` / `NSMicrophoneUsageDescription` 里的 Switcher → PlusMix；CFBundleName 仍是 `$(PRODUCT_NAME)` |
| App/Resources/{zh-Hans,en}.lproj/Localizable.strings | 7 个键的值：`menu.about` / `menu.hide` / `menu.quit`（关于 / 隐藏 / 退出 PlusMix）、`aux.external.windowTitle`（PlusMix 外部输出）、`diagnostics.save.name`（PlusMix-诊断-%@.zip / PlusMix-diagnostics-%@.zip）、`diagnostics.readme`（"PlusMix 诊断包"）、`bottom.noRecordOutputTip`（~/Movies/PlusMix）；键名不动；两种语言的值里现在一个 "Switcher" 都没有（新用例钉住） |
| App/Sources/ProductName.swift（新） | `ProductName.display` = Info.plist 的 CFBundleName（= PRODUCT_NAME，所以产品名只在 project.yml 一处定义；拿不到退 "PlusMix"）、`ProductName.executable` = CFBundleExecutable |
| App/Sources/AppDelegate.swift | App 菜单标题 `"Switcher"` → `ProductName.display` |
| App/Sources/UI/MainWindowController.swift | 主窗口标题 3 处 `"Switcher \(版本)"` → `"\(ProductName.display) \(版本)[ — 节目名]"` |
| App/Sources/Settings/OutputSettingsPanel.swift | 新建 NDI 发送的默认源名 `"Switcher"` → `"PlusMix"`（App 侧默认值；包内默认值不动） |
| App/Sources/Show/ShowDocuments.swift | 默认录制目录 `~/Movies/Switcher` → `~/Movies/PlusMix`（Finder 里用户天天看的目录；0.1.0 没发布过，不迁移）。`autosaveURL` 的 `Application Support/Switcher` **故意没改**：hotkeys.json / midi.json / Diagnostics/ 都在 SwitcherControl 包的 `UserConfig.directory` 下，配置目录要一个整体，等包一起换（§3 第 2 条，注释里写了） |
| App/Sources/Release/DiagnosticBundle.swift | zip 顶层目录 `Switcher-diagnostics-<时间>` → `PlusMix-diagnostics-<时间>`；系统崩溃报告按**可执行名**前缀收（`~/Library/Logs/DiagnosticReports/PlusMix*.ips`——可执行名变了不跟着改就一份都收不到）；`log show` 的进程名同样从 CFBundleExecutable 来 |

没动的写死字符串（用户看不到）：`MIDINotificationAnchor` 的 CoreMIDI 客户端名 "Switcher MIDI anchor"、主窗口 `setFrameAutosaveName("SwitcherMainWindow")`、UserDefaults 测试 suite、临时目录名。

### 1.2 虚拟摄像头扩展显示名（交付 2，`b05311a`）

CameraExtension/Info.plist 的 `CFBundleDisplayName` 默认值（ASCII）→ "PlusMix Virtual Camera"；CameraExtension/Resources/en.lproj → "PlusMix Virtual Camera"、zh-Hans.lproj → "PlusMix 虚拟摄像头"。
扩展的 bundle id、mach service、entitlements 不动。**摄像头设备在 FaceTime 里的名字仍是 "Switcher"**（`VirtualCameraConstants.deviceName`，Packages/SwitcherOutputs，归 W3-C，见 §3 第 1 条与问题单）。

### 1.3 发布产物名（交付 3，`93e63cc`）

- `archive.sh`：从 project.yml 读 App target 的 `PRODUCT_NAME`（第一个 `PRODUCT_NAME:`；扩展的在后面、等于它的 bundle id），xcarchive / .app / DMG 都按它命名，并校验归档里确实有 `$product.app`；主二进制路径按 `CFBundleExecutable` 找；报告标题 "发布归档报告：PlusMix 0.1.0"。
- `dmg.sh`：默认卷名从包的 `CFBundleDisplayName` 推（"PlusMix 0.1.0"）；`sign.sh` / `verify.sh` / `release.mk` / `appcast.sh` 只是用法与注释里的名字（它们本来就按 Info.plist 找可执行）。
- `scripts/release/tests/`：`lib.sh` 加 `product_name()` / `app_executable()`，产物按 `*/*.app` 找；R1 断言 `PlusMix.xcarchive` / `PlusMix.app` / `PlusMix-0.1.0.dmg`、`Contents/MacOS/PlusMix`、CFBundleName / DisplayName / Executable = PlusMix、bundle id 不变、旧产物名不再出现、报告标题；R12 断言两种语言的显示名与 Info.plist 默认值的**准确值**、扩展 bundle id 不变；R2 / R4 / R5 不再写死 `Switcher.app` / `MacOS/Switcher`。
- `make archive-adhoc` 出 `.build/release/0.1.0/PlusMix.xcarchive`、`PlusMix.app`、`PlusMix-0.1.0.dmg(.sha256)`（§2）。

### 1.4 文档与 Stream Deck 插件（交付 4，`fc19bd4`）

- README.md、Samples/README.md、docs/user（中英 10 个文件）、docs/api（README / examples / vmix-compat / 示例客户端的 docstring）、docs/integrations（stream-deck / vmix-compat）、docs/testing（README 中英 / 测试标准 / 设备兼容性）、docs/release（README / signing / sparkle / diagnostics / third-party / checklist-first-signed-run）里指产品的 Switcher → PlusMix；
  README.md、docs/user/README.md、docs/user/en/README.md、docs/release/README.md 各留一句"代码名 Switcher（模块 / 命令行工具 / scheme / bundle id 仍叫这个名字）"。
- 跟着代码一起变的：Debug 产物 `.build/DerivedData/Build/Products/Debug/PlusMix.app`、`PlusMix.app/Contents/MacOS/PlusMix`、`open -a PlusMix`、`log show --predicate 'process == "PlusMix"'`、崩溃报告 `PlusMix*.ips`、`~/Movies/PlusMix`、发布产物名、扩展显示名、`atos -o PlusMix.app.dSYM/…/PlusMix`。
- 照实保留的：模块名、`switcher-headless`、`SwitcherVersion`、`App/Switcher*.entitlements`、`Switcher.xcodeproj`、`.switcher.json`、`~/Library/Application Support/Switcher`（包内配置目录）、兼容层 `<edition>` = "Switcher"（包内默认值，注明）、FaceTime 里的摄像头名 "Switcher"（注明"0.1.0 里设备名仍是代码名"）。
- docs/CONTRACTS.md 第 183 行"App 相对 `~/Movies/Switcher`"改成 PlusMix 并注明 `MixerState.swift` 的注释待契约会话顺手改（§4）。
- Stream Deck 插件：manifest.json 的 `Name` / `Author` / `Category` / `Description` → PlusMix（Stream Deck 里的分类名从 "Switcher" 变 "PlusMix"），package.json 的 description、README 标题；UUID（`com.plusmix.switcher.*`）、目录名、npm 包名不动。
- `python3 docs/tools/check-links.py`：119 个 Markdown 全绿（标题改了产品名，没有锚点指向它们）。

### 1.5 归属

OWNERSHIP 的 W4-D 行原来没有 App/Tests：prompt 75 交付 5 点名 LocalizationTests / ReleaseTests 与新用例，窗口标题改了 ShortcutAndShowTests 的一行断言也必须跟。
按 W1-A3 / W3-C2 的先例，**本会话在 W4-D 行自记了这三个文件**（`App/Tests/LocalizationTests.swift` `App/Tests/ReleaseTests.swift` `App/Tests/ShortcutAndShowTests.swift`）并在备注里标"检查点合并时请复核这次授权"。
`make lint BRANCH=w4-rename` 全绿（60 个改动文件都在范围内）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

### 2.1 App（`make test-app` 全量；计数从 `.build/DerivedData/Logs/Test/*.xcresult` 用 `xcrun xcresulttool get test-results summary` 读）

`make test-app`（2026-09-28 14:18，`-quiet`，机器上没有别的 xcodebuild；xcresult `.build/DerivedData/Logs/Test/Test-Switcher-2026.09.28_14-18-33-+0800.xcresult`）：
**92 个用例：88 过、0 失败、4 跳**，181 s。4 条跳过都是原有的 BLOCKED，与改名无关：`testA4_app_isoRoutesSharedStartAndStop_filesAlignWithin1Frame` 与 `testStream_10sToLocalMediaMTX_framesContinuous`
（BLOCKED-工具：新 worktree 里跑 App 测试时还没编 release 版 frameprobe——本会话随后 `make build-tools` 编的是 debug 版，那两条要 `swift build -c release --package-path Tools/frameprobe` 后单独复跑）、
`testInputs_builtInCameraLiveWithin5sAndPictureShows`（BLOCKED-权限：摄像头 TCC 未授权）、`testL1_virtualCameraEgress_requiresSignedExtension`（BLOCKED-签名）。
比 main 上一次记录（W3-E4 后 86 用例 84 过 2 跳）多 6 条：本会话 2 条 + 续做会话（prompt 76–83 那批）合入的用例。

| ID | 测什么 | 结果 | 通过否 |
|---|---|---|---|
| `ReleaseTests.testW4D_displayNameIsPlusMix_codeNameUntouched`（新） | Info.plist 的 CFBundleDisplayName / CFBundleName / CFBundleExecutable = PlusMix、包名 PlusMix.app、用途说明含 PlusMix 不含 Switcher；bundle id 仍 `com.plusmix.switcher`；`SwitcherVersion.current` = CFBundleShortVersionString；project.yml 的 `PRODUCT_NAME: PlusMix` 且 `name: Switcher` / `Switcher:` target / bundle id 原样；扩展 Info.plist 默认显示名 + 两种语言的 InfoPlist.strings 准确值 + 编进 App 的扩展里两份都在；App 菜单标题 = PlusMix、主窗口标题以 "PlusMix 0.1.0" 开头、默认录制目录以 /Movies/PlusMix 结尾 | 全部断言过 | ✅ |
| `LocalizationTests.testW4D_uiStringsUseProductNameNotCodeName`（新） | 点名的 7 个键两种语言都含 PlusMix；两张表里**没有任何一条值含 "Switcher"**；关于 / 外部输出标题 / 录制提示 / 诊断包文件名的准确值 | 全部断言过 | ✅ |
| `LocalizationTests` 既有 6 条 | 键集合一致无空值、源码用到的键都在、无中文字面量、包状态查表、缺键回退、l10n-exempt | 6 / 6 过 | ✅ |
| `ReleaseTests.testR7_…`（加一行） | 诊断包顶层目录以 `PlusMix-diagnostics-` 开头 | 过 | ✅ |
| `ShortcutAndShowTests.testShow_controllerRoundTripReplacesSession`（改一行） | 打开节目后窗口标题 = "PlusMix 0.1.0 — round" | 过 | ✅ |

定向跑（`-only-testing` 新用例 + LocalizationTests + ShortcutAndShowTests）：16 用例 0 失败，2.7 s。

### 2.2 发布产物

`make archive-adhoc`（2026-09-28 14:23，用时 83 s，其中 `xcodebuild archive` Release / arm64 70 s）：

| 项 | 数值 | 期望 | 通过否 |
|---|---|---|---|
| 产物 | `.build/release/0.1.0/PlusMix.xcarchive`、`PlusMix.app`（50 MB）、`PlusMix-0.1.0.dmg`（16 MB，UDZO）+ `.sha256`、`verify.json`、`release-report.md`、`logs/` | 产物名 = PRODUCT_NAME（PlusMix），旧名一个不剩 | ✅ |
| release-report.md 标题 | "发布归档报告：PlusMix 0.1.0" | 产品名 | ✅ |
| verify.json | version 0.1.0 / build 1 / bundle_id `com.plusmix.switcher`；signature_valid true、adhoc true、notarized false（预期）、extension_signed true、extension_strings_en / zh-Hans true、ndi_bundled true、sparkle_signed true、archs arm64、dmg_checksum / dmg_contains_app true | 与 W4-B 报告 R1 相同，只是名字变了 | ✅ |
| 公证 | BLOCKED-账号（报告里两行都标了） | 同 W4-B | — |

### 2.3 `make release-test`（scripts/release/tests/，日志 `.build/release-tests/`）

跑了两遍（都在改名后的树上，`.build/release-tests/`；R1 每遍自己 ad-hoc 归档一次到 `.build/release-tests/r1/0.1.0/`，82–99 s）：

| ID | 测什么 | 数值 | 通过否 |
|---|---|---|---|
| R1 `test-r1-archive-adhoc` | ad-hoc 全链 + **新产物名** | **42 项断言全过**：project.yml PRODUCT_NAME = PlusMix；PlusMix.xcarchive / PlusMix.app / PlusMix-0.1.0.dmg(.sha256) 都在、Switcher.app / Switcher.xcarchive 不再出现；Contents/MacOS/PlusMix、CFBundleExecutable / CFBundleName / CFBundleDisplayName = PlusMix、bundle id = com.plusmix.switcher、版本 0.1.0、LSMinimumSystemVersion 15.0；签名 / 扩展 / libndi / Sparkle / 许可证 / DMG（挂载后有 PlusMix.app 与 Applications 链接）/ 报告标题 "PlusMix 0.1.0" / verify.json；App 起 4 s 不崩 | ✅ |
| R12 `test-r12-extension-strings` | 扩展显示名 | 7 / 7：en = "PlusMix Virtual Camera"、zh-Hans = "PlusMix 虚拟摄像头"（含中文）、Info.plist 默认 "PlusMix Virtual Camera"、扩展 bundle id 不变 | ✅ |
| R2 `test-r2-verify-rejects-unsigned` | 坏包被拒（包名 / 可执行名从产物读） | 4 / 4 | ✅ |
| R4 `test-r4-runtime-symbols` | 主二进制（Contents/MacOS/PlusMix，按 CFBundleExecutable 找）与 dylib 不引用 `_swift_initBorrow` | 4 / 4 | ✅ |
| R5 `test-r5-appcast` | appcast（DMG / .md 按 PlusMix-0.1.0 命名，下载地址 `…/PlusMix-0.1.0.dmg`） | 19 / 19 | ✅ |
| R3 / R13 / R14 | 钉版本 / make 入口 / 版本工具（没改） | 6 / 6、9 / 9、14 / 14 | ✅ |
| R6 `test-r6-workflows` | actionlint + 工作流关键字（没改） | 第二遍 17 / 17；**第一遍 16 / 17**：`nightly.yml 跑 make soak-1h（找不到 [soak-1h]）` 一次性红——文件里明明有 5 处 `soak-1h`（同一变量上的 `schedule` / `perf-baseline` 断言都过），单独重跑与第二遍全过；R6 与 .github/ 相对 main 零改动，第一遍时后台正并行跑 `make build-packages`。查不出机制（`printf | grep -q` + `pipefail`），记在 §5 | ✅（一次性红，复跑过） |
| R11 `test-r11-set-bundle-id` | bundle id 一键切换 | 失败：1 / 22 项断言：`--check 报出当前 App 前缀 com.example` 找不到——G5 切到 com.plusmix 之后就红，**W4-B2（prompt 83）交付 1 的活**，与本会话无关（reports/issues/G5-w4-release-r11-assumes-placeholder-prefix.md） | ❌（已知，归 W4-B2） |

汇总：第一遍 PASS 8 / FAIL 2（R11 + R6 一次性）/ SKIP 0；第二遍 **PASS 9 / FAIL 1（只剩 R11）/ SKIP 0**。

### 2.4 其他

| 项 | 结果 |
|---|---|
| `make gen` + `make build-app` | 过；Debug 产物 `PlusMix.app`（Contents/MacOS/PlusMix，Info.plist CFBundleName / CFBundleDisplayName = PlusMix，CFBundleIdentifier = com.plusmix.switcher，扩展嵌在 Contents/Library/SystemExtensions/） |
| `make build`（六包 + 两工具 `swift build`） | 过：`make build-packages build-tools`（六包 + switcher-headless + frameprobe 的 debug `swift build`）0 个 error，退出 0；改名没碰任何包，只是确认整树能编 |
| `python3 docs/tools/check-links.py` | 通过：119 个 Markdown 的相对链接与锚点都能解析，Samples 节目文件合法 |
| `make lint BRANCH=w4-rename` | 全绿：禁词（扫 Packages App Tools CameraExtension project.yml）、版本号 0.1.0 一致、Package.swift 约束、依赖方向 8 个包、归属 60 个文件、CSwitcherAudioRT 实时符号 |
| Stream Deck 插件 `npm test` | 没跑：worktree 里没有 node_modules、本会话不联网装；manifest.json / package.json 只做了 JSON 合法性检查（UUID 没动，插件测试不看显示名） |

## 3. 没做的和原因

1. **FaceTime / QuickTime 里的摄像头设备名仍是 "Switcher"**：`VirtualCameraConstants.deviceName` / `deviceModel` / 两条流名在 Packages/SwitcherOutputs（W3-C 的），不在本会话范围。系统设置里扩展叫 "PlusMix 虚拟摄像头"、会议软件里摄像头叫 "Switcher"，两个名字对不上——建议 0.1.0 发布前改（发布后用户在会议软件里选过的设备名就变了）。问题单 reports/issues/W4D-packages-user-visible-code-name-leftovers.md 第 1 条，文档都照实写了并注明。
2. **`~/Library/Application Support/Switcher` 没改名**：目录定义在 SwitcherControl 的 `UserConfig.directory`（W2-C 的），hotkeys.json / midi.json / Diagnostics/ 与 App 的 LastSession 都在里面，App 单独改 LastSession 会把配置目录拆成两个；帮助 → 打开诊断文件夹 打开的就是它。问题单第 2 条；用户手册与 diagnostics.md 照实写。
3. **兼容层 XML `<edition>` 仍报 "Switcher"**：`VMixCompatConfiguration.edition` 默认值在包里（W3-D）。问题单第 3 条。
4. **`.github/workflows/release.yml` 写死了 `Switcher-<版本>.dmg` / `.md` / 标题**：`.github/` 归 W4-B，prompt 83（W4-B2）的范围也没有它；改名后发布工作流会在"收集产物"一步失败（现在本来就 BLOCKED-账号 / 没有远程）。问题单 reports/issues/W4D-w4-release-github-release-workflow-product-name.md，两种修法都写了。
5. THIRD_PARTY/{NDI,Sparkle}/SOURCE.md、NOTICE.md、CameraExtension/README.md、Packages/SwitcherOutputs 两处注释里的 `Switcher.app/…` 路径：不在范围内、只是说明文字，列在问题单末节。
6. docs/release/bundle-id.md（"等用户定域名"已过时）没动：prompt 83 交付 3 指定 W4-B2 记"已定 com.plusmix"。
7. R11（`test-r11-set-bundle-id`）红：写死 `--check 报出当前 App 前缀 com.example`，G5 切到 com.plusmix 之后就红了，与本会话无关，是 W4-B2 交付 1（见 §2.3）。
8. 没改的代码名（有意）：模块名、target / scheme / 工程名、`SwitcherVersion`、`switcher-headless` / `frameprobe`、Stats 字段、Localizable 键名、`.switcher.json` 后缀、`show.switcher.json`、`App/Switcher*.entitlements` 文件名、bundle id、Stream Deck 的 UUID / 目录 / npm 包名、MIDI 锚客户端名、窗口 autosave 名、UserDefaults suite、临时目录名。
9. docs/spec、docs/plan、docs/checklists、docs/contract-changes、reports/ 是历史文档，没改。

## 4. 对契约的疑问

- 没有契约变更。`SwitcherVersion`（类型名与值）、Stats 字段、Command / Show 的 JSON 都没动。
- `Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift` 第 429 行 `RecordSettings.directory` 的注释写着"App 相对 `~/Movies/Switcher`"，App 现在是 `~/Movies/PlusMix`：只是注释、不是契约，本会话不能动包，docs/CONTRACTS.md 第 183 行已改并注明，请下一次契约会话顺手改那行注释。
- `Samples/tools/make-shows.py` 第 134 行 docstring 同一句话（Samples/ 只有 README 在本会话范围内），归 W4-C。

## 5. 下一个会话需要知道的坑

1. **改 PRODUCT_NAME 会连带两件事**，都已在 project.yml 钉住：（a）Swift 模块名默认 = PRODUCT_NAME，App/Tests 的 `@testable import Switcher` 直接 "Unable to resolve module dependency: 'Switcher'"——`PRODUCT_MODULE_NAME: Switcher`；（b）XcodeGen 2.46 给测试 target 生成的 `TEST_HOST` 按宿主 **target 名**拼（`Switcher.app/Contents/MacOS/Switcher`），不看 PRODUCT_NAME——SwitcherTests 的 `TEST_HOST` / `BUNDLE_LOADER` 写死成 PlusMix 的路径（"Could not find test host for SwitcherTests" 就是这个）。
2. 进程名变成 PlusMix：`log show --predicate 'process == "PlusMix"'`、崩溃报告 `~/Library/Logs/DiagnosticReports/PlusMix-*.ips`、Activity Monitor 里叫 PlusMix；系统设置 › 隐私与安全性 里按显示名显示 "PlusMix"（TCC 记录按 bundle id，没变）。Debug 产物在 `.build/DerivedData/Build/Products/Debug/PlusMix.app`，仓库里 scripts/gate*.sh 之类没有引用 Debug App 路径（查过），docs/checklists/G3、G4 的老路径是历史清单。
3. 发布脚本读的是 project.yml 里**第一个** `PRODUCT_NAME:`（App target）；扩展 target 的 PRODUCT_NAME 等于它的 bundle id，在后面。谁把 target 顺序换了，`archive.sh` 会在"归档里没有 X.app"处停下（它校验了）。`make release-test` 的 R1 自己再归档一次到 `.build/release-tests/r1/`，与 `make archive-adhoc` 的 `.build/release/0.1.0/` 是两份。
4. `~/Movies/Switcher` 里的旧录像不会搬；开发机上节目文件里写相对录制目录（Samples 的 `教会` / `教室` / `活动`）现在落在 `~/Movies/PlusMix/` 下。
5. 两条新用例读的是仓库源文件（`AppTest.repoRoot()` 找 CLAUDE.md）：project.yml、CameraExtension/Info.plist 与两份 InfoPlist.strings；再改产品名要一起改测试里的字面量（故意写死，测试不从实现里抄期望值）。
6. `ProductName.display` 在运行时读 CFBundleName：headless / 非 bundle 进程拿不到就退字面量 "PlusMix"；Localizable.strings 里的产品名是字面量，改名要两边一起。
7. W3-C 改 `VirtualCameraConstants.deviceName` 时要跟的文档六处列在问题单里（docs/user 四处、docs/release 两处）；改 `UserConfig.directory` 时跟的文档七处也在。
8. 桌面端的 Edit / Write 工具拒绝写别的 worktree，本会话所有改动用 python 精确替换（old 必须唯一）写入。
9. `make release-test` 的 R6 出过一次性红（`soak-1h` 找不到，§2.3）：断言用的是 `printf '%s' "$var" | grep -q -- "$pat"` 加 `set -o pipefail`，怀疑与并行的 `swift build` 有关但没复现；再撞到就单独 `scripts/release/tests/run.sh test-r6-workflows` 复跑一次，连续红才算真红。
10. 后台跑长任务：Bash 工具 `run_in_background` 的命令仍受 10 分钟超时（`make test-app` + `archive-adhoc` + `release-test` 连跑会被杀成 144），改用 `nohup <脚本> & disown` 再用 until 循环等日志里的 `exit=` 行。
