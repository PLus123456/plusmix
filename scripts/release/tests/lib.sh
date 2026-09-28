#!/bin/bash
# 发布工程脚本的测试公共库（scripts/release/tests/test-*.sh 都 source 它）。
# 约定：每个测试脚本自己 set -uo pipefail；断言失败调 fail（累计，最后 finish 退出 1）；测不了调 skip "BLOCKED-xxx：…"（退出 77，run.sh 记 SKIP）。
# 环境：RELEASE_TEST_OUT（run.sh 给，默认 .build/release-tests）；RELEASE_TEST_APP（R1 产出的 <产品名>.app，后面的测试复用，不重编）。
# 产物名（W4-D，用户 2026-09-28 定名 PlusMix）：.app / .xcarchive / DMG 都叫 project.yml 里 App target 的 PRODUCT_NAME（product_name），
# 可执行名从包的 CFBundleExecutable 读（app_executable）；scheme / target / 模块仍叫代码名 Switcher。
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RELEASE_TEST_OUT=${RELEASE_TEST_OUT:-$REPO_ROOT/.build/release-tests}
mkdir -p "$RELEASE_TEST_OUT"
_failures=0
_checks=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

ok()   { _checks=$((_checks + 1)); green "  ok   $*"; }
fail() { _checks=$((_checks + 1)); _failures=$((_failures + 1)); red "  FAIL $*"; }
skip() { yellow "  SKIP $*"; exit 77; }
note() { printf '  ·    %s\n' "$*"; }

# assert_true <说明> <命令...>：命令退出 0 就 ok
assert_true() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else fail "$msg（命令：$*）"; fi; }
# assert_false <说明> <命令...>：命令退出非 0 就 ok
assert_false() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then fail "$msg（命令本该失败：$*）"; else ok "$msg"; fi; }
assert_file() { if [ -e "$1" ]; then ok "存在：${2:-$1}"; else fail "缺文件：${2:-$1}"; fi; }
assert_no_file() { if [ -e "$1" ]; then fail "不该存在：${2:-$1}"; else ok "不存在：${2:-$1}"; fi; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3 = $1"; else fail "$3：期望 [$2]，实际 [$1]"; fi; }
# 用 here-string 喂 grep、不走管道：bash 3.2 的 printf 内建往管道按行写，grep -q 命中就退出，printf 吃 SIGPIPE，pipefail 下整条管道 141
# ——assert_contains 误报"找不到"、assert_not_contains 误报通过（W4-B2 探针；R6 开头有回归）
assert_contains() { if grep -q -- "$2" <<< "$1"; then ok "$3"; else fail "$3（找不到 [$2]）"; fi; }
assert_not_contains() { if grep -q -- "$2" <<< "$1"; then fail "$3（不该出现 [$2]）"; else ok "$3"; fi; }

finish() {
  if [ "$_failures" = 0 ]; then green "通过：$_checks 项断言"; exit 0; fi
  red "失败：$_failures / $_checks 项断言"; exit 1
}

# 复用 R1 的产物（没有就自己跑一次 ad-hoc 归档）。
require_archived_app() {
  if [ -n "${RELEASE_TEST_APP:-}" ] && [ -d "$RELEASE_TEST_APP" ]; then return 0; fi
  local dir="$RELEASE_TEST_OUT/r1"
  if [ -d "$dir" ] && ls -d "$dir"/*/*.app >/dev/null 2>&1; then
    RELEASE_TEST_APP=$(ls -d "$dir"/*/*.app | head -1); export RELEASE_TEST_APP; return 0
  fi
  note "没有 R1 的产物，先跑一次 ad-hoc 归档（几分钟）"
  "$REPO_ROOT/scripts/release/archive.sh" --adhoc --skip-notarize --out "$dir" >"$RELEASE_TEST_OUT/r1-archive.log" 2>&1 || { fail "ad-hoc 归档失败（$RELEASE_TEST_OUT/r1-archive.log）"; finish; }
  RELEASE_TEST_APP=$(ls -d "$dir"/*/*.app | head -1); export RELEASE_TEST_APP
}

marketing_version() { sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$REPO_ROOT/project.yml" | head -1; }
# App target 的 PRODUCT_NAME（project.yml 里第一个 PRODUCT_NAME；扩展的在后面、等于它的 bundle id）
product_name() { sed -n 's/^[[:space:]]*PRODUCT_NAME:[[:space:]]*"\{0,1\}\([A-Za-z0-9][A-Za-z0-9._-]*\)"\{0,1\}.*/\1/p' "$REPO_ROOT/project.yml" | head -1; }
# 一个 .app 的可执行名（Contents/MacOS/ 下那个文件）
app_executable() { /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null; }
