# W4-B 发布工程（签名、公证、更新、CI）——分支 w4-release

prompt：docs/plan/prompts/71-W4B-发布工程.md。从 main da44bec 开。机器：M5 Max，macOS 27.0 (26A428)，Xcode 27.0 (27A266a)，Swift 6.4，xcodegen 2.46.0；
`security find-identity -v -p codesigning` = 0 个身份（没有 Apple Developer Program 账号）→ 所有签名 / 公证 / 扩展激活项 BLOCKED-账号 / BLOCKED-签名，
脚本在 ad-hoc 下走通除公证外的全部步骤（prompt 测试段的要求）。NDI SDK 装在 /Library/NDI SDK for Apple（v6.3.2.0，2026-04-13）。仓库没有 GitHub 远程、本机没装 Actions runner。

## 1. 做了什么

### 1.1 `make archive`（交付 1）——scripts/release/

- `release.mk`（根 Makefile 末尾 `-include`）：`archive` / `archive-adhoc` / `release-verify` / `appcast` / `release-test` / `pin-check` / `pin-sync` / `runner-install` / `sparkle-keys`。
- `archive.sh`：钉版本检查 → `make gen`（DEVELOPMENT_TEAM 决定权限表）→ `xcodebuild archive`（Release、arm64、`-onlyUsePackageVersionsFromResolvedFile`、Sparkle 两键作命令行设置）→
  导出（Team：`-exportArchive` developer-id；ad-hoc：拷 xcarchive 里的 App）→ 随包 `libndi.dylib` + 许可证、`install_name_tool -delete_rpath` 删掉指向 SDK 目录的 LC_RPATH、
  所有 SwiftPM 依赖与 THIRD_PARTY 的许可证进 `Contents/Resources/Licenses/` → `sign.sh` 由内向外重签（dylib → Sparkle 的 XPC / Autoupdate / Updater.app → 框架 → 系统扩展（保留权限表）→ App）→
  `verify.sh` → `dmg.sh`（App + Applications 链接，UDZO，sha256）→ `notarize.sh`（先 App 后 DMG，各自 staple；凭据三选一）→ DMG 终校验 → `release-report.md` + `verify.json`。
  模式自动：有 Team ID 且钥匙串有该 Team 的 "Developer ID Application" 才走签名，否则 ad-hoc 并在报告里把公证标 BLOCKED-账号。
- `verify.sh`（prompt 的 spctl -a -vv 验证脚本）：`codesign --verify --deep --strict`、身份 / Team / 硬化运行时、`spctl --assess --type execute -vv`、`stapler validate`、扩展在且带 app-sandbox、
  两种语言的 InfoPlist.strings、链接了 libndi 就必须随包且无 SDK rpath 且带许可证、Sparkle.framework 与两个键、架构 / 最低系统；DMG 另查 `hdiutil verify`、Applications 链接、DMG 签名 / staple。
  `--expect-notarized` 要求 spctl accepted + staple；`--json` 出结构化结果。
- project.yml：`ENABLE_HARDENED_RUNTIME: YES`（ad-hoc 时 Xcode 自动关：构建日志 note "Disabling hardened runtime with ad-hoc codesigning"，探针见 §5）；
  App/Switcher-signed.entitlements 加 `device.camera` / `device.audio-input`（硬化运行时下访问摄像头 / 麦克风必须；不加正式版摄像头黑屏）。
- 文档：docs/release/signing.md（步骤、权限表矩阵、干净机器清单、常见错误）。

### 1.2 Sparkle（交付 2）

- project.yml `packages.Sparkle`（SwiftPM 二进制，`exactVersion: 2.10.0`，2026-09-13 发布；模板钉 tag 提交 eef1a539），App 依赖 `package: Sparkle`；Xcode 把 Sparkle.framework 嵌进 Contents/Frameworks 并签名（Debug 与归档都验过）。
- App/Info.plist：`SUFeedURL = $(SPARKLE_FEED_URL)`、`SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)`；project.yml 默认两者为空 → 开发 / ad-hoc / 测试宿主里不起 Sparkle、不连任何更新源；`archive.sh` 从环境变量注入真实值。
- `App/Sources/Release/UpdateController.swift`：两键都有且非测试宿主才起 `SPUStandardUpdaterController`；`SWITCHER_APPCAST_URL` / UserDefaults `updateFeedURLOverride` 可指到本地 appcast（本地验证用）。
  App 菜单 "检查更新…"（未配置时弹一句说明）；偏好设置 → 更新：状态（未配置 / 上次检查时间）、自动检查开关（apply 写回 Sparkle）、检查更新、导出诊断包。
