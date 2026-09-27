#!/bin/bash
# R13：make 入口挂上了（prompt 71 交付 1 的 `make archive`）：根 Makefile include 了 scripts/release/release.mk，几个目标 make -n 能解析。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
for t in archive archive-adhoc release-verify appcast release-test pin-check pin-sync runner-install; do
  if make -n "$t" >/dev/null 2>&1; then ok "make $t 可解析"; else fail "make $t：没有这个目标（Makefile 没 include scripts/release/release.mk？）"; fi
done
assert_true "make help 提到 archive" bash -c "make help | grep -q archive"
finish
