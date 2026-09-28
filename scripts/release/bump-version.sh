#!/bin/bash
# 改版本号（prompt 71 交付 5；docs/release/versioning.md）。版本号只在两处：project.yml 的 MARKETING_VERSION 与
# Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift 的 SwitcherVersion.current（lint 校验一致）；构建号 CURRENT_PROJECT_VERSION 单调递增
# （Sparkle 用它比大小：sparkle:version）。CHANGELOG.md 里"## 未发布"小节改成"## X.Y.Z — 日期"，顶上补一个新的"## 未发布"。
# 跑它的是 G5（版本号归 G5 改，docs/OWNERSHIP.md）；本脚本只是工具。
# 用法：bump-version.sh <X.Y.Z[-预发布]> [--build N] [--root DIR] [--changelog CHANGELOG.md] [--date YYYY-MM-DD]
set -uo pipefail
cd "$(dirname "$0")/../.."
root=$PWD; version=""; build=""; changelog=CHANGELOG.md; today=$(date +%Y-%m-%d)
while [ $# -gt 0 ]; do
  case "$1" in
    --build) build=$2; shift 2 ;;
    --root) root=$2; shift 2 ;;
    --changelog) changelog=$2; shift 2 ;;
    --date) today=$2; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    -*) echo "不认识的参数：$1" >&2; exit 2 ;;
    *) version=$1; shift ;;
  esac
done
red() { printf '\033[31m%s\033[0m\n' "$*"; }
[ -n "$version" ] || { red "用法：bump-version.sh <X.Y.Z> [--build N]"; exit 2; }
printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || { red "[bump-version] 版本号要是语义化版本（X.Y.Z 或 X.Y.Z-beta.1）：$version"; exit 2; }
yml="$root/project.yml"; swift="$root/Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift"
[ -f "$yml" ] && [ -f "$swift" ] || { red "[bump-version] $root 下缺 project.yml 或 Version.swift"; exit 2; }
cur=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9A-Za-z.-]*\)"\{0,1\}.*/\1/p' "$yml" | head -1)
curbuild=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' "$yml" | head -1)
# 不许倒退（只比 X.Y.Z 三段）
cmp=$(python3 -c "
import sys
def k(v): return tuple(int(x) for x in v.split('-')[0].split('.'))
a, b = k(sys.argv[1]), k(sys.argv[2]); print('lt' if a < b else 'eq' if a == b else 'gt')" "$version" "$cur")
[ "$cmp" = gt ] || { red "[bump-version] 新版本 $version 不高于当前 $cur"; exit 1; }
[ -n "$build" ] || build=$((curbuild + 1))
printf '%s' "$build" | grep -qE '^[0-9]+$' && [ "$build" -gt "$curbuild" ] || { red "[bump-version] 构建号要是大于 $curbuild 的整数：$build"; exit 1; }
sed -i '' -E 's/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)"[^"]*"/\1"'"$version"'"/' "$yml"
sed -i '' -E 's/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)"[^"]*"/\1"'"$build"'"/' "$yml"
sed -i '' -E 's/(static let current = )"[^"]*"/\1"'"$version"'"/' "$swift"
cl="$root/$changelog"
if [ -f "$cl" ]; then
  if grep -q '^## 未发布' "$cl"; then
    python3 - "$cl" "$version" "$today" <<'PY'
import sys, re
p, ver, day = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
s = re.sub(r'^## 未发布[^\n]*$', f"## 未发布\n\n（无）\n\n## {ver} — {day}", s, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY
  else
    printf '\033[33m%s\033[0m\n' "[bump-version] $changelog 里没有“## 未发布”小节，没改它"
  fi
else
  printf '\033[33m%s\033[0m\n' "[bump-version] 没有 $changelog（G5 从 docs/release/CHANGELOG-template.md 建），没改变更日志"
fi
printf '\033[32m%s\033[0m\n' "[bump-version] $cur (build $curbuild) → $version (build $build)。接下来：make lint（版本号一致）、git tag v$version 在 G5 判定通过后打"
