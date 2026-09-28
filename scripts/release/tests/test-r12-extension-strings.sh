#!/bin/bash
# R12：扩展的 CFBundleDisplayName 中英两份（prompt 71 第 9 条）：归档出来的 .systemextension 里 en.lproj / zh-Hans.lproj 各有 InfoPlist.strings，
#      都带 CFBundleDisplayName；W4-D 改名后（用户 2026-09-28 定名 PlusMix）值是 "PlusMix Virtual Camera" / "PlusMix 虚拟摄像头"，
#      Info.plist 里的默认值仍是 ASCII（W3-C3 定）："PlusMix Virtual Camera"。扩展的 bundle id 不随产品名变。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_archived_app
ext=$(ls -d "$RELEASE_TEST_APP"/Contents/Library/SystemExtensions/*.systemextension 2>/dev/null | head -1)
[ -n "$ext" ] || { fail "没有扩展"; finish; }
for lang in en zh-Hans; do
  f="$ext/Contents/Resources/$lang.lproj/InfoPlist.strings"
  assert_file "$f" "$lang.lproj/InfoPlist.strings"
  [ -f "$f" ] || continue
  name=$(plutil -extract CFBundleDisplayName raw -o - "$f" 2>/dev/null || true)
  case "$lang" in
    en) assert_eq "$name" "PlusMix Virtual Camera" "en：CFBundleDisplayName" ;;
    zh-Hans) assert_eq "$name" "PlusMix 虚拟摄像头" "zh-Hans：CFBundleDisplayName"
             printf '%s' "$name" | grep -q "[一-鿿]" && ok "中文那份是中文" || fail "zh-Hans 的显示名不含中文：$name" ;;
  esac
done
# Info.plist 里的默认值仍是 ASCII（W3-C3 定），用产品名
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$ext/Contents/Info.plist")" "PlusMix Virtual Camera" "Info.plist 默认显示名"
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$ext/Contents/Info.plist")" "com.plusmix.switcher.camera-extension" "扩展 bundle id 不随产品名变"
finish
