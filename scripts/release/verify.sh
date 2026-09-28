#!/bin/bash
# 校验发布产物（prompt 71 交付 1 的 spctl -a -vv 验证脚本）：签名（codesign --deep --strict）、Gatekeeper（spctl --assess）、公证票据（stapler validate）、
# 系统扩展、随包的 libndi.dylib（且主二进制不再指向 SDK 目录）、Sparkle.framework 与 Info.plist 的两个键、版本号。
# 用法：verify.sh <PlusMix.app | PlusMix-x.dmg> [--expect-notarized] [--json 输出.json] [--quiet]（可执行名从 CFBundleExecutable 读，不写死）
#   退出 0：结构与签名都对（ad-hoc 时 spctl 会 rejected，只记录不算失败）；--expect-notarized 时还要求 spctl accepted + 已 staple。
#   退出 1：签名验不过 / 缺扩展 / 链接了 libndi 却没随包 / Sparkle 缺 / --expect-notarized 没满足。
set -uo pipefail
target=""; expect_notarized=0; json=""; quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-notarized) expect_notarized=1; shift ;;
    --json) json=$2; shift 2 ;;
    --quiet) quiet=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    -*) echo "不认识的参数：$1" >&2; exit 2 ;;
    *) target=$1; shift ;;
  esac
done
[ -e "$target" ] || { echo "用法：verify.sh <PlusMix.app | .dmg> [--expect-notarized] [--json out]" >&2; exit 2; }

declare -a keys=() vals=()   # 结果表（bash 3.2 没有关联数组）
set_r() { keys+=("$1"); vals+=("$2"); }
fails=0
say()  { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }
pass() { set_r "$1" true;  say "  ok    $1: ${2:-}"; }
warn() { set_r "$1" false; say "  info  $1: ${2:-}"; }
bad()  { set_r "$1" false; fails=$((fails + 1)); say "  FAIL  $1: ${2:-}"; }

