#!/bin/bash
# R13：make 入口挂上了（prompt 71 交付 1 的 `make archive`）：根 Makefile include 了 scripts/release/release.mk，几个目标 make -n 能解析。
#      W4-B2（prompt 83 交付 2）：文档链接检查挂进 make lint——scripts/check-links.sh 可执行、被 EXTRA_LINTS 带上，按自己的位置转调
#      docs/tools/check-links.py（不看当前目录），参数与退出码原样传。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
for t in archive archive-adhoc release-verify appcast release-test pin-check pin-sync runner-install; do
  if make -n "$t" >/dev/null 2>&1; then ok "make $t 可解析"; else fail "make $t：没有这个目标（Makefile 没 include scripts/release/release.mk？）"; fi
done
assert_true "make help 提到 archive" bash -c "make help | grep -q archive"
cl="$REPO_ROOT/scripts/check-links.sh"
assert_true "scripts/check-links.sh 存在且可执行（CI 的 ci-ownership.sh 只带可执行的）" test -x "$cl"
assert_contains "$(make -n lint 2>/dev/null)" "scripts/check-links.sh" "make lint 带上 scripts/check-links.sh（docs/OWNERSHIP.md 补充规则 4）"
# 在副本上验转调：一个坏链接 → 退出非 0 并点名；从 / 调也找得到 check-links.py；给范围参数时只查那个范围
scratch=$(mktemp -d "$RELEASE_TEST_OUT/r13.XXXX")
mkdir -p "$scratch/scripts" "$scratch/docs/tools"
cp "$cl" "$scratch/scripts/" 2>/dev/null; cp "$REPO_ROOT/docs/tools/check-links.py" "$scratch/docs/tools/"
printf '[坏链接](不存在.md)\n' > "$scratch/docs/a.md"
out=$(cd / && "$scratch/scripts/check-links.sh" 2>&1); code=$?
[ "$code" != 0 ] && ok "副本里有坏链接时 check-links.sh 退出非 0（${code}）" || fail "副本里有坏链接时 check-links.sh 应退出非 0"
assert_contains "$out" "docs/a.md:1: 目标不存在" "从别的目录调也找得到 check-links.py，并点名坏链接"
assert_true "参数原样传给 check-links.py（只查 Samples 时 docs 的坏链接不算）" bash -c "cd / && '$scratch/scripts/check-links.sh' Samples"
printf '[好链接](a.md)\n' > "$scratch/docs/a.md"
assert_true "链接都对时退出 0" bash -c "cd / && '$scratch/scripts/check-links.sh'"
rm -rf "$scratch"
finish
