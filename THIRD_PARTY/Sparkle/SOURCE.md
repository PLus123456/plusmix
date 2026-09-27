# 来源

- 库：Sparkle 2（自动更新框架），MIT 许可证（本目录 LICENSE 是发行包里的原文）。
- 版本：2.10.0（project.yml `packages.Sparkle.exactVersion`；scripts/xcode-workspace-Package.resolved 钉 tag 2.10.0 = eef1a539）。
- 获取：SwiftPM 二进制 target，https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip
  （sha256 17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959，Package.swift 里的 checksum 一致）。
- 用法：Xcode 把 Sparkle.framework 嵌进 `Switcher.app/Contents/Frameworks/`，scripts/release/sign.sh 用本产品身份重签框架内的 XPC / Autoupdate / Updater.app；
  命令行工具（generate_keys / sign_update / generate_appcast）在解析出的包里，scripts/release/sparkle-bin.sh 找它们。LICENSE 随包放
  `Contents/Resources/Licenses/Sparkle/`。升级：scripts/release/pin-deps.sh upgrade sparkle <版本> <提交> + 改 project.yml 的 exactVersion。