mnt=""; app=""
cleanup() { [ -n "$mnt" ] && { hdiutil detach "$mnt" -quiet 2>/dev/null || hdiutil detach "$mnt" -force -quiet 2>/dev/null; rmdir "$mnt" 2>/dev/null; }; }
trap cleanup EXIT
case "$target" in
  *.dmg)
    set_r "target_kind" '"dmg"'
    if hdiutil verify "$target" >/dev/null 2>&1; then pass dmg_checksum "hdiutil verify"; else bad dmg_checksum "hdiutil verify 失败"; fi
    mnt=$(mktemp -d /tmp/switcher-verify.XXXX)
    hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$target" >/dev/null 2>&1 || { bad dmg_mount "挂不上"; fails=1; }
    app=$(ls -d "$mnt"/*.app 2>/dev/null | head -1)
    [ -n "$app" ] && pass dmg_contains_app "$(basename "$app")" || bad dmg_contains_app "DMG 里没有 .app"
    [ -L "$mnt/Applications" ] && pass dmg_applications_link "" || warn dmg_applications_link "没有 Applications 链接"
    dsig=$(codesign -dvv "$target" 2>&1 | grep -E '^Authority=' | head -1)
    [ -n "$dsig" ] && pass dmg_signed "$dsig" || warn dmg_signed "DMG 没签名（ad-hoc 构建正常）"
    if xcrun stapler validate "$target" >/dev/null 2>&1; then pass dmg_stapled ""; else warn dmg_stapled "没有 staple 票据"; fi
    ;;
  *.app) set_r "target_kind" '"app"'; app=$target ;;
  *) echo "[verify] 只认 .app 或 .dmg：$target" >&2; exit 2 ;;
esac
[ -n "$app" ] && [ -d "$app" ] || { say "没有 App 可校验"; fails=$((fails + 1)); app=""; }

if [ -n "$app" ]; then
  plist="$app/Contents/Info.plist"
  bin="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)"
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null); build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)
  set_r version "\"$ver\""; set_r build "\"$build\""; set_r bundle_id "\"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)\""
  say "== $app（$ver build $build）"
  # 签名
  if out=$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1); then pass signature_valid "--deep --strict"; else bad signature_valid "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
  info=$(codesign -dvv "$app" 2>&1)
  sig=$(printf '%s' "$info" | sed -n 's/^Signature=//p' | head -1); team=$(printf '%s' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1); auth=$(printf '%s' "$info" | sed -n 's/^Authority=//p' | head -1)
  flags=$(printf '%s' "$info" | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p' | head -1)
  set_r signature "\"${sig:-$auth}\""; set_r team_id "\"$team\""; set_r code_directory_flags "\"$flags\""
  if [ "$sig" = adhoc ]; then set_r adhoc true; say "  info  签名：ad-hoc（TeamIdentifier ${team:-not set}）"; else set_r adhoc false; say "  info  签名：$auth（Team $team）"; fi
  case "$flags" in *runtime*) set_r hardened_runtime true ;; *) set_r hardened_runtime false ;; esac
  # Gatekeeper
  sp=$(spctl --assess --type execute --verbose=4 "$app" 2>&1); spcode=$?
  src=$(printf '%s' "$sp" | sed -n 's/.*source=\(.*\)$/\1/p' | head -1)
  set_r spctl_output "\"$(printf '%s' "$sp" | tr '\n' ' ' | sed 's/"/\\"/g')\""
  if [ $spcode = 0 ]; then pass spctl_accepted "$sp"; else warn spctl_accepted "$sp"; fi
  case "$src" in *Notarized*) set_r notarized true; say "  ok    公证：$src" ;; *) set_r notarized false; say "  info  未公证（source=${src:-?}）" ;; esac
  if xcrun stapler validate "$app" >/dev/null 2>&1; then pass stapled ""; else warn stapled "没有 staple 票据"; fi
  # 扩展
  ext=$(ls -d "$app"/Contents/Library/SystemExtensions/*.systemextension 2>/dev/null | head -1)
  if [ -n "$ext" ]; then
    if codesign --verify --strict "$ext" >/dev/null 2>&1; then pass extension_signed "$(basename "$ext")"; else bad extension_signed "$(basename "$ext") 验不过"; fi
    ent=$(codesign -d --entitlements - --xml "$ext" 2>/dev/null)
    # here-string 不走管道：pipefail 下 `printf | grep -q` 命中即退出会让 printf（按行写）吃 SIGPIPE，结果随调度翻转（W4-B2）
    grep -q "com.apple.security.app-sandbox" <<< "$ent" && pass extension_sandboxed "" || bad extension_sandboxed "扩展没有 app-sandbox 权限"
    for lang in en zh-Hans; do [ -f "$ext/Contents/Resources/$lang.lproj/InfoPlist.strings" ] && pass "extension_strings_$lang" "" || warn "extension_strings_$lang" "缺 $lang.lproj/InfoPlist.strings"; done
  else bad extension_present "Contents/Library/SystemExtensions 里没有扩展"; fi
  # libndi
  if otool -L "$bin" 2>/dev/null | grep -q "libndi.dylib"; then
    set_r links_ndi true
    if [ -f "$app/Contents/Frameworks/libndi.dylib" ] && codesign --verify --strict "$app/Contents/Frameworks/libndi.dylib" >/dev/null 2>&1; then pass ndi_bundled "Contents/Frameworks/libndi.dylib"; else bad ndi_bundled "链接了 libndi 却没随包（或没签名）"; fi
    # otool -l 输出几十 KB、分几次写：先收齐再 grep -q，不让命中即退出的 grep -q 把上游截断（同上，W4-B2）
    rpaths=$(otool -l "$bin" | grep -A2 LC_RPATH || true)
    if grep -q "NDI SDK" <<< "$rpaths"; then bad ndi_rpath_clean "主二进制还带着 SDK 目录的 LC_RPATH"; else pass ndi_rpath_clean ""; fi
    [ -f "$app/Contents/Resources/Licenses/NDI/libndi_licenses.txt" ] && pass ndi_license "" || bad ndi_license "缺 Resources/Licenses/NDI/libndi_licenses.txt（SDK 再分发条款要求）"
  else set_r links_ndi false; say "  info  这份构建没链接 libndi（编译机没装 NDI SDK；Stats 会标 unavailable）"; fi
  # Sparkle
  spk="$app/Contents/Frameworks/Sparkle.framework"
  if [ -d "$spk" ]; then
    codesign --verify --deep --strict "$spk" >/dev/null 2>&1 && pass sparkle_signed "" || bad sparkle_signed "Sparkle.framework 验不过"
    feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null); key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null)
    set_r sparkle_feed_url "\"$feed\""
    if [ -n "$feed" ] && [ -n "$key" ]; then set_r sparkle_configured true; pass sparkle_configured "$feed"; else set_r sparkle_configured false; say "  info  Sparkle 未配置（SUFeedURL / SUPublicEDKey 为空：这份构建不带更新）"; fi
    [ -f "$app/Contents/Resources/Licenses/Sparkle/LICENSE" ] && pass sparkle_license "" || warn sparkle_license "缺 Resources/Licenses/Sparkle/LICENSE"
  else bad sparkle_present "没有 Sparkle.framework"; fi
  # 架构 / 最低系统
  archs=$(lipo -archs "$bin" 2>/dev/null); set_r archs "\"$archs\""; say "  info  架构：$archs；LSMinimumSystemVersion $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null)"
fi

# --expect-notarized
notarized=false; stapled=false
for i in "${!keys[@]}"; do [ "${keys[$i]}" = notarized ] && notarized=${vals[$i]}; [ "${keys[$i]}" = stapled ] && stapled=${vals[$i]}; done
if [ "$expect_notarized" = 1 ]; then
  [ "$notarized" = true ] && [ "$stapled" = true ] && say "  ok    已公证且已 staple" || { fails=$((fails + 1)); say "  FAIL  要求已公证 + staple：notarized=$notarized stapled=$stapled"; }
fi
if [ -n "$json" ]; then
  { echo "{"; for i in "${!keys[@]}"; do sep=","; [ "$i" = $((${#keys[@]} - 1)) ] && sep=""; printf '  "%s": %s%s\n' "${keys[$i]}" "${vals[$i]}" "$sep"; done; echo "}"; } > "$json"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json" 2>/dev/null || echo "[verify] 警告：$json 不是合法 JSON" >&2
fi
if [ "$fails" = 0 ]; then say "[verify] 通过"; exit 0; else say "[verify] $fails 项失败"; exit 1; fi