- `sparkle-keys.sh generate | public | export --to | import`：EdDSA 私钥进登录钥匙串（服务 https://sparkle-project.org），永远不进仓库；`appcast.sh <目录> --download-url-prefix … [--account | --ed-key-file -]`
  调 Sparkle 发行包里的 `generate_appcast`（`sparkle-bin.sh` 在 .build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin 找）。
- 文档：docs/release/sparkle.md（密钥、appcast、托管到 GitHub Releases、本地 appcast 验证一次的步骤）。

### 1.3 崩溃与诊断（交付 3）

- `CrashDiagnostics.swift`：`MXMetricManager` 订阅 + `pastDiagnosticPayloads` 回收，负载 JSON 原样落到 `~/Library/Application Support/Switcher/Diagnostics/<crash|hang|cpu|disk>-yyyyMMdd-HHmmss.json`，只留 100 份，不上传。
- `DiagnosticBundle.swift` / `DiagnosticsExport`：帮助 → 导出诊断包…（偏好设置里也有）→ 同意对话框（含崩溃诊断与日志 / 只导出设置与统计 / 取消）→ 存储面板 → 后台打 zip：
  README、system.txt、settings.txt（token 只写 set / not set）、stats-latest.jsonl（`Stats.jsonLine()`，与 stats.jsonl 同一套字段）、stats.jsonl（开了 --stats 时）、show.switcher.json（过 `ShowRedaction`）、config/、crashes/（同意时）、log.txt（`log show` 本程序与扩展进程，同意时）。
- `ShowRedaction.swift`：JSON 层去密钥——`streamKey` 等键的值、url 查询串里 passphrase / key / token / password / secret / streamid / auth / user / pass / pwd 的值 → `<redacted>`，主机 / 端口 / 路径保留。
- 文档：docs/release/diagnostics.md。

### 1.4 CI（交付 4）

- `.github/workflows/ci.yml`：每次 push（tag 除外）+ 每个 PR 跑 `l0-l1`（pin-deps check → lint（分支有归属行就是 `make lint BRANCH=<分支>`，没有就 `ci-ownership.sh --no-ownership`）→ make gen → `make test`）；PR 再跑 `l2`（`make gate4-run` 10 分钟场景）；都在 `[self-hosted, macOS, ARM64, switcher]` 上、包 `caffeinate -u -i -d -s`。
- `nightly.yml`：每天 03:00（Asia/Shanghai）`make soak-1h` → `make perf-baseline`（非零 = job 失败 = 退步阻塞）；两个目标是 W4-A 的，合入前第一步就红并说明。
- `release.yml`：`v*` tag / 手动 → tag 与 MARKETING_VERSION 一致 → `ci-keychain.sh import`（secret 里的 .p12 进一次性钥匙串）→ `make archive` → `appcast.sh --ed-key-file -`（secret 私钥）→ 清理 → artifact → GitHub Release 草稿。
- `ci-runner-setup.sh`（`make runner-install RUNNER_FLAGS="--url … --token …"`）：下载最新 osx-arm64 runner、注册、`svc.sh` 装成 LaunchAgent（登录会话，App 测试要窗口服务器），末尾打印人工项（自动登录 / 不休眠 / TCC / powermetrics 免密码 sudo / 装 SDK）。
- `actionlint` 零告警（`.github/actionlint.yaml` 登记 runner 标签）。文档：docs/release/ci.md（工作流表、runner、secrets 表、本地对应）。

### 1.5 版本号与变更日志规范、KNOWN_ISSUES 模板（交付 5）

- docs/release/versioning.md（版本号只在两处、构建号单调、tag 时机、CHANGELOG 格式、发布顺序）；docs/release/CHANGELOG-template.md、KNOWN_ISSUES-template.md（G5 拷成 docs/KNOWN_ISSUES.md）。
- `bump-version.sh X.Y.Z [--build N]`：同时改 project.yml 两处、Version.swift、CHANGELOG 的"未发布"→ 版本 + 日期并补新的"未发布"；拒绝不合法 / 倒退。`changelog.sh X.Y.Z` 抽小节（发布说明与 appcast 的更新说明）。
  跑它们是 G5 的事（版本号归属），本会话没改版本号。

