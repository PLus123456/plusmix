#!/bin/bash
# 由内向外重签一个 PlusMix.app（prompt 71 交付 1；不写死包名与可执行名）。归档 / 导出后我们往包里加了 libndi.dylib 与许可证、删了主二进制里指向 SDK 目录的 LC_RPATH，
# 外层封条就失效了，所以最后统一签一遍：先包内的 dylib → Sparkle.framework 里的 XPC / Autoupdate / Updater.app → 框架本体 → 系统扩展 → App 本体。
# 权限表：--entitlements FILE 给 App；--extension-entitlements FILE 给扩展；不给 = 从现有签名里抽（codesign -d --entitlements --xml），保持不变。
# Developer ID：--options runtime（硬化运行时，公证要求）+ --timestamp；ad-hoc（-s -）不带这两项（Xcode 对 ad-hoc 也是这么做的）。
# 用法：sign.sh <PlusMix.app> (--identity "Developer ID Application: …" | --adhoc) [--entitlements F] [--extension-entitlements F] [--verbose]
set -uo pipefail
app=""; identity=""; adhoc=0; ent=""; ext_ent=""; verbose=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) identity=$2; shift 2 ;;
    --adhoc) adhoc=1; shift ;;
    --entitlements) ent=$2; shift 2 ;;
    --extension-entitlements) ext_ent=$2; shift 2 ;;
    --verbose) verbose=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -*) echo "不认识的参数：$1" >&2; exit 2 ;;
    *) app=$1; shift ;;
  esac
done
[ -d "$app" ] && [ -f "$app/Contents/Info.plist" ] || { echo "用法：sign.sh <PlusMix.app> --identity ID | --adhoc" >&2; exit 2; }
if [ "$adhoc" = 1 ]; then sign_id="-"; opts=(); else
  [ -n "$identity" ] || { echo "[sign] 要 --identity 或 --adhoc" >&2; exit 2; }
  sign_id=$identity; opts=(--options runtime --timestamp)
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
log() { printf '[sign] %s\n' "$*"; }

# 抽现有权限表；空 = 没有
extract_entitlements() { # $1 = code path, $2 = out file；返回 0 = 有权限表
  codesign -d --entitlements - --xml "$1" > "$2" 2>/dev/null && [ -s "$2" ] && grep -q "<dict" "$2"
}
sign_one() { # $1 = path, 其余 = 附加参数（--entitlements F）
  local p=$1; shift
  # bash 3.2 + set -u：空数组要用 ${opts[@]+"${opts[@]}"} 展开（ad-hoc 时 opts 为空）
  if [ "$verbose" = 1 ]; then codesign --force --sign "$sign_id" ${opts[@]+"${opts[@]}"} "$@" --verbose=2 "$p"; else codesign --force --sign "$sign_id" ${opts[@]+"${opts[@]}"} "$@" "$p" 2>&1 | grep -v "replacing existing signature" || true; fi
  codesign --verify --strict "$p" >/dev/null 2>&1 || { echo "[sign] 签完验不过：$p" >&2; exit 1; }
}
# 带权限表签：给定文件 → 用它；否则抽现有的
sign_with_entitlements() { # $1 = path, $2 = 指定的权限表（可空）
  local p=$1
  local given=${2:-}
  local f="$tmp/$(basename "$p").ent.plist"
  if [ -n "$given" ]; then sign_one "$p" --entitlements "$given"
  elif extract_entitlements "$p" "$f"; then sign_one "$p" --entitlements "$f"
  else sign_one "$p"; fi
}

fw="$app/Contents/Frameworks"
# 1. 顶层 dylib（libndi.dylib、Swift 兼容库）
for f in "$fw"/*.dylib; do [ -f "$f" ] || continue; log "$(basename "$f")"; sign_one "$f"; done
# 2. 框架：先里面的可执行捆绑（XPC、Autoupdate、Updater.app），再框架本体
for framework in "$fw"/*.framework; do
  [ -d "$framework" ] || continue
  cur="$framework/Versions/Current"; [ -d "$cur" ] || cur="$framework"
  for x in "$cur"/XPCServices/*.xpc; do [ -d "$x" ] || continue; log "$(basename "$framework")/$(basename "$x")"; sign_one "$x"; done
  [ -f "$cur/Autoupdate" ] && { log "$(basename "$framework")/Autoupdate"; sign_one "$cur/Autoupdate"; }
  [ -d "$cur/Updater.app" ] && { log "$(basename "$framework")/Updater.app"; sign_one "$cur/Updater.app"; }
  log "$(basename "$framework")"; sign_one "$framework"
done
# 3. 系统扩展（保留它的权限表：沙盒 + app group）
for ext in "$app"/Contents/Library/SystemExtensions/*.systemextension; do
  [ -d "$ext" ] || continue
  log "$(basename "$ext")"; sign_with_entitlements "$ext" "$ext_ent"
done
# 4. 其他嵌入的可执行捆绑（PlugIns / Helpers，目前没有；以后加了也照顾到）
for b in "$app"/Contents/PlugIns/* "$app"/Contents/Library/LoginItems/* "$app"/Contents/Helpers/*; do
  [ -e "$b" ] || continue; log "$(basename "$b")"; sign_with_entitlements "$b" ""
done
# 5. App 本体
log "$(basename "$app")"; sign_with_entitlements "$app" "$ent"
codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/[sign]   /'
codesign --verify --deep --strict "$app" || { echo "[sign] 整包 --deep --strict 验不过" >&2; exit 1; }
log "完成：$(codesign -dvv "$app" 2>&1 | grep -E '^(Authority|Signature|TeamIdentifier)' | head -3 | tr '\n' ' ')"
