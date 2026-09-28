# 正式 bundle id（prompt 71 第 7 条）——等用户定域名

## 现状

| 处 | 现在 | 备注 |
|---|---|---|
| App | `com.example.switcher`（project.yml `bundleIdPrefix: com.example`） | 占位，P0 起 |
| 虚拟摄像头扩展 | `com.example.switcher.camera-extension`；mach service / app group `$(TeamIdentifierPrefix)com.example.switcher.camera` | CameraExtension/Info.plist、CameraExtension.entitlements、VirtualCameraConstants |
| 测试 | UserDefaults suite `com.example.switcher.tests` | App/Sources/AppController.swift 与三个测试文件 |
| Stream Deck 插件 | UUID `com.plusmix.switcher`（+ `.cut` / `.auto` … 九个动作），目录 `com.plusmix.switcher.sdPlugin` | W3-D 用仓库名反写；用户 2026-09-22 定随 bundle id 一起换 |
| VMixCompat `reportedVersion` | 报本产品版本 | 不动（W3-D 报告 §4 第 4 条） |

两边前缀现在不一致（`scripts/release/set-bundle-id.sh --check` 会提示）。

## 决定项（用户）

反写域名前缀，例如 `com.plusmix` 或 `io.github.plus123456`。bundle id 不要求真拥有域名，但 Sparkle 更新源、公证记录、系统扩展的 mach service 名
都跟着它走，**发布 0.1.0 之后就不能改**（换 id = 另一个 App：旧用户收不到更新，扩展要重新激活，TCC 授权重来）。

## 定下来之后（一次性）

```bash
scripts/release/set-bundle-id.sh --list            # 会改哪些文件（按内容搜，不是写死的）
scripts/release/set-bundle-id.sh com.plusmix       # 真改；--dry-run 先看
make gen build test                                # 扩展与 App 一起重编
cd Tools/streamdeck-plugin && npm test && npx streamdeck link com.plusmix.switcher.sdPlugin
```

脚本改的：project.yml（bundleIdPrefix、三个 PRODUCT_BUNDLE_IDENTIFIER、扩展 PRODUCT_NAME）、CameraExtension/Info.plist 与 entitlements（mach service / app group）、
CameraExtension/README.md、VirtualCameraConstants.swift（四个 UID + extensionBundleIdentifier + allowedClientSigningIDPrefix）、App 的测试 suite 名、
Stream Deck 插件（manifest.json 的十个 UUID、plugin.js 的前缀、package.json / README / test / scripts 里的命令与路径、目录改名）、docs/integrations/stream-deck.md。
它不动 reports/、docs/plan/、docs/release/（历史记录），也不动 Contracts014Tests 里作为例子的 `com.example`（不带 `.switcher` 后缀）。

改完要做的验证：`make release-test`（R11 只在副本上验脚本本身）、App 起来、虚拟摄像头扩展重新激活（bundle id 变了就是另一个扩展，旧的要在系统设置里停用）、
Stream Deck 重新 link。这些改动跨 App/、CameraExtension/、Packages/SwitcherOutputs、Tools/streamdeck-plugin、docs/integrations 五个归属，
所以由检查点（G5）在用户定了域名后跑脚本、一次提交。