### 1.6 依赖钉版本与升级（交付 6）

- `pin-deps.sh check | list | sync | upgrade <identity> <version> <revision> | verify-runtime <mach-o>…`：七份 Package.resolved（模板 + 五份入库 + 工作区）对 30 个依赖钉法一致、swift-collections ≤ 1.6.x；
  `verify-runtime` 用 `nm -u` 查 `_swift_initBorrow`。`archive.sh` 第一步就是 check，xcodebuild 带 `-onlyUsePackageVersionsFromResolvedFile`。
- 模板 scripts/xcode-workspace-Package.resolved 加了 sparkle 一项（2.10.0 / eef1a539），originHash 与 Xcode 解析后一致。
- **没升 swift-collections**：1.7.0 要 Swift 6.4 运行时；本机 macOS 27.0 的 libswiftCore 已导出 `_swift_initBorrow`（`dyld_info -exports /usr/lib/swift/libswiftCore.dylib | grep swift_initBorrow` = 1 条，§5 第 7 条的答案：27 上不崩），
  但产品最低系统 macOS 15、用户机器多在 26.x，升了就是发出去起不来，所以钉法不变；升级流程与放行条件（macOS 15 / 26 各起一次）写在 docs/release/dependencies.md。本机已是 27.0，26.x 的验证只能靠别的机器（BLOCKED-机器）。

### 1.7 正式 bundle id 与 Stream Deck UUID（交付 7）

- **没有定域名**（只有用户能定；docs/release/bundle-id.md 列了决定项与后果：发布后不能改）。做了 `set-bundle-id.sh --check | --list | <前缀> [--dry-run]`：按内容搜出全部出现处（project.yml、扩展 Info.plist / entitlements / README、
  VirtualCameraConstants、App 测试 suite、Stream Deck 插件 manifest / plugin.js / package.json / README / test / scripts + 目录改名、docs/integrations/stream-deck.md），一次改完；VMixCompat 的 `reportedVersion` 不在此列。
  R11 在副本上验过：旧前缀一处不剩。定了域名后由检查点跑一次、一次提交（跨五个归属）。

### 1.8 NDI 运行库随包（交付 8）

- 主二进制链接的是 `@rpath/libndi.dylib`，rpath 表里 `@executable_path/../Frameworks` 在 SDK 目录之前（探针 §5）；`archive.sh` 拷 libndi.dylib（universal，Vizrt 签名）进 Contents/Frameworks、删 SDK rpath、用本产品身份重签（硬化运行时的库校验要求）；
  `libndi_licenses.txt`（SDK 要求随二进制分发）+ NOTICE.md 进 Contents/Resources/Licenses/NDI/。THIRD_PARTY/NDI/（NOTICE.md 逐条对照再分发条款、SOURCE.md、licenses 副本）、THIRD_PARTY/Sparkle/（LICENSE、SOURCE.md）、THIRD_PARTY/README.md 加两行；docs/release/third-party.md 列全部随包组件。
- 没装 SDK 的机器：Package.swift 探测不到就空实现，verify.json 记 `links_ndi=false`，报告标"这份构建不含 NDI"。

### 1.9 扩展显示名中英两份（交付 9）

- CameraExtension/Resources/{en,zh-Hans}.lproj/InfoPlist.strings（"Switcher Virtual Camera" / "Switcher 虚拟摄像头"），project.yml 的扩展 target 加了这个 sources 路径；Info.plist 默认值仍是 ASCII（W3-C3 定）。归档出的 .systemextension 里两份都在（R12）。

### 1.10 第一次签名跑通的验证清单（交付 10）

- docs/release/checklist-first-signed-run.md：硬化运行时下摄像头 / 麦克风、libndi 库校验、扩展激活与显示名、'sonp' 四步、`consumeNext` 递归的 CPU、`VirtualCameraAppTests` 的 L1、那条 Sendable 警告、公证 / Gatekeeper、本地 appcast 更新一次、升依赖的 15 / 26 验证。全部 BLOCKED-签名 / 账号。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

