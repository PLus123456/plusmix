## 75 W4-D 产品改名 PlusMix（用户 2026-09-28 定：产品名 PlusMix，bundle id 前缀 com.plusmix；G5 已把 bundle id 切成 com.plusmix.switcher）
分支：w4-rename（从 W2-A3 合入后的 main 开）。只准动：App/Resources/、App/Info.plist、App/Sources/（只改写死的 "Switcher" 显示字符串）、project.yml、CameraExtension/Resources/、CameraExtension/Info.plist、docs/（spec/ 与 plan/ 除外）、README.md、Samples/README.md、Tools/streamdeck-plugin/（只改显示名）、scripts/release/（产物名）。
先读：docs/release/bundle-id.md、docs/release/signing.md、reports/G5.md §7 第 3 条、设计方案 §1.1 用词。

原则：**只改用户看得到的名字**。代码名 Switcher（模块名、target、SwitcherVersion、switcher-headless / frameprobe 命令名、Package 名、Stats 字段）一律不动，不改契约、不做全仓库替换；bundle id 已是 com.plusmix.switcher，不再动（发布后不能改）。docs/spec 与 docs/plan 是历史文档，不改。

交付：
1. App：CFBundleDisplayName / PRODUCT_NAME → PlusMix（.app 变成 PlusMix.app；scripts/release/ 里 archive.sh / verify.sh / dmg.sh / tests 写死 Switcher.app 的地方跟改，DMG 名 PlusMix-<版本>.dmg）；两种语言 Localizable.strings 里出现 "Switcher" 的界面文案（窗口标题、关于、菜单、外部输出窗口标题、诊断包 README、更新说明）→ PlusMix；InfoPlist 的用途说明同改。
2. 虚拟摄像头扩展显示名 "PlusMix 虚拟摄像头" / "PlusMix Virtual Camera"（CameraExtension/Resources 两份 InfoPlist.strings）；App 侧 NDI 发送等默认名字里的 "Switcher" 改 PlusMix（包内默认值不动）。
3. Stream Deck 插件 manifest 的 Name / 描述显示名（UUID 不动）；docs/integrations、docs/user、docs/api、docs/testing、README、Samples/README 里的产品名改 PlusMix，保留一句"代号 / 代码名 Switcher"说明。
4. lint 禁词表不变；LocalizationTests / ReleaseTests / R1 / R12 / check-links 全绿；`make gen build test`、`make archive-adhoc` 出 PlusMix.app 与 PlusMix-0.1.0.dmg。

测试：App 全量 `make test-app`、`make release-test`、`python3 docs/tools/check-links.py`。报告 reports/w4-rename.md（五段）。不 push、不 merge。
