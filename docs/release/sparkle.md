# Sparkle 自动更新（prompt 71 交付 2）

## 集成（已做）

- project.yml：`packages.Sparkle`（SwiftPM 二进制，`exactVersion: 2.10.0`）+ App 依赖 `package: Sparkle`；Xcode 把 `Sparkle.framework` 嵌进 `Contents/Frameworks/`，`sign.sh` 用本产品身份重签框架内的 XPC / Autoupdate / Updater.app。
- App/Info.plist：`SUFeedURL = $(SPARKLE_FEED_URL)`、`SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)`；project.yml 默认两者为空 = **这份构建不带更新**，`archive.sh` 用 xcodebuild 命令行设置注入真实值。
- `App/Sources/Release/UpdateController.swift`：两个键都有且不在测试宿主里才起 `SPUStandardUpdaterController`（Sparkle 自己的检查 / 下载 / 安装界面）；否则菜单 "检查更新…" 弹一句说明，偏好设置里写"未配置"。
  偏好设置 → 更新：自动检查开关（`automaticallyChecksForUpdates`，默认 Sparkle 在第二次启动时问用户）、检查更新、上次检查时间、导出诊断包。
- 更新包就是发布的 DMG（Sparkle 支持 dmg / zip / tar.xz），签名校验两道：appcast 里的 EdDSA 签名 + 新旧 App 的代码签名一致（Developer ID）。

## 密钥（EdDSA / ed25519）——私钥不进仓库

```bash
make sparkle-keys                                  # = scripts/release/sparkle-keys.sh generate：生成到登录钥匙串（服务 https://sparkle-project.org，账户 ed25519），打印公钥
scripts/release/sparkle-keys.sh public             # 只打印公钥（放进 CI 变量 SPARKLE_PUBLIC_ED_KEY / archive.sh 的环境变量）
scripts/release/sparkle-keys.sh export --to key.txt   # 导出私钥给 CI（内容进 secret SPARKLE_PRIVATE_KEY，然后删文件）
scripts/release/sparkle-keys.sh import key.txt     # 新打包机导入
```

- 一套密钥对应产品的全部版本：换私钥 = 老用户更新不了（Sparkle 用旧 App 里的公钥验新包）。私钥只在打包机钥匙串与 CI secret 里；丢了就只能靠代码签名一致性发一个带新公钥的版本。
- 公钥与更新源在构建时才进 Info.plist，所以本地 `make build-app` 出来的 App 不会去检查更新，也不会误连别人的 appcast。

## appcast

```bash
scripts/release/changelog.sh 0.1.0 > .build/release/0.1.0/Switcher-0.1.0.md      # 同名 .md = 该版本的更新说明
make appcast DIR=.build/release/0.1.0 APPCAST_FLAGS="--download-url-prefix https://github.com/<owner>/<repo>/releases/download/v0.1.0/ --embed-release-notes"
```

`appcast.sh` 调 Sparkle 发行包里的 `generate_appcast`（`sparkle-bin.sh` 在 `.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin` 找；`SPARKLE_BIN` 可指定），
出 `appcast.xml`：每项 `sparkle:version`（= CFBundleVersion 构建号，判新旧）、`sparkle:shortVersionString`、`sparkle:edSignature`、`length`、`sparkle:minimumSystemVersion`（从 App 的 LSMinimumSystemVersion 推）。
CI（release.yml）用 `--ed-key-file -` 从 secret 读私钥。

托管：`SUFeedURL` 用固定地址，例如 `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`（每次发布把 appcast.xml 作为 Release 资产上传，latest 自动指到最新）。
appcast 只需要含最新版本；用户跨多个版本升级也是直接装最新。

## 更新流程（用户侧）

1. 启动后 Sparkle 按 `SUScheduledCheckInterval`（默认一天）检查；或 App 菜单 / 偏好设置里"检查更新…"。
2. 有新版：Sparkle 弹窗（版本、更新说明）→ 下载 → 校验 EdDSA 与代码签名 → 退出 → 换包 → 重启。安装由 Sparkle 的 Installer.xpc / Autoupdate 做，App 不用管。
3. 失败的常见原因：appcast 的 `url` 打不开（前缀写错）、`edSignature` 是别的私钥签的、新包的 Team ID 与旧包不同。

## 本地 appcast 验证一次（prompt 71 测试段；第一次签名跑通时做，ad-hoc 下 Sparkle 会因代码签名不一致拒绝安装——BLOCKED-签名）

```bash
# 1. 老版本：当前版本号（例如 0.1.0 build 1）签名归档，装到 /Applications
DEVELOPMENT_TEAM=… SPARKLE_FEED_URL=http://127.0.0.1:8000/appcast.xml SPARKLE_PUBLIC_ED_KEY=$(scripts/release/sparkle-keys.sh public) make archive
cp -R .build/release/0.1.0/Switcher.app /Applications/
# 2. 新版本：临时把 project.yml 的 CURRENT_PROJECT_VERSION 改成 2（不提交），再归档一次，DMG 放到一个目录
sed -i '' 's/CURRENT_PROJECT_VERSION: "1"/CURRENT_PROJECT_VERSION: "2"/' project.yml && DEVELOPMENT_TEAM=… SPARKLE_FEED_URL=http://127.0.0.1:8000/appcast.xml SPARKLE_PUBLIC_ED_KEY=… make archive RELEASE_OUT=.build/release-next
mkdir -p /tmp/appcast && cp .build/release-next/0.1.0/Switcher-0.1.0.dmg /tmp/appcast/ && git checkout project.yml
# 3. appcast + 本地 HTTP
scripts/release/appcast.sh /tmp/appcast --download-url-prefix http://127.0.0.1:8000/
(cd /tmp/appcast && python3 -m http.server 8000) &
# 4. 老版本里 检查更新… → 应看到 build 2 → 安装 → 重启后 关于 里是 build 2
open /Applications/Switcher.app
```

也可以不重编老版本，用 `SWITCHER_APPCAST_URL=http://127.0.0.1:8000/appcast.xml open -a Switcher`（UpdateController 的覆盖，`updateFeedURLOverride` UserDefaults 键同效）。
