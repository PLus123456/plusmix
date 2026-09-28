#!/bin/bash
# 发布工程脚本的测试公共库（scripts/release/tests/test-*.sh 都 source 它）。
# 约定：每个测试脚本自己 set -uo pipefail；断言失败调 fail（累计，最后 finish 退出 1）；测不了调 skip "BLOCKED-xxx：…"（退出 77，run.sh 记 SKIP）。
# 环境：RELEASE_TEST_OUT（run.sh 给，默认 .build/release-tests）；RELEASE_TEST_APP（R1 产出的 Switcher.app，后面的测试复用，不重编）。
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
assert_contains() { if printf '%s' "$1" | grep -q -- "$2"; then ok "$3"; else fail "$3（找不到 [$2]）"; fi; }
assert_not_contains() { if printf '%s' "$1" | grep -q -- "$2"; then fail "$3（不该出现 [$2]）"; else ok "$3"; fi; }

finish() {
  if [ "$_failures" = 0 ]; then green "通过：$_checks 项断言"; exit 0; fi
  red "失败：$_failures / $_checks 项断言"; exit 1
}

# 复用 R1 的产物（没有就自己跑一次 ad-hoc 归档）。
require_archived_app() {
  if [ -n "${RELEASE_TEST_APP:-}" ] && [ -d "$RELEASE_TEST_APP" ]; then return 0; fi
  local dir="$RELEASE_TEST_OUT/r1"
  if [ -d "$dir" ] && ls "$dir"/*/Switcher.app >/dev/null 2>&1; then
    RELEASE_TEST_APP=$(ls -d "$dir"/*/Switcher.app | head -1); export RELEASE_TEST_APP; return 0
  fi
  note "没有 R1 的产物，先跑一次 ad-hoc 归档（几分钟）"
  "$REPO_ROOT/scripts/release/archive.sh" --adhoc --skip-notarize --out "$dir" >"$RELEASE_TEST_OUT/r1-archive.log" 2>&1 || { fail "ad-hoc 归档失败（$RELEASE_TEST_OUT/r1-archive.log）"; finish; }
  RELEASE_TEST_APP=$(ls -d "$dir"/*/Switcher.app | head -1); export RELEASE_TEST_APP
}

marketing_version() { sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$REPO_ROOT/project.yml" | head -1; }
