# 签名、公证、DMG（prompt 71 交付 1）

## 一条命令

```bash
DEVELOPMENT_TEAM=XXXXXXXXXX make archive          # Developer ID：archive → export → 随包 libndi → 重签 → 校验 → DMG → 公证 App 与 DMG 并 staple → 终校验
make archive-adhoc                                # 没有账号时：同样的步骤，ad-hoc 签名，公证一行标 BLOCKED-账号
make release-verify TARGET=.build/release/0.1.0/Switcher-0.1.0.dmg VERIFY_FLAGS=--expect-notarized
```

产物在 `.build/release/<版本>/`：`Switcher.xcarchive`（含 dSYM，留着符号化崩溃）、`Switcher.app`、`Switcher-<版本>.dmg` + `.sha256`、`verify.json`、`release-report.md`、`logs/`。

## 步骤与脚本（scripts/release/）

| 步 | 脚本 | 要点 |
|---|---|---|
| 钉版本 | `pin-deps.sh check` | 不一致直接停：发布构建必须用钉住的解析结果（docs/release/dependencies.md） |
| 生成工程 | `make gen`（DEVELOPMENT_TEAM 决定权限表：空 → App/Switcher.entitlements；Team ID → App/Switcher-signed.entitlements） | 会重写 Switcher.xcodeproj（生成物） |
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

| | ad-hoc（无 Team ID） | Developer ID |
|---|---|---|
| App 权限表 | `App/Switcher.entitlements`（空） | `App/Switcher-signed.entitlements`：`system-extension.install`（受限，靠描述文件）、`device.camera`、`device.audio-input`（硬化运行时下访问摄像头 / 麦克风必须） |
| 硬化运行时 | project.yml 开着，Xcode 对 ad-hoc 自动关（构建日志 note） | 开（公证要求）；库校验要求包内 dylib / 框架同一 Team 签名 → sign.sh 重签 libndi 与 Sparkle |
| 扩展 | 编得出、签 ad-hoc，装不上（BLOCKED-签名） | `CameraExtension/CameraExtension.entitlements`（沙盒 + app group `$(TeamIdentifierPrefix)<bundle id>.camera`） |

## Gatekeeper 与干净机器验证（人工）

1. 另建一个 macOS 用户账户（没装过本 App、没给过 TCC）。
2. 拷 DMG 过去，双击、拖到 /Applications、首次启动：正式版应无任何拦截；ad-hoc 版会被拦（"无法验证开发者"），右键 → 打开也能起——这是预期，记进报告即可。
3. 输出 → 虚拟摄像头 → 安装 / 激活扩展 → 系统设置允许 → FaceTime 里选 "Switcher"。
4. 偏好设置 → 更新 → 检查更新…（docs/release/sparkle.md §5 的本地 appcast）。
5. 帮助 → 导出诊断包… 出一份，打开看没有密钥。

## 常见错误

- `errSecInternalComponent` / "no identity found"：钥匙串锁着或身份不在登录钥匙串；CI 用 `ci-keychain.sh`。
- 公证被拒 "The signature of the binary is invalid" / "not signed with a valid Developer ID"：包里有哪个可执行没重签（看 `notarytool log`），sign.sh 的顺序覆盖了 Frameworks / SystemExtensions / PlugIns，新加目录要补。
- "The executable does not have the hardened runtime enabled"：archive 没带 Release 配置或 project.yml 的 ENABLE_HARDENED_RUNTIME 被覆盖。
- 起来就崩 `Library not loaded: @rpath/libndi.dylib`：随包那步没跑（打包机没装 SDK 却链接了它——不可能，Package.swift 探测的是同一台机器）。
- 摄像头黑屏、`TCC` 拒绝：硬化运行时下少了 `device.camera` 权限（本文上表）。
