# 版本号与变更日志规范（prompt 71 交付 5）

## 版本号

- 语义化版本 `X.Y.Z`：X 有不兼容的节目文件 / API 变化（schemaVersion 升、Show 迁移）；Y 新功能；Z 只修 bug。预发布 `X.Y.Z-beta.1`（Sparkle 按 `sparkle:version` 比大小，不看后缀）。
- **只写在两处**：`project.yml` 的 `MARKETING_VERSION` 和 `Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift` 的 `SwitcherVersion.current`；`make lint` 校验一致。
  App 的 Info.plist 与扩展的 Info.plist 都用 `$(MARKETING_VERSION)`；headless / frameprobe 打印 `SwitcherVersion.current`；API 的 `/version` 与 VMixCompat 的 `reportedVersion` 也是它。
- 构建号 `CURRENT_PROJECT_VERSION`（project.yml）：整数、单调递增、每次改版本号至少 +1；Sparkle 用它当 `sparkle:version` 判新旧（`CFBundleVersion`），
  两个不同的发布不许同一个构建号。
- 改版本号归 G5（docs/OWNERSHIP.md）：`scripts/release/bump-version.sh X.Y.Z [--build N]` 一次改三处 + CHANGELOG；拒绝倒退与不合法格式。
- git tag `vX.Y.Z` 只在 G5 判定全部发布门槛通过后打（prompt 80）；`.github/workflows/release.yml` 校验 tag 与 `MARKETING_VERSION` 一致。

## 变更日志（CHANGELOG.md，仓库根；G5 从 docs/release/CHANGELOG-template.md 建）

- 顶上永远有 `## 未发布`；每个版本 `## X.Y.Z — YYYY-MM-DD`。
- 小节内四类：`### 新增` / `### 变更` / `### 修复` / `### 已知问题`，空类写 `（无）`。
- 每条写用户看得到的行为，动词开头，一行一条；涉及测试标准的指标就带 ID（"修复 V6：Cut 晚一拍"）；内部重构不写。
- 已知问题只放摘要，全表在 docs/KNOWN_ISSUES.md（模板 docs/release/KNOWN_ISSUES-template.md），发布说明里两者都要列（测试标准 §6 第 5 条）。
- `scripts/release/changelog.sh X.Y.Z` 抽出一个小节：GitHub Release 的说明和 Sparkle 的更新说明（`appcast.sh` 把同名 .md 嵌进 appcast）都用它。

## 发布一次的顺序

1. G5 判定：L0–L2 全过、L3 无 S0 / S1、L4 8 小时过、L5 无退步、KNOWN_ISSUES 更新（prompt 80）。
2. `scripts/release/bump-version.sh X.Y.Z` → 看 diff → 提交"发布 X.Y.Z"。
3. `git tag vX.Y.Z` → push tag → release.yml 出 DMG + appcast + 草稿 Release；或本机 `DEVELOPMENT_TEAM=… make archive` + `make appcast DIR=.build/release/X.Y.Z APPCAST_FLAGS="--download-url-prefix …"`。
4. 干净机器验证（docs/release/README.md §4）→ 发布草稿 → 把 appcast.xml 放到 `SUFeedURL` 指的地址。
5. 提交里把 `## 未发布` 留空的新小节带上（bump-version 已经加好）。