脚本测试在 scripts/release/tests/（`make release-test`，日志 .build/release-tests/）；App 测试在 App/Tests/ReleaseTests.swift（`xcodebuild test -only-testing:SwitcherTests/ReleaseTests`）。

| ID | 测什么 | 数值 | 阈值 / 期望 | 通过否 |
|---|---|---|---|---|
| R1 `test-r1-archive-adhoc` | `archive.sh --adhoc --skip-notarize` 全链 | 33 项断言全过：archive 63–85 s；App 50 MB、DMG 16 MB（UDZO）；`codesign --verify --deep --strict` 过；扩展嵌入且可验；libndi.dylib 在 Contents/Frameworks 且已重签、主二进制无 SDK rpath、许可证在；Sparkle.framework 嵌入（Installer.xpc 等已签）；Info.plist 带 SUFeedURL / SUPublicEDKey（空）；LSMinimumSystemVersion 15.0；DMG `hdiutil verify` 过、sha256 对、挂载后有 App + Applications 链接；报告公证行 BLOCKED-账号；verify.json signature_valid=true / notarized=false；App 起 4 s 不崩 | 每项都要过；公证 BLOCKED-账号 | ✅ |
| R2 `test-r2-verify-rejects-unsigned` | verify.sh 抓坏包 | 4/4：原包过；去主二进制签名 → 非 0；改包内资源一字节 → 非 0（--deep --strict）；ad-hoc 包 `--expect-notarized` → 非 0 | 三种坏包都要非 0 | ✅ |
| R3 `test-r3-pinned-deps` | 钉版本一致 | 6/6：7 份 Package.resolved 对 30 个依赖钉法一致；swift-collections 1.6.0；把一份改成 1.7.0 后 check 非 0 且点名 | 一致；≤ 1.6.x | ✅ |
| R4 `test-r4-runtime-symbols` | 归档二进制不要新运行时 | 4/4：Switcher 主二进制、libndi.dylib、libswiftCompatibilitySpan.dylib 都不引用 `_swift_initBorrow`（frameprobe 本 worktree 没编，跳过那一项） | 0 个坏符号 | ✅ |
| R5 `test-r5-appcast` | appcast 生成与验签 | 19/19：文件私钥 → 公钥注入副本 → ad-hoc 重签 → dmg.sh → appcast.xml 带 edSignature、version=1、shortVersionString=0.1.0、minimumSystemVersion 15.0、hardwareRequirements arm64、嵌入更新说明；`sign_update --verify` 过，改一字节 / 换钥匙都失败；stdin 读私钥可用；SUPublicEDKey 为空的包出的 appcast 无签名（记录行为） | 签名在且验得过 | ✅ |
| R6 `test-r6-workflows` | CI 工作流 | 17/17：actionlint 零告警；ci.yml self-hosted + make lint + make test + gate4-run + PR 触发；nightly.yml 定时 + soak-1h + perf-baseline + caffeinate；release.yml tag 触发 + make archive + secret 的 Team ID、无写死密钥 | 零告警 | ✅ |
| R7 `testR7_diagnosticBundleContainsRequiredFilesWithoutSecrets`（App） | 诊断包内容与去密钥 | 通过（2.65 s）：README / system / settings / stats-latest / show / log / crashes / config 都在；扫 ≥ 5 个文本文件无推流密钥、无 API token；show 里 streamKey=`<redacted>`、主机端口保留；system.txt 有 app_version / bundle_id / macos / model / chip_or_cpu / memory_gb / gpu；stats-latest 是合法 JSON | 密钥 0 处出现 | ✅ |
| R8 `testR8_showRedactionStripsStreamKeyAndURLSecrets`（App） | 去密钥规则 | 通过：passphrase / streamid / token / KEY 的值 → 标记，其他参数与非 url 原样；Show 往返合法；空 streamKey 不动 | 全部断言 | ✅ |
| R9 `testR9_crashDiagnosticsStoreWritesListsAndPrunes`（App） | MetricKit 落盘 | 通过：5 份按时间命名、列表升序、prune 留 3、summary 3 行；订阅 / 退订状态正确 | 全部断言 | ✅ |
| R10 `testR10_updateEntryPointsPresentAndUnconfiguredWithoutKey`（App） | 更新入口 | 通过：测试宿主 isConfigured=false、状态文案 = 未配置、lastCheckDate=nil；App 菜单有"检查更新…"（action 对）；帮助菜单有导出诊断包 / 打开诊断文件夹；占位文案已换 | 全部断言 | ✅ |
| R11 `test-r11-set-bundle-id` | bundle id 一键切换 | 22/22：--check 报两个前缀；--list 含 17 个文件；副本切到 io.example-domain 后旧前缀 0 处、Stream Deck 目录改名、动作 UUID 一起换；仓库本体校验和不变 | 0 处残留 | ✅ |
| R12 `test-r12-extension-strings` | 扩展显示名中英 | 6/6：归档的 .systemextension 里 en / zh-Hans 的 InfoPlist.strings 都在、中文那份含中文；Info.plist 默认 ASCII | 两份都在 | ✅ |
| R13 `test-r13-make-targets` | make 入口 | 9/9：archive / archive-adhoc / release-verify / appcast / release-test / pin-check / pin-sync / runner-install 可解析；make help 提到 archive | 全部可解析 | ✅ |
| R14 `test-r14-version-changelog` | 版本号 / 变更日志工具 | 14/14：bump 0.2.0 --build 7 三处 + CHANGELOG 都对；changelog.sh 抽出小节；拒绝 v1 与倒退；仓库本体校验和不变 | 全部断言 | ✅ |
| LocalizationTests（App，既有 5 条） | 新增 21 个键两种语言齐、源码里用的键都在、无中文字面量 | 5/5 过 | 既有阈值 | ✅ |

