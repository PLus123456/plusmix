# 第一次带 Team ID 签名跑通时的验证清单（prompt 71 第 10 条；W4-B3 分成两段）

两种"第一次"：**开发签名**（钥匙串里有 Apple Development 身份就能做，Personal Team / 免费 Apple ID 也行——本机 2026-11-03 起就有）和 **Developer ID**（要 Apple Developer Program，仍 BLOCKED-账号）。
两者的区别（能做 / 不能做、TCC 为什么稳定、libndi 为什么要关库校验）见 signing.md"三种签名模式"与"权限表与硬化运行时"。

## 开发签名第一次（W4-B3）

前提：钥匙串里有 "Apple Development: …" 身份（`security find-identity -v -p codesigning`）；Team ID 用 `scripts/dev-signing/sign-mode.sh --dev-team` 读（证书名括号里那串不是）。

```bash
DEVELOPMENT_TEAM=<Team ID> make gen build-app   # 没有 Developer ID 身份时 make gen 自动选开发签名（打一行 "[sign-mode] 开发签名…"）；写明 SWITCHER_DEV_SIGN=1 也一样
make release-test                               # R17 真签一次（Team / runtime / 权限表 / 指定要求 / 起来 4 秒）；跑完工程回到 ad-hoc（R1），见最后一条
```

- [ ] `make gen` 那行是 `[sign-mode] 开发签名…`；`codesign -dvv .build/DerivedData/Build/Products/Debug/PlusMix.app` 有 `TeamIdentifier=<Team ID>`、`flags=0x10000(runtime)`、`Authority=Apple Development: …`；`codesign -d -r- <同一个 App>` 的指定要求里没有 `cdhash`。
- [ ] **授一次权**：在 Terminal.app 里 `open .build/DerivedData/Build/Products/Debug/PlusMix.app`（经 LaunchServices 起，TCC 记在 PlusMix 名下；直接跑 `Contents/MacOS/PlusMix` 时记在 Terminal 名下，测不出签名的作用；Claude 的 Bash 起的进程拿不到 TCC）：添加内置摄像头输入 → 允许、出画面；添加纯音频设备输入 → 允许、有电平；添加屏幕采集 → 系统设置里允许屏幕录制、按提示重开 App。
- [ ] **重编译不重问**：改一行 App 代码（或 `touch App/Sources/AppDelegate.swift`）→ `make build-app` → 再 `open` 起：三项都不再问、直接出画面 / 电平。对照：ad-hoc 构建同样操作会重问（指定要求是 cdhash）。另一个 worktree 用同一 Team 编出来的也应不重问（TCC 按 bundle id + 指定要求记、不看路径）——顺手验一次。
- [ ] **`make test-app` 的宿主也不重问**：从 Terminal.app `make test-app XCB_FLAGS=`——`InputWiringTests.testInputs_builtInCameraLiveWithin5sAndPictureShows` 不再因"BLOCKED-权限"跳过、不再弹授权框；用例数看日志末尾 `Executed N tests`。
- [ ] **libndi 在硬化运行时下能加载**：App 起来、添加 NDI 输入 / 开 NDI 输出不崩（开发表的 `cs.disable-library-validation`；没有它 dyld 当场拒，signing.md 上表）。
- [ ] **虚拟摄像头扩展装不上是预期**：输出 → 虚拟摄像头 → 安装 / 激活扩展 → 失败或要批准都记下来（Personal Team 没有 `system-extension.install`，BLOCKED-账号），别当新问题。
- [ ] `make release-test` / `make archive-adhoc` 之后工程是 ad-hoc 的：回来开发再 `DEVELOPMENT_TEAM=<Team ID> make gen`；只想临时编一次用别名 `make build-app DEV_SIGN_TEAM=<Team ID>`（不改工程里写的模式）。

## Developer ID 第一次（BLOCKED-账号；都 BLOCKED-签名 / 账号到这里）

前提：Apple Developer Program 账号；Team ID；钥匙串里有 "Developer ID Application" 证书；App 放到 /Applications 再起。

