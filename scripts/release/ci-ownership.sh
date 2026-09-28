#!/bin/bash
# CI 里的 lint（.github/workflows/ci.yml）：分支在 docs/OWNERSHIP.md 有行时工作流直接跑 make lint BRANCH=<分支>；没有行（main、临时分支、PR 的合并分支）
# 就跑本脚本 --no-ownership：lint-rules + check-deps + 会话自加的 scripts/{check,lint}-*.sh，跳过目录归属。本地直接 make lint 即可。
set -uo pipefail
cd "$(dirname "$0")/../.."
no_ownership=0
[ "${1:-}" = --no-ownership ] && no_ownership=1
status=0
scripts/lint-rules.sh || status=1
scripts/check-deps.sh || status=1
if [ "$no_ownership" = 1 ]; then
  printf '\033[33m[ci-ownership] 跳过目录归属检查（分支在 docs/OWNERSHIP.md 没有行；检查点合并前请用会话分支名跑 make lint BRANCH=<分支>）\033[0m\n'
else
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo main)
  scripts/check-ownership.sh "$branch" || status=1
fi
for s in scripts/lint-*.sh scripts/check-*.sh; do
  case "$s" in scripts/lint-rules.sh|scripts/check-deps.sh|scripts/check-ownership.sh) continue ;; esac
  [ -x "$s" ] || continue
  echo "== $s"; "$s" || status=1
done
exit $status