`make release-test`：PASS 10 / FAIL 0 / SKIP 0（134 项断言）；App：ReleaseTests 4 过 + LocalizationTests 5 过。
`make lint`：lint-rules / check-deps 绿；check-ownership 红 = §4 列的 20 个越界文件（都是 prompt 点名的交付）。
六包 `swift test` 没动包代码、没跑；App 全量没跑（见 §3 第 10 条）。

BLOCKED 项（都写进 docs/release/checklist-first-signed-run.md）：

| 项 | 状态 | 解锁条件 |
|---|---|---|
| Developer ID 签名、公证、staple、spctl accepted | BLOCKED-账号 | Apple Developer Program + Team ID + "Developer ID Application" 证书 + notarytool 凭据（docs/release/signing.md）；脚本的 Team 路径按 Apple 文档写、没在真证书上跑过 |
| 干净机器装 DMG 首次启动无 Gatekeeper 拦截 | BLOCKED-账号 | 同上；ad-hoc 版本机验证见 §2 表 R1 的起动冒烟（本机不另建用户账户：ad-hoc 一定被拦，结论已知） |
| 虚拟摄像头扩展激活 | BLOCKED-签名 | Team ID + /Applications + 系统设置允许（W3-C 起） |
| Sparkle 从本地 appcast 更新成功一次 | BLOCKED-签名 | Sparkle 要求新旧 App 代码签名一致（ad-hoc 每次签名不同，Sparkle 会拒装）；步骤写在 docs/release/sparkle.md §5，appcast 生成与验签本机已过（R5） |
| CI 真跑（三个工作流） | BLOCKED-账号 | 仓库没有 GitHub 远程、本机没装 runner；`make runner-install` + 建远程后第一次 push 即跑；本机只做了 actionlint（R6） |
| 升依赖后 macOS 15 / 26 各起一次 | BLOCKED-机器 | 本机已升 27.0；没升依赖，所以本会话不需要 |

## 3. 没做的和原因

1. **Developer ID 签名、公证、staple、干净机器首启无拦截**：BLOCKED-账号（0 个签名身份）。脚本的 Team 路径（`-exportArchive` developer-id、`--options runtime --timestamp`、notarytool submit / staple、DMG 签名）按 Apple 文档写，
   在 ad-hoc 路径上验过除签名身份以外的每一步；第一次真签时按 docs/release/checklist-first-signed-run.md 过一遍，公证被拒的常见原因写在 docs/release/signing.md 末节。
