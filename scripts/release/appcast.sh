#!/bin/bash
# 生成 Sparkle appcast（prompt 71 交付 2）：对一个目录里的 DMG（/ zip）跑 generate_appcast，出 appcast.xml（每项带 EdDSA 签名、版本、最低系统）。
# 同名 .md / .html 文件当该版本的更新说明（scripts/release/changelog.sh X.Y.Z > Switcher-X.Y.Z.md）。
# 用法：appcast.sh <目录> [--download-url-prefix URL] [--account NAME | --ed-key-file FILE|-] [--out appcast.xml]
#                  [--release-notes-url-prefix URL] [--embed-release-notes] [--link URL] [--maximum-versions N]
#        appcast.sh --print-bin-dir       打印 Sparkle 工具目录（测试 / 排障用）
# 发布到 GitHub Releases 时：--download-url-prefix https://github.com/<owner>/<repo>/releases/download/v<版本>/ ，appcast.xml 本身放固定地址
# （SUFeedURL），例如 releases/latest/download/appcast.xml。详见 docs/release/sparkle.md。
set -uo pipefail
. "$(dirname "$0")/sparkle-bin.sh"
dir=""; extra=(); out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --print-bin-dir) sparkle_bin_dir; echo; exit $? ;;
    --download-url-prefix|--release-notes-url-prefix|--link|--maximum-versions|--maximum-deltas|--channel|--major-version|--minimum-update-version)
      extra+=("$1" "$2"); shift 2 ;;
    --account) extra+=(--account "$2"); shift 2 ;;
    --ed-key-file) extra+=(--ed-key-file "$2"); shift 2 ;;
    --out|-o) out=$2; shift 2 ;;
    --embed-release-notes|--auto-prune-update-files) extra+=("$1"); shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    -*) echo "不认识的参数：$1" >&2; exit 2 ;;
    *) dir=$1; shift ;;
  esac
done
[ -n "$dir" ] && [ -d "$dir" ] || { echo "用法：appcast.sh <放 DMG 的目录> [--download-url-prefix URL] …" >&2; exit 2; }
bin=$(sparkle_bin_dir) || exit 2
n=$(ls "$dir"/*.dmg "$dir"/*.zip "$dir"/*.tar.xz 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 0 ] || { echo "[appcast] $dir 里没有 .dmg / .zip" >&2; exit 1; }
[ -n "$out" ] && extra+=(-o "$out")
echo "[appcast] generate_appcast（$bin）→ $dir（$n 个包）"
"$bin/generate_appcast" ${extra[@]+"${extra[@]}"} "$dir" || { echo "[appcast] generate_appcast 失败" >&2; exit 1; }   # bash 3.2 + set -u：空数组的展开写法
result=${out:-$dir/appcast.xml}
[ -f "$result" ] || { echo "[appcast] 没产出 $result" >&2; exit 1; }
echo "[appcast] 写了 $result："
grep -o 'sparkle:shortVersionString="[^"]*"\|sparkle:version="[^"]*"\|url="[^"]*"\|sparkle:minimumSystemVersion>[^<]*' "$result" | sed 's/^/    /'
