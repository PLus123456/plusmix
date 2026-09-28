# 正式 bundle id（prompt 71 第 7 条）——已定 com.plusmix.switcher

用户 2026-09-28 定前缀 **com.plusmix**（同时定产品名 PlusMix，改名见 W4-D / prompt 75）；G5 用 `scripts/release/set-bundle-id.sh com.plusmix` 一次切完（提交 62289ac）。
App、虚拟摄像头扩展与 Stream Deck 插件现在是同一个前缀，`scripts/release/set-bundle-id.sh --check` 报"两者一致"。

## 已定的值

| 处 | 值 | 在哪 |
|---|---|---|
| App | `com.plusmix.switcher`（project.yml `bundleIdPrefix: com.plusmix`） | project.yml |
| 虚拟摄像头扩展 | `com.plusmix.switcher.camera-extension`；mach service / app group `$(TeamIdentifierPrefix)com.plusmix.switcher.camera` | project.yml、CameraExtension/Info.plist、CameraExtension.entitlements、VirtualCameraConstants |
| 测试 | UserDefaults suite `com.plusmix.switcher.tests`（用例里再带后缀） | App/Sources/AppController.swift 与 App/Tests 里几个用例 |
| Stream Deck 插件 | UUID `com.plusmix.switcher`（+ `.cut` / `.auto` … 九个动作），目录 `com.plusmix.switcher.sdPlugin` | W3-D 起就是这个前缀（用仓库名反写），这次没动 |
| VMixCompat `reportedVersion` | 报本产品版本 | 不动（W3-D 报告 §4 第 4 条） |

bundle id 末段仍是代码名 `switcher`：W4-D 只改用户看得到的名字（产物 / 显示名 PlusMix），bundle id、模块、scheme 不动。

## 为什么定了就不再改

bundle id 不要求真拥有域名，但 Sparkle 更新源、公证记录、系统扩展的 mach service 名都跟着它走，**发布 0.1.0 之后就不能改**
（换 id = 另一个 App：旧用户收不到更新，扩展要重新激活，TCC 授权重来）。

## 切换脚本（G5 已跑过；留给以后 fork 或真要换时用）

```bash
scripts/release/set-bundle-id.sh --check           # 报 App 与 Stream Deck 两个前缀
scripts/release/set-bundle-id.sh --list            # 会改哪些文件（按内容搜，不是写死的）
scripts/release/set-bundle-id.sh <新前缀>           # 真改；--dry-run 先看
make gen build test                                # 扩展与 App 一起重编
cd Tools/streamdeck-plugin && npm test && npx streamdeck link <新前缀>.switcher.sdPlugin
```

脚本改的：project.yml（bundleIdPrefix、三个 PRODUCT_BUNDLE_IDENTIFIER、扩展 PRODUCT_NAME）、CameraExtension/Info.plist 与 entitlements（mach service / app group）、
CameraExtension/README.md、VirtualCameraConstants.swift（四个 UID + extensionBundleIdentifier + allowedClientSigningIDPrefix）、App 的测试 suite 名、
Stream Deck 插件（manifest.json 的十个 UUID、plugin.js 的前缀、package.json / README / test / scripts 里的命令与路径、目录改名）、docs/integrations/stream-deck.md。
它不动 reports/、docs/plan/、docs/release/（历史记录），也不动 Contracts014Tests 里作为例子的 `com.example`（不带 `.switcher` 后缀）。

改完要做的验证：`make release-test`（R11 只在副本上验脚本本身；当前前缀从 project.yml 的 bundleIdPrefix 与插件 manifest 的 UUID 读，切换前后都绿——W4-B2）、
App 起来、虚拟摄像头扩展重新激活（bundle id 变了就是另一个扩展，旧的要在系统设置里停用）、Stream Deck 重新 link。
这些改动跨 App/、CameraExtension/、Packages/SwitcherOutputs、Tools/streamdeck-plugin、docs/integrations 五个归属，所以由检查点跑脚本、一次提交（2026-09-28 G5 就是这么做的）。