2. **虚拟摄像头扩展激活**、**扩展的 'sonp' 四步**、**`consumeNext` 的 CPU**、**`VirtualCameraAppTests` 的 L1**、**扩展里那条 Sendable 警告**：BLOCKED-签名（prompt 第 10 条），全部落在清单里，没动 CameraExtension/Sources。
3. **Sparkle 从本地 appcast 更新成功一次**：BLOCKED-签名——Sparkle 装更新前校验新旧 App 的代码签名一致（Apple 签名的 DR），ad-hoc 每次构建 cdhash 都变，会拒装；appcast 生成、EdDSA 签名与 `sign_update --verify` 验签本机已过（R5），步骤写在 docs/release/sparkle.md §5。
4. **CI 真跑**：仓库没有 GitHub 远程、本机没装 runner（BLOCKED-账号 / 用户决定）；三个工作流 actionlint 零告警（R6），`ci-runner-setup.sh` 没在真 token 上跑过（下载 / config.sh / svc.sh 的参数按 GitHub 文档）。
   建了远程后：`make runner-install RUNNER_FLAGS="--url … --token …"`，第一次 push 就跑 l0-l1。nightly 在 W4-A 合入前第一步就红（故意的：说明目标不存在）。
5. **没升依赖**（swift-collections 留在 1.6.0）：升了 macOS 15 / 26 用户起不来；27 上不崩的结论靠运行时符号探针，没在 15 / 26 机器上验（本机已升 27，BLOCKED-机器）。
6. **正式 bundle id 没切**：域名只有用户能定（docs/release/bundle-id.md）；脚本备好，改动跨五个归属，建议检查点在用户定了之后跑一次。Stream Deck 插件 UUID 因此也没动（随 bundle id 一起）。
7. **通用二进制**：只出 arm64（`ARCHS=arm64`，"Apple Silicon 原生"）；要 Intel 得改 archive.sh 的 ARCHS 并处理 libndi（它本身是 universal）。
8. **崩溃上传 / 遥测 / 自己的符号化**：后续方案 §8.1 本期只做落盘 + 同意后导出；符号化用 xcarchive 里的 dSYM + atos，写在 docs/release/diagnostics.md。
9. **DMG 背景图 / 图标**：DMG 是素的（App + Applications 链接）；App 还没有图标（App/Resources 里没有 .icns），等有了再加 `--background` 与 Assets。
10. **`make test` 全量**没在本分支跑：本会话只跑了 ReleaseTests 与 LocalizationTests（全过）；六个包没动、App 只加了新文件与三处挂接，全量留给检查点（另一个会话 W4-A 正在本机跑 xctrace Leaks，同时跑全量会互相拖慢）。

## 4. 对契约的疑问 / 归属越界（请检查点复核）

契约（SwitcherContracts）没动。以下是 prompt 71 点名的交付落在 W4-B 归属行（scripts/release/、.github/、project.yml、App/Resources/、docs/release/、Tools/streamdeck-plugin/）之外的地方，
每处都是最小改动，`make lint` 的 check-ownership 会红，请在 docs/OWNERSHIP.md 的 W4-B 行补记（同 W3-E3 的 project.yml 先例）：

| 路径 | 改了什么 | 为什么非改不可 |
|---|---|---|
| Makefile | 末尾 `-include scripts/release/release.mk` + help 一行（3 行） | 交付 1 是 `make archive`，根 Makefile 不 include 就没有这个目标 |
| App/Info.plist | `SUFeedURL` / `SUPublicEDKey` 两键（值是 `$(SPARKLE_*)`） | Sparkle 只认 Info.plist 里的公钥；INFOPLIST_KEY_* 只支持固定白名单键 |
| App/Switcher-signed.entitlements | `device.camera` / `device.audio-input` | 公证要硬化运行时，硬化运行时下没有这两条摄像头 / 麦克风直接被拒 |
| App/Sources/Release/（4 个新文件）+ AppController / AppDelegate / PreferencesPanel 三处挂接 | 更新入口、崩溃诊断、诊断包 | 交付 2 的"更新检查 UI"、交付 3 整条只能在 App 里做；新目录 + 最小挂接，W3-E4（w3-app-5）同时在 App/ 上，冲突面只有 AppDelegate 的菜单段与 PreferencesPanel 的更新一节 |
| App/Tests/ReleaseTests.swift | R7–R10 | 铁律 2 先写测试 |
| CameraExtension/Resources/ | 两个 InfoPlist.strings | 交付 9 |
| THIRD_PARTY/NDI/、THIRD_PARTY/Sparkle/、THIRD_PARTY/README.md | 许可证 / 声明 / 两行表 | 交付 8 点名放 THIRD_PARTY/；README 原文说动态库归 W4-B 处理 |
| scripts/xcode-workspace-Package.resolved | 加 sparkle 一项 | 交付 6 点名"改模板" |

