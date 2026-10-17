#!/bin/bash
# G4：编译矩阵三种配置（prompt 60 第 2 条；W3-A 报告 §2.3 的 A / B / C）——SwitcherInputs 的 NDI / DeckLink 可选 target 在
#   A 都在（本机默认：NDI SDK + NDI 示例自带的 DeckLink 头）、B 只有 NDI（DECKLINK_SDK_DIR 指到不存在的路径）、C 都不在
#   三种配置下都能编译，且 NDITests + DeckLinkTests 在每种配置下都过（没 SDK 的那组用例按 BLOCKED-SDK 跳过，"无 SDK 行为"用例真跑）。
#   SwiftPM 清单随环境变量重新求值，切配置不用 make clean（W3-A §5 第 1 条）。
# 用法：scripts/gate4-matrix.sh [--report reports/G4-matrix.md] [--skip-tests]
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
report="reports/G4-matrix.md"; run_tests=1
while [ $# -gt 0 ]; do
  case "$1" in
    --report) report="$2"; shift 2 ;;
    --skip-tests) run_tests=0; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }
pkg=Packages/SwitcherInputs
out=.build/gate4/matrix; mkdir -p "$out"
lines=("## 编译矩阵（scripts/gate4-matrix.sh，$(date '+%Y-%m-%d %H:%M')）" "" "SwitcherInputs 的可选 target（W3-A）在三种 SDK 配置下 \`swift build\` + \`swift test --filter 'NDITests|DeckLinkTests'\`（debug）。" ""
       "| 配置 | 环境 | swift build | NDITests + DeckLinkTests | 通过 |" "|---|---|---|---|---|")
all_ok=1
run_config() { # $1 名字 $2 说明 $3... 环境变量赋值
  local name=$1 desc=$2; shift 2
  step "配置 ${name}（${desc}）：$*"
  local blog="$out/build-$name.log" tlog="$out/test-$name.log" bres tres ok=1 tsum="—"
  if env "$@" swift build --package-path "$pkg" > "$blog" 2>&1; then bres="✅"; else bres="❌（看 ${blog}）"; ok=0; fi
  if [ "$run_tests" = 1 ] && [ "$ok" = 1 ]; then
    if env "$@" swift test --package-path "$pkg" --filter 'NDITests|DeckLinkTests' > "$tlog" 2>&1; then tres="✅"; else tres="❌（看 ${tlog}）"; ok=0; fi
    # 只数每个 .xctest target 的汇总行（Xcode 27 的 swift test 对每个类、每个 target、"All tests" 各印一次 Executed）；
    # 行形如 "Executed 20 tests, with 2 tests skipped and 0 failures (0 unexpected)"
    tsum=$(python3 - "$tlog" <<'PYSUM'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
e = s = f = 0; parts = []
for i, l in enumerate(lines):
    m = re.match(r"Test Suite '(\w+)\.xctest' (passed|failed)", l)
    if not m: continue
    n = lines[i + 1] if i + 1 < len(lines) else ""
    x = re.search(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", n)
    if not x or x.group(1) == "0": continue   # --filter 之外的 target 印 "Executed 0 tests"，不列
    e += int(x.group(1)); s += int(x.group(2) or 0); f += int(x.group(3))
    parts.append(f"{m.group(1)} {x.group(1)}（跳过 {x.group(2) or 0}）")
print(f"{e} 个，失败 {f}，跳过 {s}：" + "、".join(parts))
PYSUM
)
    [ -n "$tsum" ] || tsum=$(grep -E 'Executed [0-9]+ tests?' "$tlog" | tail -1)
  fi
  [ "$ok" = 1 ] || all_ok=0
  lines+=("| $name | ${desc}（\`$*\`） | $bres | ${tres:-未跑} $tsum | $([ "$ok" = 1 ] && echo ✅ || echo ❌) |")
}
run_config A "都在（本机默认）" NOOP_MATRIX=1
run_config B "只有 NDI" DECKLINK_SDK_DIR=/nonexistent
run_config C "都不在" NDI_SDK_DIR=/nonexistent DECKLINK_SDK_DIR=/nonexistent
# 切回默认配置重编一次，免得留着 C 配置的产物
env swift build --package-path "$pkg" > "$out/build-restore.log" 2>&1 || true
lines+=("" "- 日志：\`$out/\`。切配置只改环境变量（清单重新求值），最后按默认配置重编一次还原产物。" "- 结论：**$([ "$all_ok" = 1 ] && echo 通过 || echo 未通过)**。")
printf '%s\n' "${lines[@]}" > "$report"
printf '%s\n' "${lines[@]}"
[ "$all_ok" = 1 ] && green "编译矩阵通过 → $report" || red "编译矩阵有配置失败（${report}）"
[ "$all_ok" = 1 ]
