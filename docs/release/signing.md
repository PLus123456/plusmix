# 签名、公证、DMG（prompt 71 交付 1）

## 一条命令

```bash
DEVELOPMENT_TEAM=XXXXXXXXXX make archive          # Developer ID：archive → export → 随包 libndi → 重签 → 校验 → DMG → 公证 App 与 DMG 并 staple → 终校验
make archive-adhoc                                # 没有账号时：同样的步骤，ad-hoc 签名，公证一行标 BLOCKED-账号
make release-verify TARGET=.build/release/0.1.0/PlusMix-0.1.0.dmg VERIFY_FLAGS=--expect-notarized
```

产物在 `.build/release/<版本>/`：`PlusMix.xcarchive`（含 dSYM，留着符号化崩溃）、`PlusMix.app`、`PlusMix-<版本>.dmg` + `.sha256`（产物名 = project.yml 的 `PRODUCT_NAME`，W4-D）、`verify.json`、`release-report.md`、`logs/`。

## 三种签名模式（W4-B3，prompt 141）

`make gen` 时由两个环境变量定、写进工程（project.yml 设置段开头的注释；派生的构建设置 `SWITCHER_SIGN_MODE` = `adhoc` / `dev` / `devid`）：

| 模式 | 怎么选 | 签名方式 / 身份 | App 权限表 | 干什么用 |
|---|---|---|---|---|
| (a) ad-hoc | 不给 `DEVELOPMENT_TEAM`（默认） | Automatic / `-`（"Sign to Run Locally"） | `App/Switcher.entitlements`（空） | 没有 Apple 身份的机器；`make archive-adhoc` |
| (b) 开发签名 | `DEVELOPMENT_TEAM=<Team ID> SWITCHER_DEV_SIGN=1 make gen build-app`；Team 给了、`SWITCHER_DEV_SIGN` 没给时自动识别（下面） | Manual / `Apple Development`，不要描述文件 | `App/Switcher-dev.entitlements` | 本机编、跑、测：TCC 授权跨重编译不重问 |
| (c) Developer ID | `DEVELOPMENT_TEAM=<Team ID> make archive`（archive.sh 生成工程与 archive 都钉 `SWITCHER_DEV_SIGN=0`） | Automatic / `-`，archive 带 `-allowProvisioningUpdates`、导出 developer-id、sign.sh 用 Developer ID 重签 | `App/Switcher-signed.entitlements` | 发布（公证仍 BLOCKED-账号） |

- **自动识别**（`scripts/dev-signing/sign-mode.sh`，只读钥匙串、不碰私钥、不联网）：钥匙串里有该 Team 的 "Developer ID Application" 身份 → (c) 的设置（W4-B 原样）；没有、但有它的 "Apple Development" 身份 → (b)——Personal Team（免费 Apple ID）就是这样，(c) 那套设置在这种机器上根本签不出来（G13 §4.4：停在 GatherProvisioningInputs）；都没有 → (c) 的设置（原样，构建多半停在签名）。`make gen` 打一行 `[sign-mode] …` 说选了哪种、为什么；`SWITCHER_DEV_SIGN=1` 却没给 Team、或值不是 1 / 0 / 空，在这里就停。
- **Team ID** 是证书主题的 OU：`scripts/dev-signing/sign-mode.sh --dev-team`、或签过的东西 `codesign -dvv` 的 `TeamIdentifier`。**不是** "Apple Development: 邮箱 (XXXXXXXXXX)" 括号里那串（那是个人证书的编号）；给错了 `make gen` 会提示钥匙串里实际的 Team。
- **别名**：`make build-app DEV_SIGN_TEAM=<Team ID>`（`test-app` 同）不重新生成工程，在 xcodebuild 命令行上盖 `DEVELOPMENT_TEAM` + `SWITCHER_DEV_SIGN=1`——命令行优先级最高，工程里派生的签名方式 / 身份 / 权限表跟着变；下一次不给别名就回到工程里写的模式。G13 的 `-xcconfig` 旁路已删，权限表只有 App/ 下这三份。
- 写进工程的模式一直有效到下一次显式 `make gen`：project.yml 变了（比如 bump 版本号）`make build-app` / `test-app` 自动重新生成时，环境里两个签名变量都没给就沿用工程里原来写的 Team 与开关（打一行"沿用工程里原来的 …"），不会悄悄退回 ad-hoc。`make release-test`（R1 跑 `archive.sh --adhoc`）、`make archive-adhoc` 是显式生成 ad-hoc，之后回来开发再 `DEVELOPMENT_TEAM=<Team ID> make gen` 一次。
- **自检**：`make release-test` 的 R16（不要身份、CI 也跑：决策表、三种模式下三个 target 的设置、(a) / (c) 与 W4-B3 之前一致、生成的 TargetAttributes 不变）与 R17（真签一次：TeamIdentifier / runtime / 权限表 / 指定要求不含 cdhash / `codesign --verify --deep --strict` / 扩展与测试包同一 Team / 起来 4 秒；钥匙串里没有 Apple Development 身份、在 CI 上、钥匙串锁着都跳过并写明 BLOCKED-签名）。
- 实现上的一个坑：XcodeGen 把 `CODE_SIGN_STYLE` 原样抄进 TargetAttributes 的 `ProvisioningStyle`（宏也照抄），target 的 `attributes:` 盖不住（XcodeGen 2.46 后写的覆盖先写的）。所以 project.yml 写成无条件 `CODE_SIGN_STYLE: Automatic`（给 XcodeGen 抄）+ `CODE_SIGN_STYLE[sdk=macosx*]` 宏（同一层带条件的变体优先，构建时生效）。

