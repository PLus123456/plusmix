#!/bin/bash
# R6：.github/workflows 语法与结构（prompt 71 交付 4）：actionlint 零告警；ci.yml 有 L0+L1（每次提交）和 L2（每个 PR）两个 job、
#     nightly.yml 有 soak-1h 与 perf-baseline（perf 非零 = job 失败）、release.yml 由 v* tag 触发；都跑在 self-hosted 的 macOS runner 上。
#     W4-B2：release.yml 的产物名跟 project.yml 的 PRODUCT_NAME（W4-D 改名 PlusMix）：ver 这步用 archive.sh 同一条 sed 算出 product，
#     更新说明 / 上传 / Release 资产与标题都用它，不写死代码名（issue W4D-w4-release-github-release-workflow-product-name）。
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
assert_not_contains "$rel" "Switcher-" "release.yml 不写死 Switcher-<版本> 的产物名"
assert_not_contains "$rel" '"Switcher ' "release.yml 的 Release 标题不写死 Switcher"
prog=$(grep -m1 "^product=\$(sed -n '" "$REPO_ROOT/scripts/release/archive.sh" | cut -d"'" -f2)
if [ -n "$prog" ] && grep -qF -- "sed -n '$prog' project.yml" "$wf/release.yml"; then ok "release.yml 读 PRODUCT_NAME 用的是 archive.sh 同一条 sed"
else fail "release.yml 没用 archive.sh 那条 sed 读 PRODUCT_NAME（archive.sh：${prog:-没找到 product=\$(sed -n …)}）"; fi
for want in '/${{ steps.ver.outputs.product }}-*.dmg' '/${{ steps.ver.outputs.product }}-*.dmg.sha256' \
            '"$dir/$PRODUCT-$VERSION.md"' '"$dir/$PRODUCT-$VERSION.dmg"' '"$dir/$PRODUCT-$VERSION.dmg.sha256"' '--title "$PRODUCT $VERSION"'; do
  if grep -qF -- "$want" "$wf/release.yml"; then ok "release.yml 用产物名：$want"; else fail "release.yml 缺：$want"; fi
done
# 真跑一遍 ver 这步的脚本（仓库根、tag = v<MARKETING_VERSION>，同 Actions 的 bash -e）：输出的 product 要等于 archive.sh 会用的产物名
step="$RELEASE_TEST_OUT/r6-release-ver-step.sh"; outf="$RELEASE_TEST_OUT/r6-release-ver-step.out"; : > "$outf"   # 留着方便看，每次覆盖
if python3 - "$wf/release.yml" ver > "$step" 2>/dev/null <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = next(n for n, l in enumerate(lines) if re.match(r"^\s*id:\s*" + re.escape(sys.argv[2]) + r"\s*$", l))
j = next(n for n in range(i, len(lines)) if re.match(r"^\s*run:\s*\|\s*$", lines[n]))
ind = len(lines[j]) - len(lines[j].lstrip())
body = []
for l in lines[j + 1:]:
    if l.strip() and len(l) - len(l.lstrip()) <= ind:
        break
    body.append(l)
cut = min(len(l) - len(l.lstrip()) for l in body if l.strip())
print("\n".join(l[cut:] for l in body))
PY
then
  if (cd "$REPO_ROOT" && GITHUB_OUTPUT="$outf" GITHUB_REF_NAME="v$(marketing_version)" bash -e "$step") >"$outf.log" 2>&1; then ok "ver 这步在仓库根跑得通（tag v$(marketing_version)）"
  else fail "ver 这步跑失败（脚本 $step，输出 $outf.log）"; fi
else
  fail "release.yml 里找不到 id: ver 那步的 run 脚本"
fi
assert_eq "$(sed -n 's/^product=//p' "$outf")" "$(product_name)" "ver 输出的 product（= archive.sh 的产物名前缀）"
assert_eq "$(sed -n 's/^version=//p' "$outf")" "$(marketing_version)" "ver 输出的 version"
finish