```bash
DEVELOPMENT_TEAM=<TeamID> make archive               # 拿签好的 .build/release/<版本>/PlusMix.app（archive.sh 钉 SWITCHER_DEV_SIGN=0 → App/Switcher-signed.entitlements，含 system-extension.install、camera、audio-input）
# 本机直接编：DEVELOPMENT_TEAM=<TeamID> make gen build-app（钥匙串里有该 Team 的 Developer ID 身份时 make gen 自动选 Developer ID 的设置）——
# 这条在 Personal Team 上停在 GatherProvisioningInputs（G13 §4.4）；付费账号第一次在这里验证，不行就加 -allowProvisioningUpdates，或本机清单改用上一段的开发签名
```

- [ ] **硬化运行时下摄像头 / 麦克风能用**：添加内置摄像头输入 → 出画面；纯音频设备输入 → 有电平。不行 = App/Switcher-signed.entitlements 少了 device.camera / device.audio-input（W4-B 加的两条）。
- [ ] **libndi 在库校验下能加载**：App 起来、NDI 输出能起（Stats 不是 unavailable）。起不来 = libndi.dylib 没用同一 Team 重签（archive.sh 的 sign.sh 那步）。
- [ ] **虚拟摄像头扩展**：输出 → 虚拟摄像头 → 安装 / 激活扩展 → 系统设置允许 → FaceTime / QuickTime 里选 "PlusMix" 出画面（设备名 = VirtualCameraConstants.deviceName，改名合入后 G5 改成了产品名）。
      系统设置 → 登录项与扩展 → 摄像头扩展里显示名中文系统 "PlusMix 虚拟摄像头"、英文 "PlusMix Virtual Camera"（W4-B 的 InfoPlist.strings，W4-D 改成产品名）。
- [ ] **扩展回报 'sonp' 的四步**（issue W3C2-camera-extension-scheduled-output 末节；`session.aux.virtualCamera?.countersSnapshot`）：
      1. `extensionReports == true`；2. `framesOutput` 跟着 `framesSent` 涨（不涨 = CMIO 桥没转发 notify → 换扩展自定义属性回报）；
      3. `extensionUnmatched == 0`（在涨 = 桥改了 / 丢了序号）；4. `droppedExtension` 平时 0，扩展里临时每 10 帧不 send 不 notify 时每秒涨 6。
- [ ] **`consumeNext` 递归取帧的 CPU**（reports/w3-outputs-4.md §3 第 6 条）：活动监视器看 `com.plusmix.switcher.camera-extension` 进程，sink 没帧时不该空转（> 5% 就是在空转，改成等到有帧再回）。
- [ ] **App `VirtualCameraAppTests` 的 L1**：`xcodebuild test -only-testing:SwitcherTests/VirtualCameraAppTests`，ad-hoc 下 XCTSkip 的那些要真跑。
- [ ] **扩展里那条 Swift 6 非 Sendable 捕获警告顺手清**（CameraExtension/Sources/CameraExtensionProvider.swift 的 `consumeNext` 递归捕获 `CMIOExtensionClient`，w3-outputs-4 §3 第 5 条）——归 CameraExtension/，改完跑扩展的激活与四步。
- [ ] **公证与 Gatekeeper**：`make archive`（带 notarytool 凭据，docs/release/signing.md）→ `verify.json` 里 `notarized: true`、`stapled: true`、`spctl_accepted: true`；
      新建 macOS 用户账户装 `PlusMix-<版本>.dmg` 首次启动无拦截——DMG 要带隔离属性（从 Release 草稿下载或 AirDrop；本机直接拷过去的不带，Gatekeeper 不查，
      等于没验，见 signing.md "Gatekeeper 与干净机器验证"）。
- [ ] **Sparkle 从本地 appcast 更新成功一次**（docs/release/sparkle.md §5）：两个构建号、本地 HTTP 服务、`SWITCHER_APPCAST_URL` 指过去 → 检查更新 → 安装 → 重启后是新版本。
- [ ] **升依赖时**（docs/release/dependencies.md）：macOS 15 / 26 各起一次 App 与 frameprobe；swift-collections 1.7.0 在 27 上不崩（W4-B 已验运行时符号在），15 / 26 上崩。

做完把数字填进 reports/G5.md（或当次的会话报告），BLOCKED 项解除。