另外两条要用户拍板：
1. **bundle id 域名**（交付 7）：定了之后 `scripts/release/set-bundle-id.sh <前缀>` 一次改完（跨 App/、CameraExtension/、Packages/SwitcherOutputs、Tools/streamdeck-plugin、docs/integrations），建议检查点跑。
2. **Sparkle 更新源地址**（`SPARKLE_FEED_URL`）随远程仓库定：建议 `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`（release.yml 已按此上传 appcast.xml）。

## 5. 下一个会话需要知道的坑

1. **App 测试不能写成 `async`**：async 测试体在主队列的 dispatch 块里执行，`AppTest.pump` 的嵌套 run loop 在这种情况下不排空主队列（CoreFoundation 的 libdispatchQSafe 条件），
   引擎启动 / `newShow` 的 main actor 续体永远回不来，`runningSession` / `freshSession` 一律 15 s 超时 XCTSkip 且 lastError 为 nil——看起来像"引擎没起来"，其实是死锁。
   写法：同步 `func test…() throws`，异步调用放 `Task { @MainActor in … }` 再 `waitUntil` 轮询结果盒子（ReleaseTests.R7 就是范本）。这条值得写进 TestSupport 的注释（归 App）。
2. **`grep` 在 Claude 的 shell 里是 ugrep 7.8**（brew 装的，PATH 里盖住了 /usr/bin/grep）：`--exclude-dir` / `-rIl` 语义与 BSD grep 基本一致，但正则方言不同（ugrep 默认 ERE 风格更宽）；脚本里的 grep 都按两边都认的写法写，改脚本时在 Terminal.app（BSD grep）也跑一遍。
3. **xcodebuild 解析 Sparkle 二进制包会卡死**（本机 2026-09-27 一次：`-resolvePackageDependencies` 15 分钟 0% CPU，卡在 artifact 下载的 .lock 上）：`kill` 它、删 `$TMPDIR/…Sparkle_for_Swift_Package_Manager_zip.lock`，
   把发行包 zip（sha256 与 Package.swift 的 checksum 一致）放到 `~/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_sparkle_project_Sparkle_releases_download_2_10_0_Sparkle_for_Swift_Package_Manager_zip` 就能过。
4. **新加源文件后要 `make gen`**：XcodeGen 按生成时的文件列表建工程，加了 App/Sources/Release/*.swift 不重新 gen 就是 "cannot find type"。
5. **归档会重写 Switcher.xcodeproj**（`archive.sh` 调 `make gen`，DEVELOPMENT_TEAM 决定权限表）：正在开着 Xcode 的话先关；ad-hoc 与 Team 两种 gen 结果不同，切换后 `make build-app` 一次。
6. **硬化运行时 + 库校验**：有 Team ID 时包内每个 dylib / 框架都要同 Team 签名，否则 App 一起就 `Library not loaded`；ad-hoc 时 Xcode 自动关硬化运行时所以看不出来——第一次真签一定要跑 R1 的起动冒烟。
7. **`Packages/SwitcherControl/Package.resolved` 会被 xcodebuild 顺手写**（W3-E2 记过）：提交前 `git checkout` 它；`pin-deps.sh check` 会先红。
8. **W4-A 在本机同时跑 soak / xctrace 时不要跑 App 全量**（W4-A prompt 第 7 条反过来也成立）：S7 那条 missed_render 与显示类用例在机器忙时偶发红。
9. **verify.sh 的 spctl 在 ad-hoc 上一定 rejected**，脚本只记录不算失败；`--expect-notarized` 才把它当门槛。看 verify.json 的 `notarized` / `stapled` / `spctl_accepted` 三个布尔。
10. **`generate_appcast` 会在 `~/Library/Caches/Sparkle_generate_appcast` 缓存解包的 App**，同版本号重新打包后要清这个目录，否则 appcast 里的签名对的是旧包。
