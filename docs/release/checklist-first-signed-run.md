# 第一次带 Team ID 签名跑通时的验证清单（prompt 71 第 10 条；都 BLOCKED-签名 / 账号到这里）

前提：Apple Developer Program 账号；Team ID；钥匙串里有 "Developer ID Application" 证书；App 放到 /Applications 再起。

```bash
DEVELOPMENT_TEAM=<TeamID> make gen build-app         # 权限表自动换成 App/Switcher-signed.entitlements（含 system-extension.install、camera、audio-input）
# 或直接 DEVELOPMENT_TEAM=<TeamID> make archive 拿签好的 .build/release/<版本>/PlusMix.app
```

- [ ] **硬化运行时下摄像头 / 麦克风能用**：添加内置摄像头输入 → 出画面；纯音频设备输入 → 有电平。不行 = App/Switcher-signed.entitlements 少了 device.camera / device.audio-input（W4-B 加的两条）。
- [ ] **libndi 在库校验下能加载**：App 起来、NDI 输出能起（Stats 不是 unavailable）。起不来 = libndi.dylib 没用同一 Team 重签（archive.sh 的 sign.sh 那步）。
- [ ] **虚拟摄像头扩展**：输出 → 虚拟摄像头 → 安装 / 激活扩展 → 系统设置允许 → FaceTime / QuickTime 里选 "Switcher" 出画面（0.1.0 里摄像头设备名仍是代码名，VirtualCameraConstants.deviceName 归 W3-C）。
      系统设置 → 登录项与扩展 → 摄像头扩展里显示名中文系统 "PlusMix 虚拟摄像头"、英文 "PlusMix Virtual Camera"（W4-B 的 InfoPlist.strings，W4-D 改成产品名）。
- [ ] **扩展回报 'sonp' 的四步**（issue W3C2-camera-extension-scheduled-output 末节；`session.aux.virtualCamera?.countersSnapshot`）：
      1. `extensionReports == true`；2. `framesOutput` 跟着 `framesSent` 涨（不涨 = CMIO 桥没转发 notify → 换扩展自定义属性回报）；
      3. `extensionUnmatched == 0`（在涨 = 桥改了 / 丢了序号）；4. `droppedExtension` 平时 0，扩展里临时每 10 帧不 send 不 notify 时每秒涨 6。
- [ ] **`consumeNext` 递归取帧的 CPU**（reports/w3-outputs-4.md §3 第 6 条）：活动监视器看 `com.<域名>.switcher.camera-extension` 进程，sink 没帧时不该空转（> 5% 就是在空转，改成等到有帧再回）。
- [ ] **App `VirtualCameraAppTests` 的 L1**：`xcodebuild test -only-testing:SwitcherTests/VirtualCameraAppTests`，ad-hoc 下 XCTSkip 的那些要真跑。
- [ ] **扩展里那条 Swift 6 非 Sendable 捕获警告顺手清**（CameraExtension/Sources/CameraExtensionProvider.swift 的 `consumeNext` 递归捕获 `CMIOExtensionClient`，w3-outputs-4 §3 第 5 条）——归 CameraExtension/，改完跑扩展的激活与四步。
- [ ] **公证与 Gatekeeper**：`make archive`（带 notarytool 凭据，docs/release/signing.md）→ `verify.json` 里 `notarized: true`、`stapled: true`、`spctl_accepted: true`；
      新建 macOS 用户账户装 DMG 首次启动无拦截。
- [ ] **Sparkle 从本地 appcast 更新成功一次**（docs/release/sparkle.md §5）：两个构建号、本地 HTTP 服务、`SWITCHER_APPCAST_URL` 指过去 → 检查更新 → 安装 → 重启后是新版本。
- [ ] **升依赖时**（docs/release/dependencies.md）：macOS 15 / 26 各起一次 App 与 frameprobe；swift-collections 1.7.0 在 27 上不崩（W4-B 已验运行时符号在），15 / 26 上崩。

做完把数字填进 reports/G5.md（或当次的会话报告），BLOCKED 项解除。
