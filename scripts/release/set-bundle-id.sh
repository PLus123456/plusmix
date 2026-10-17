#!/bin/bash
# 正式 bundle id 一键切换（prompt 71 第 7 条；用户 2026-09-22 定：Stream Deck 插件 UUID 随 bundle id 一起换、不等 G5）。
# 现在的占位：App 用 com.example（project.yml bundleIdPrefix、PRODUCT_BUNDLE_IDENTIFIER com.example.switcher、扩展 com.example.switcher.camera-extension、
# mach service / app group com.example.switcher.camera、VirtualCameraConstants 的四个 UID、测试的 UserDefaults suite），Stream Deck 插件用 com.plusmix
# （manifest.json 的插件 / 动作 UUID、目录名 com.plusmix.switcher.sdPlugin、package.json / README / docs 里的命令）。
# 域名定下来后跑一次（例如 set-bundle-id.sh com.plusmix），所有出现处一起改；VMixCompat 的 reportedVersion 不在此列（继续报本产品版本）。
#
# 用法：
#   set-bundle-id.sh --check [--root DIR]     报当前的两个前缀
#   set-bundle-id.sh --list  [--root DIR]     列出会改的文件（按内容搜索，不是写死的清单）
#   set-bundle-id.sh <新前缀> [--dry-run] [--root DIR]   新前缀形如 com.plusmix；--dry-run 只打印会改什么
# 改完：make gen build test；扩展要重新签名 / 激活（bundle id 变了就是另一个扩展）；Stream Deck 插件 npm test + 重新 link。
set -uo pipefail
cd "$(dirname "$0")/../.."
root=$PWD; mode=apply; prefix=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check; shift ;;
    --list) mode=list; shift ;;
    --dry-run) mode=dry; shift ;;
    --root) root=$2; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "不认识的参数：$1" >&2; exit 2 ;;
    *) prefix=$1; shift ;;
  esac
done
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
PRODUCT=switcher

current_app_prefix() {
  local id; id=$(sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*\([A-Za-z0-9.-]*\)\.'"$PRODUCT"'[[:space:]]*$/\1/p' "$root/project.yml" | head -1)
  [ -n "$id" ] && printf '%s' "$id"
}
current_sd_prefix() {
  local m; m=$(ls -d "$root"/Tools/streamdeck-plugin/*."$PRODUCT".sdPlugin 2>/dev/null | head -1)
  [ -n "$m" ] || return 1
  basename "$m" | sed 's/\.'"$PRODUCT"'\.sdPlugin$//'
}
# 出现处：按内容搜（排除生成物、报告、计划、node_modules、本脚本与 docs/release）
occurrences() { # $1..: 要找的 id（例如 com.example.switcher）
  local pats=() p
  for p in "$@"; do pats+=(-e "${p//./\\.}"); done
  (cd "$root" && grep -rIl "${pats[@]}" . \
     --exclude-dir=.git --exclude-dir=.build --exclude-dir=node_modules --exclude-dir='*.xcodeproj' --exclude-dir=DerivedData \
     --exclude-dir=reports --exclude-dir=plan --exclude-dir=release --exclude-dir=contract-changes --exclude-dir=.swiftpm \
     2>/dev/null | sed 's|^\./||' | grep -v '^scripts/release/' | sort)
}

app_prefix=$(current_app_prefix) || app_prefix=""
sd_prefix=$(current_sd_prefix) || sd_prefix=""
[ -n "$app_prefix" ] || { red "[set-bundle-id] 读不到 project.yml 里的 PRODUCT_BUNDLE_IDENTIFIER <前缀>.$PRODUCT"; exit 2; }
[ -n "$sd_prefix" ] || { red "[set-bundle-id] 找不到 Tools/streamdeck-plugin/<前缀>.$PRODUCT.sdPlugin"; exit 2; }
app_id="$app_prefix.$PRODUCT"; sd_id="$sd_prefix.$PRODUCT"

case "$mode" in
  check)
    echo "App / 扩展 bundle id 前缀：${app_prefix}（${app_id}、$app_id.camera-extension、mach service $app_id.camera）"
    echo "Stream Deck 插件前缀：      ${sd_prefix}（${sd_id}、目录 $sd_id.sdPlugin）"
    [ "$app_prefix" = "$sd_prefix" ] && green "两者一致" || printf '\033[33m%s\033[0m\n' "两者不一致：定正式域名时跑 set-bundle-id.sh <前缀> 一起换"
    exit 0 ;;
  list)
    occurrences "$app_id" "$sd_id"; exit 0 ;;
esac

[ -n "$prefix" ] || { red "用法：set-bundle-id.sh <新前缀，如 com.plusmix> [--dry-run] [--root DIR]"; exit 2; }
printf '%s' "$prefix" | grep -qE '^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+$' || { red "[set-bundle-id] 前缀要是反写域名（小写字母 / 数字 / 连字符，至少两段）：$prefix"; exit 2; }
[ "$prefix" != "$app_id" ] || { red "[set-bundle-id] 给前缀（com.plusmix），不是完整 id（${app_id}）"; exit 2; }
new_id="$prefix.$PRODUCT"
files=$(occurrences "$app_id" "$sd_id")
[ -n "$files" ] || { red "[set-bundle-id] 没找到任何出现处"; exit 1; }
echo "把 $app_id 与 $sd_id 全部改成 ${new_id}："
printf '  %s\n' $files
sd_dir_old="Tools/streamdeck-plugin/$sd_id.sdPlugin"; sd_dir_new="Tools/streamdeck-plugin/$new_id.sdPlugin"
[ -d "$root/$sd_dir_old" ] && echo "  目录改名：$sd_dir_old → $sd_dir_new"
[ "$mode" = dry ] && { echo "（--dry-run，没改）"; exit 0; }
esc_app=${app_id//./\\.}; esc_sd=${sd_id//./\\.}
for f in $files; do
  # 只改精确的 id（后面不是标识符字符；后缀 .camera-extension / .tests / .cut … 跟着一起换），不碰别的 com.example（Contracts014Tests 里的 bundleID 例子就不动）
  perl -pi -e 's/\b'"$esc_app"'(?![A-Za-z0-9_])/'"$new_id"'/g; s/\b'"$esc_sd"'(?![A-Za-z0-9_])/'"$new_id"'/g' "$root/$f"
done
# project.yml 的 bundleIdPrefix
perl -pi -e 's/^(\s*bundleIdPrefix:\s*)'"${app_prefix//./\\.}"'\b/${1}'"$prefix"'/' "$root/project.yml"
if [ -d "$root/$sd_dir_old" ] && [ "$sd_dir_old" != "$sd_dir_new" ]; then
  if [ -d "$root/.git" ] && git -C "$root" ls-files --error-unmatch "$sd_dir_old" >/dev/null 2>&1; then git -C "$root" mv "$sd_dir_old" "$sd_dir_new"; else mv "$root/$sd_dir_old" "$root/$sd_dir_new"; fi
fi
left=$(occurrences "$app_id" "$sd_id" || true)
if [ -n "$left" ]; then red "[set-bundle-id] 还有没改到的："; printf '  %s\n' $left; exit 1; fi
green "[set-bundle-id] 完成：${new_id}。接下来 make gen build test；扩展要重新签名 / 激活；Stream Deck 插件 npm test、npx streamdeck link $new_id.sdPlugin。"
