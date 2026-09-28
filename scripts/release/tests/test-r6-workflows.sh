#!/bin/bash
# R6：.github/workflows 语法与结构（prompt 71 交付 4）：actionlint 零告警；ci.yml 有 L0+L1（每次提交）和 L2（每个 PR）两个 job、
#     nightly.yml 有 soak-1h 与 perf-baseline（perf 非零 = job 失败）、release.yml 由 v* tag 触发；都跑在 self-hosted 的 macOS runner 上。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
wf="$REPO_ROOT/.github/workflows"
for f in ci.yml nightly.yml release.yml; do assert_file "$wf/$f" ".github/workflows/$f"; done
if command -v actionlint >/dev/null 2>&1; then
  out=$(cd "$REPO_ROOT" && actionlint 2>&1); code=$?
  [ $code = 0 ] && ok "actionlint 零告警" || fail "actionlint：$out"
else
  note "没有 actionlint（brew install actionlint），只做 YAML 解析"
  for f in "$wf"/*.yml; do python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null && ok "YAML 可解析：$(basename "$f")" || fail "YAML 解析失败：$f"; done
fi
ci=$(cat "$wf/ci.yml")
assert_contains "$ci" "self-hosted" "ci.yml 用 self-hosted runner"
assert_contains "$ci" "make test" "ci.yml 跑 make test（L0 + L1）"
assert_contains "$ci" "make lint" "ci.yml 跑 make lint"
assert_contains "$ci" "gate4-run" "ci.yml 的 L2 用 make gate4-run（10 分钟集成场景）"
assert_contains "$ci" "pull_request" "ci.yml 在 PR 上触发 L2"
nightly=$(cat "$wf/nightly.yml")
assert_contains "$nightly" "schedule" "nightly.yml 定时"
assert_contains "$nightly" "soak-1h" "nightly.yml 跑 make soak-1h"
assert_contains "$nightly" "perf-baseline" "nightly.yml 跑 make perf-baseline"
assert_contains "$nightly" "caffeinate" "nightly.yml 用 caffeinate 防休眠（W4-A 第 7 条）"
rel=$(cat "$wf/release.yml")
assert_contains "$rel" "tags:" "release.yml 由 tag 触发"
assert_contains "$rel" "make archive" "release.yml 跑 make archive"
assert_contains "$rel" "DEVELOPMENT_TEAM" "release.yml 从 secret 拿 Team ID"
assert_not_contains "$rel" "AKIA\|-----BEGIN" "release.yml 里没有写死的密钥"
finish
