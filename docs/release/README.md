# 发布工程（W4-B，prompt 71）

| 文档 | 内容 |
|---|---|
| signing.md | `make archive`：签名、公证、DMG、校验、干净机器验证、常见错误 |
| sparkle.md | 自动更新：集成、EdDSA 密钥（私钥不进仓库）、appcast、本地验证一次 |
| diagnostics.md | MetricKit 崩溃诊断落盘、诊断包一键导出（内容、去掉了什么） |
| ci.md | GitHub Actions self-hosted runner：三个工作流、装 runner、secrets |
| versioning.md | 版本号与变更日志规范；CHANGELOG-template.md、KNOWN_ISSUES-template.md 是 G5 用的模板 |
| dependencies.md | 依赖钉版本（swift-collections 1.6.0）与升级流程 |
| bundle-id.md | 正式 bundle id 已定 `com.plusmix.switcher`（用户 2026-09-28 定前缀 com.plusmix，G5 用 `set-bundle-id.sh` 切）；脚本一键切换（含 Stream Deck 插件 UUID） |
| third-party.md | 随包分发的 NDI 运行库、Sparkle 等的许可证与商标声明 |
| checklist-first-signed-run.md | 第一次带 Team ID 跑通时要验的清单（虚拟摄像头四步、扩展 CPU、L1、警告） |

## 快速上手

```bash
make archive-adhoc            # 没有账号：全流程走一遍（公证 BLOCKED-账号），产物 .build/release/<版本>/
make release-test             # scripts/release/tests/：R1–R6、R11–R14
DEVELOPMENT_TEAM=XXXXXXXXXX SPARKLE_FEED_URL=https://… SPARKLE_PUBLIC_ED_KEY=… make archive     # 正式
make release-verify TARGET=.build/release/0.1.0/PlusMix-0.1.0.dmg VERIFY_FLAGS=--expect-notarized
```

脚本都在 `scripts/release/`，每个文件头写用法；`scripts/release/release.mk` 是 make 入口（根 Makefile 末尾 include）。
产物名 = project.yml 里 App target 的 `PRODUCT_NAME`（PlusMix，W4-D 改名）：`PlusMix.xcarchive` / `PlusMix.app` / `PlusMix-<版本>.dmg`；scheme、工程、模块、bundle id 仍叫代码名 Switcher。

## 前置条件

| 要什么 | 干什么用 | 没有会怎样 |
|---|---|---|
| Xcode 26+、xcodegen | 归档 | 不能构建 |
| Apple Developer Program（Team ID + "Developer ID Application" 证书） | 签名、公证、虚拟摄像头扩展、Sparkle 的代码签名一致性 | 退成 ad-hoc：Gatekeeper 拦、扩展装不上、Sparkle 不能装更新 |
| notarytool 凭据（钥匙串 profile 或 App Store Connect API 密钥） | 公证 | 报告标 BLOCKED-账号 |
| NDI SDK（/Library/NDI SDK for Apple） | 链接 NDI、随包 libndi.dylib | 包不含 NDI，Stats 标 unavailable |
| Sparkle 密钥（钥匙串） | appcast 签名 | 不能出 appcast；App 里更新"未配置" |
| 网络 | 第一次解析 SwiftPM 包 | 解析失败 |

## 归属

本目录、`scripts/release/`、`.github/`、`project.yml`、`App/Resources/`、`Tools/streamdeck-plugin/`（只改 UUID）归 W4-B（docs/OWNERSHIP.md）。
W4-B 还动了：根 Makefile 两行 include、App/Info.plist 两个 Sparkle 键、App/Switcher-signed.entitlements 两条硬化运行时权限、App/Sources/Release/ 四个文件与三处挂接、
App/Tests/ReleaseTests.swift、CameraExtension/Resources/ 两个 InfoPlist.strings、THIRD_PARTY/NDI 与 Sparkle、scripts/xcode-workspace-Package.resolved 的 sparkle 一项——
都是 prompt 71 点名的交付，逐条列在 reports/w4-release.md §4 请求归属行补记。
W4-B2（prompt 83，分支 w4-release-2）收尾：R11 改读当前前缀、`scripts/check-links.sh` 把文档链接检查挂进 make lint、release.yml 产物名跟 PRODUCT_NAME、本目录跟 bundle id 裁定与改名。