## 步骤与脚本（scripts/release/）

| 步 | 脚本 | 要点 |
|---|---|---|
| 钉版本 | `pin-deps.sh check` | 不一致直接停：发布构建必须用钉住的解析结果（docs/release/dependencies.md） |
| 生成工程 | `DEVELOPMENT_TEAM=<Team 或空> SWITCHER_DEV_SIGN=0 make gen`（钉 0：发布归档永远不会被自动识别成开发签名；空 → ad-hoc 空表，Team ID → App/Switcher-signed.entitlements） | 会重写 Switcher.xcodeproj（生成物）：之后工程是 ad-hoc / Developer ID 的设置 |
| 归档 | `xcodebuild archive -configuration Release -destination generic/platform=macOS ARCHS=arm64 -onlyUsePackageVersionsFromResolvedFile SPARKLE_FEED_URL=… SPARKLE_PUBLIC_ED_KEY=…`，有 Team 加 `-allowProvisioningUpdates` | 只出 Apple Silicon；Sparkle 两个键从这里进 Info.plist |
| 导出 | Team：`-exportArchive` method `developer-id`（自动签名，嵌描述文件——`system-extension.install` 是受限权限，要它）；ad-hoc：直接拷 xcarchive 里的 App | |
| 随包 | `archive.sh`：`libndi.dylib` → `Contents/Frameworks/`，`libndi_licenses.txt` + NOTICE → `Contents/Resources/Licenses/NDI/`，`install_name_tool -delete_rpath` 删掉主二进制指向 SDK 目录的 LC_RPATH；所有 SwiftPM 依赖与 THIRD_PARTY 的许可证 → `Licenses/<名>/` | 主二进制链接的是 `@rpath/libndi.dylib`，`@executable_path/../Frameworks` 在 rpath 表最前 |
| 重签 | `sign.sh`：dylib → Sparkle 的 XPC / Autoupdate / Updater.app → 框架 → 系统扩展（保留沙盒 + app group 权限表）→ App（Team：`--options runtime --timestamp` + Switcher-signed.entitlements；ad-hoc：`-s -` + 空权限表） | 加了文件、改了二进制，外层封条必须重打；由内向外 |
| 校验 | `verify.sh --json` | 见下 |
| DMG | `dmg.sh`：App + Applications 链接，UDZO，Team 时给 DMG 签名，sha256 | |
| 公证 | `notarize.sh`：先 App（zip 提交，staple 到 App）再 DMG（staple 到 DMG）；`notarytool submit --wait`，失败拉 `notarytool log` | 凭据三选一（脚本头）：本机推荐 `xcrun notarytool store-credentials <名字>` + `NOTARY_KEYCHAIN_PROFILE`；CI 用 API 密钥 |
| 报告 | `release-report.md` | 每步一行 + verify.json + 干净机器清单 |

