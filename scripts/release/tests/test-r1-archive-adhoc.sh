#!/bin/bash
# R1：没有 Developer ID 时，`make archive` 在 ad-hoc 签名下走通除公证外的全部步骤（prompt 71 交付 1 / 测试段）。
# 产物（W4-D 改名后，用户 2026-09-28 定名 PlusMix）：<out>/<版本>/PlusMix.xcarchive、PlusMix.app、PlusMix-<版本>.dmg（+ .sha256）、release-report.md、verify.json；
#       产物名 = project.yml 里 App target 的 PRODUCT_NAME，可执行 Contents/MacOS/PlusMix，CFBundleName / CFBundleDisplayName = PlusMix；bundle id 仍是 com.plusmix.switcher。
# 断言：App 与扩展签名可验；libndi.dylib 进了 Contents/Frameworks 且主二进制不再带 SDK 目录的 LC_RPATH；Sparkle.framework 嵌入并签名；
#       许可证文件进包；Info.plist 带 Sparkle 两个键；版本号与 project.yml 一致；DMG 能校验、能挂载、里面有 App 和 Applications 链接；
#       报告里公证一行标 BLOCKED-账号；App 能起来跑 4 秒不崩（dyld / 签名问题在这里就会现形）。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
out="$RELEASE_TEST_OUT/r1"
rm -rf "$out"
ver=$(marketing_version)
product=PlusMix
assert_eq "$(product_name)" "$product" "project.yml 的 App target PRODUCT_NAME"
note "ad-hoc 归档到 ${out}（版本 ${ver}，产品名 ${product}）"
if ! "$REPO_ROOT/scripts/release/archive.sh" --adhoc --skip-notarize --out "$out" >"$RELEASE_TEST_OUT/r1-archive.log" 2>&1; then
  fail "archive.sh --adhoc 退出非 0（日志 $RELEASE_TEST_OUT/r1-archive.log）"; tail -30 "$RELEASE_TEST_OUT/r1-archive.log"; finish
fi
ok "archive.sh --adhoc --skip-notarize 退出 0"
dir="$out/$ver"
app="$dir/$product.app"
assert_file "$dir/$product.xcarchive" "xcarchive（$product.xcarchive）"
assert_file "$app" "导出的 $product.app"
assert_file "$dir/$product-$ver.dmg" "DMG（$product-$ver.dmg）"
assert_file "$dir/$product-$ver.dmg.sha256" "DMG 的 sha256"
assert_file "$dir/release-report.md" "release-report.md"
assert_file "$dir/verify.json" "verify.json"
assert_no_file "$dir/Switcher.app" "旧产物名 Switcher.app 不再出现"
assert_no_file "$dir/Switcher.xcarchive" "旧产物名 Switcher.xcarchive 不再出现"
[ -d "$app" ] || finish

# ---- 名字 ----
plist="$app/Contents/Info.plist"
bin="$app/Contents/MacOS/$product"
assert_file "$bin" "可执行 Contents/MacOS/$product"
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist")" "$product" "CFBundleExecutable"
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$plist")" "$product" "CFBundleName（= PRODUCT_NAME）"
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$plist")" "$product" "CFBundleDisplayName"
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")" "com.plusmix.switcher" "bundle id 不随产品名变"
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")" "$ver" "CFBundleShortVersionString"
assert_eq "$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist")" "15.0" "LSMinimumSystemVersion"

# ---- 签名 ----
assert_true "codesign --verify --deep --strict 通过" codesign --verify --deep --strict --verbose=2 "$app"
sig=$(codesign -dvv "$app" 2>&1)
assert_contains "$sig" "Signature=adhoc" "主程序是 ad-hoc 签名（本机没有 Developer ID）"
ext=$(ls -d "$app"/Contents/Library/SystemExtensions/*.systemextension 2>/dev/null | head -1)
assert_file "$ext" "扩展嵌在 Contents/Library/SystemExtensions/"
[ -n "$ext" ] && assert_true "扩展签名可验" codesign --verify --strict "$ext"

# ---- NDI 运行库随包 ----
ndi="$app/Contents/Frameworks/libndi.dylib"
assert_file "$ndi" "Contents/Frameworks/libndi.dylib"
[ -f "$ndi" ] && assert_true "libndi.dylib 已重签（可验）" codesign --verify --strict "$ndi"
rpaths=$(otool -l "$bin" | grep -A2 LC_RPATH | grep path || true)
assert_not_contains "$rpaths" "NDI SDK" "主二进制没有指向 SDK 目录的 LC_RPATH（只从包内找 libndi）"
assert_contains "$rpaths" "@executable_path/../Frameworks" "主二进制保留 @executable_path/../Frameworks"
assert_file "$app/Contents/Resources/Licenses/NDI/libndi_licenses.txt" "NDI 许可证文件进包（SDK 要求随二进制分发）"

# ---- Sparkle ----
spk="$app/Contents/Frameworks/Sparkle.framework"
assert_file "$spk" "Sparkle.framework 嵌入"
[ -d "$spk" ] && assert_true "Sparkle.framework 签名可验（含 XPC / Autoupdate）" codesign --verify --deep --strict "$spk"
assert_file "$spk/Versions/B/XPCServices/Installer.xpc" "Installer.xpc"
assert_file "$app/Contents/Resources/Licenses/Sparkle/LICENSE" "Sparkle 许可证进包"
assert_true "Info.plist 有 SUFeedURL" /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$plist"
assert_true "Info.plist 有 SUPublicEDKey" /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$plist"

# ---- DMG ----
dmg="$dir/$product-$ver.dmg"
assert_true "hdiutil verify 通过" hdiutil verify "$dmg"
(cd "$dir" && shasum -a 256 -c "$product-$ver.dmg.sha256" >/dev/null 2>&1) && ok "sha256 对得上" || fail "sha256 对不上"
mnt=$(mktemp -d "$RELEASE_TEST_OUT/mnt.XXXX")
if hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1; then
  assert_file "$mnt/$product.app" "DMG 里有 $product.app"
  [ -L "$mnt/Applications" ] && ok "DMG 里有 Applications 链接" || fail "DMG 里没有 Applications 链接"
  hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet
else
  fail "DMG 挂不上"
fi
rmdir "$mnt" 2>/dev/null

# ---- 报告 ----
report=$(cat "$dir/release-report.md")
assert_contains "$report" "BLOCKED-账号" "报告里公证一行标 BLOCKED-账号"
assert_contains "$report" "spctl" "报告里有 spctl 结果"
assert_contains "$report" "$product $ver" "报告标题用产品名"
vj=$(cat "$dir/verify.json")
assert_contains "$vj" '"signature_valid": true' "verify.json：signature_valid"
assert_contains "$vj" '"notarized": false' "verify.json：ad-hoc 下 notarized = false"

# ---- 起得来 ----
smoke="$RELEASE_TEST_OUT/r1-smoke.log"
"$bin" --show "$REPO_ROOT/scenarios/g4-ndi-show.json" --no-api --audio-device null >"$smoke" 2>&1 &
pid=$!
sleep 4
if kill -0 "$pid" 2>/dev/null; then ok "App 起来 4 秒没崩（dyld / libndi / Sparkle 都加载成功）"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; else
  wait "$pid"; code=$?; fail "App 4 秒内退出（码 ${code}）：$(tail -3 "$smoke")"; fi
finish
