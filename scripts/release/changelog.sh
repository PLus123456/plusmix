#!/bin/bash
# 抽出 CHANGELOG.md 里某个版本的小节（发布说明 / appcast 的更新说明用；docs/release/versioning.md）。
# 用法：changelog.sh <X.Y.Z | 未发布> [--file CHANGELOG.md]   → 标准输出；找不到退出 1
set -uo pipefail
cd "$(dirname "$0")/../.."
version=""; file=CHANGELOG.md
while [ $# -gt 0 ]; do
  case "$1" in
    --file) file=$2; shift 2 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) version=$1; shift ;;
  esac
done
[ -n "$version" ] && [ -f "$file" ] || { echo "用法：changelog.sh <版本> [--file CHANGELOG.md]" >&2; exit 2; }
out=$(awk -v v="$version" '
  /^## / { if (found) exit; if (index($0, "## " v) == 1) { found = 1; print; next } }
  found { print }' "$file")
[ -n "$out" ] || { echo "[changelog] $file 里没有 ## $version 小节" >&2; exit 1; }
printf '%s\n' "$out"