## verify.sh 查什么

`codesign --verify --deep --strict`（signature_valid）、身份 / Team / 硬化运行时标志、`spctl --assess --type execute -vv`（spctl_accepted；source 含 "Notarized Developer ID" 才算 notarized）、
`stapler validate`（stapled）、扩展存在且验得过且带 app-sandbox、两种语言的 InfoPlist.strings、链接了 libndi 就必须随包且没有 SDK rpath 且有许可证、Sparkle.framework 验得过、
SUFeedURL / SUPublicEDKey（都非空才 sparkle_configured）、架构、最低系统。DMG 还查 `hdiutil verify`、Applications 链接、DMG 自己的签名与 staple。
退出非 0：签名验不过、缺扩展、链接了 libndi 却没随包、缺 Sparkle、`--expect-notarized` 没满足。ad-hoc 下 spctl rejected 只记录（预期）。

## 权限表与硬化运行时

| | ad-hoc（无 Team ID） | 开发签名（Apple Development；Personal Team 也行） | Developer ID |
|---|---|---|---|
| App 权限表 | `App/Switcher.entitlements`（空） | `App/Switcher-dev.entitlements`：`device.camera`、`device.audio-input`、`cs.disable-library-validation`；**不带** `system-extension.install` | `App/Switcher-signed.entitlements`：`system-extension.install`（受限，靠描述文件）、`device.camera`、`device.audio-input`（硬化运行时下访问摄像头 / 麦克风必须） |
| 签名身份 | `-` | 钥匙串里的 "Apple Development: …"（Manual、不要描述文件；扩展、测试包同一身份） | "Developer ID Application: …"（sign.sh 由内向外重签、带时间戳） |
| 硬化运行时 | project.yml 开着，Xcode 对 ad-hoc 自动关（构建日志 note） | 开（`codesign -dvv` 的 flags 含 runtime），库校验也跟着开——所以要下面"libndi"那一行 | 开（公证要求）；库校验要求包内 dylib / 框架同一 Team 签名 → sign.sh 重签 libndi 与 Sparkle |
| TCC（摄像头 / 麦克风 / 屏幕录制） | **每次重编译都重问**：ad-hoc 的指定要求（designated requirement）就是 `cdhash H"…"`，CDHash 一变系统当新 App | **授一次、重编译不重问**：TCC 按指定要求记授权，开发签名的是 `identifier "com.plusmix.switcher" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and certificate 1[…] /* exists */`——只看 bundle id + 证书、不含 CDHash；`make test-app` 的测试宿主就是同一个 PlusMix.app、同一身份，也不重问 | 同开发签名（按 Developer ID 证书记）；从 /Applications 起 |
| libndi | 硬化运行时关着，库校验不查，直接从 SDK 目录加载 | 开发构建不随包重签：主程序从 `/Library/NDI SDK for Apple/lib/macOS/` 直接加载 NDI 自己 Team 签的 libndi，库校验开着时 dyld 当场拒（`mapping process and mapped file (non-platform) have different Team IDs`，G13 §4.4；W4-B3 去掉这条权限重签一份的反证：退出 134）→ 开发表关库校验 | 随包进 Contents/Frameworks、sign.sh 用同一 Team 重签，发布表**不**关库校验 |
| 扩展 | 编得出、签 ad-hoc，装不上（BLOCKED-签名） | 编得出、签成同一 Team（app group `<Team>.<bundle id>.camera`），**装不上**：App 没有 `system-extension.install`（受限权限要带 System Extension 能力的描述文件，Personal Team 拿不到，BLOCKED-账号） | `CameraExtension/CameraExtension.entitlements`（沙盒 + app group `$(TeamIdentifierPrefix)<bundle id>.camera`） |
| 能做 | 本机编、跑、测（每次重编译重授权） | 本机编、跑、测、跑 L3 清单：TCC 稳定、`make test-app` 宿主不重问；钥匙串里有身份就行，免费 Apple ID 也有 | 分发：公证、Gatekeeper 放行、Sparkle 正式更新、虚拟摄像头扩展 |
| 不能做 | 分发；虚拟摄像头扩展 | **分发**——不是 Developer ID：不能公证、`spctl --assess` rejected、别的机器上 Gatekeeper 拦、Sparkle 不能装更新；虚拟摄像头扩展；Personal Team 只能签不带受限权限的东西，证书一年一换（本机这张 2026-11-03 签发、2027-11-03 到期，到期在 Xcode › Settings › Accounts 重建，Team ID 不变、授权照旧） | — |

