#!/bin/bash
# R14：版本号与变更日志工具（prompt 71 交付 5）：bump-version.sh 在副本上同时改 project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION、
#      Version.swift 的 SwitcherVersion.current、CHANGELOG 的"未发布"标题；changelog.sh 能抽出某版本的小节；模板文件齐全。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
assert_file "$REPO_ROOT/docs/release/CHANGELOG-template.md" "CHANGELOG 模板"
assert_file "$REPO_ROOT/docs/release/KNOWN_ISSUES-template.md" "KNOWN_ISSUES 模板"
assert_file "$REPO_ROOT/docs/release/versioning.md" "版本号与变更日志规范"
scratch=$(mktemp -d "$RELEASE_TEST_OUT/r14.XXXX")
mkdir -p "$scratch/Packages/SwitcherCore/Sources/SwitcherContracts"
cp "$REPO_ROOT/project.yml" "$scratch/"
cp "$REPO_ROOT/Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift" "$scratch/Packages/SwitcherCore/Sources/SwitcherContracts/"
cp "$REPO_ROOT/docs/release/CHANGELOG-template.md" "$scratch/CHANGELOG.md"
assert_true "bump-version.sh 0.2.0 --build 7 在副本上成功" "$REPO_ROOT/scripts/release/bump-version.sh" 0.2.0 --build 7 --root "$scratch"
assert_contains "$(cat "$scratch/project.yml")" 'MARKETING_VERSION: "0.2.0"' "project.yml MARKETING_VERSION"
assert_contains "$(cat "$scratch/project.yml")" 'CURRENT_PROJECT_VERSION: "7"' "project.yml CURRENT_PROJECT_VERSION"
assert_contains "$(cat "$scratch/Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift")" 'current = "0.2.0"' "Version.swift"
assert_contains "$(cat "$scratch/CHANGELOG.md")" "## 0.2.0 " "CHANGELOG 的未发布小节变成 0.2.0 + 日期"
assert_contains "$(cat "$scratch/CHANGELOG.md")" "## 未发布" "CHANGELOG 顶上补了新的未发布小节"
sec=$("$REPO_ROOT/scripts/release/changelog.sh" 0.2.0 --file "$scratch/CHANGELOG.md")
[ -n "$sec" ] && ok "changelog.sh 抽出了 0.2.0 小节" || fail "changelog.sh 抽不出 0.2.0"
assert_not_contains "$sec" "## 未发布" "抽出的小节不含别的小节"
assert_false "bump-version.sh 拒绝不合法的版本号" "$REPO_ROOT/scripts/release/bump-version.sh" v1 --root "$scratch"
assert_false "bump-version.sh 拒绝倒退的版本号" "$REPO_ROOT/scripts/release/bump-version.sh" 0.1.0 --root "$scratch"
rm -rf "$scratch"
# 仓库本体的两处版本号一致（lint 也查；这里保证工具没碰它们）
assert_true "仓库本体没动" git -C "$REPO_ROOT" diff --quiet -- project.yml Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift
finish
