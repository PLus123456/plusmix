#!/bin/bash
# 跑发布工程的脚本测试（make release-test）。用法：scripts/release/tests/run.sh [test-r3-pins ...]（不给参数 = 全部，按文件名顺序：R1 先出产物）。
# 每个测试：退出 0 = PASS，77 = SKIP（BLOCKED），其他 = FAIL；日志在 .build/release-tests/<名字>.log。最后打一张表，任一 FAIL 退出 1。
set -uo pipefail
cd "$(dirname "$0")"
export RELEASE_TEST_OUT=${RELEASE_TEST_OUT:-$(cd ../../.. && pwd)/.build/release-tests}
mkdir -p "$RELEASE_TEST_OUT"
if [ $# -gt 0 ]; then tests=("$@"); else tests=(); for f in test-*.sh; do tests+=("${f%.sh}"); done; fi
pass=0; failn=0; skipn=0; rows=()
for t in "${tests[@]}"; do
  t=${t%.sh}
  log="$RELEASE_TEST_OUT/$t.log"
  printf '== %s\n' "$t"
  start=$(date +%s)
  bash "./$t.sh" >"$log" 2>&1; code=$?
  secs=$(( $(date +%s) - start ))
  case $code in
    0)  pass=$((pass + 1)); status=PASS ;;
    77) skipn=$((skipn + 1)); status=SKIP ;;
    *)  failn=$((failn + 1)); status=FAIL ;;
  esac
  # 把断言行原样打出来（ok / FAIL / SKIP），方便直接看；lib.sh 的颜色码在行首，先剥掉再匹配
  LC_ALL=C sed $'s/\e\\[[0-9;]*m//g' "$log" | grep -E '^ +(ok|FAIL|SKIP|·) ' | sed 's/^/   /'
  [ "$status" = FAIL ] && tail -20 "$log" | sed 's/^/   | /'
  rows+=("$(printf '%-6s %-44s %4ss  %s' "$status" "$t" "$secs" "$log")")
  # R1 产出的 App 给后面的测试复用
  if [ "$t" = test-r1-archive-adhoc ] && [ -z "${RELEASE_TEST_APP:-}" ]; then
    app=$(ls -d "$RELEASE_TEST_OUT"/r1/*/Switcher.app 2>/dev/null | head -1); [ -n "$app" ] && export RELEASE_TEST_APP="$app"
  fi
done
printf '\n%-6s %-44s %5s  %s\n' 状态 测试 用时 日志
printf '%s\n' "${rows[@]}"
printf '\nPASS %d  FAIL %d  SKIP %d\n' "$pass" "$failn" "$skipn"
[ "$failn" = 0 ]