## Gatekeeper 与干净机器验证（人工）

1. 另建一个 macOS 用户账户（没装过本 App、没给过 TCC）。
2. 把 `PlusMix-<版本>.dmg` 按"下载"的方式拿过去：从 Release 草稿下载或 AirDrop（会带隔离属性 `com.apple.quarantine`）。在本机直接拷给另一个账户**不带**隔离属性，
   Gatekeeper 根本不查，测不出拦截——那样就先 `xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" PlusMix-<版本>.dmg` 再挂载。
   双击、拖到 /Applications、首次启动：正式版（公证 + staple）应无任何拦截；ad-hoc 版会被拦，弹窗只有"完成"和"移到废纸篓"。
   **macOS 15 起右键 → 打开不再能绕过**：点"完成"，到 系统设置 › 隐私与安全性，拉到底部"安全性"一栏，刚被拦的 PlusMix 旁边点"仍要打开"
   （尝试打开后大约一小时内才有这个按钮），按提示输登录密码或触控 ID 确认，之后就能正常起。这是预期，记进报告即可。
3. 输出 → 虚拟摄像头 → 安装 / 激活扩展 → 系统设置允许（扩展显示名 "PlusMix 虚拟摄像头" / "PlusMix Virtual Camera"）→ FaceTime 里选 "PlusMix"
   （摄像头设备名 = `VirtualCameraConstants.deviceName`，改名合入后 G5 改成了产品名）。
4. 设置 › 更新与诊断 → 检查更新…（docs/release/sparkle.md §5 的本地 appcast）。
5. 帮助 → 导出诊断包… 出一份，打开看没有密钥。

## 常见错误

- `errSecInternalComponent` / "no identity found"：钥匙串锁着或身份不在登录钥匙串；CI 用 `ci-keychain.sh`。
- 公证被拒 "The signature of the binary is invalid" / "not signed with a valid Developer ID"：包里有哪个可执行没重签（看 `notarytool log`），sign.sh 的顺序覆盖了 Frameworks / SystemExtensions / PlugIns，新加目录要补。
- "The executable does not have the hardened runtime enabled"：archive 没带 Release 配置或 project.yml 的 ENABLE_HARDENED_RUNTIME 被覆盖。
- 起来就崩 `Library not loaded: @rpath/libndi.dylib`：随包那步没跑（打包机没装 SDK 却链接了它——不可能，Package.swift 探测的是同一台机器）。
- 摄像头黑屏、`TCC` 拒绝：硬化运行时下少了 `device.camera` 权限（本文上表）。
- `"Switcher" has entitlements that require signing with a development certificate`（GatherProvisioningInputs）：工程按 (c) Developer ID 的设置生成（`CODE_SIGN_IDENTITY "-"` + 带受限权限的签名表）却在本机 `make build-app`——本机开发用开发签名：`DEVELOPMENT_TEAM=<Team ID> SWITCHER_DEV_SIGN=1 make gen`（G13 §4.4 撞到的就是这个）。
- 开发签名找不到身份：`No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "…" with a private key was found`——Team ID 给错（多半拿了证书名括号里那串；W4-B3 用 `DEV_SIGN_TEAM=34XFY3Q25G` 试出的就是这条）或钥匙串里没有这个 Team 的 Apple Development 身份：`scripts/dev-signing/sign-mode.sh --list` 列出钥匙串里能用的。
- 开发签名的 App / 测试宿主一起来就 abort，`Library not loaded: @rpath/libndi.dylib … different Team IDs`：权限表少了 `cs.disable-library-validation`（不是 `App/Switcher-dev.entitlements`，或被人删了那条）。
