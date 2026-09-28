#!/bin/bash
# R5：Sparkle appcast 生成（prompt 71 交付 2）。要点：
#   - 私钥用文件（32 字节 ed25519 种子的 base64，= sparkle-keys.sh export 的格式），不碰钥匙串——generate_appcast / sign_update 读别的工具存进钥匙串的密钥会弹授权框，
#     无人值守就卡死（W4-B 撞过十分钟）。
#   - generate_appcast 只在 App 的 SUPublicEDKey 与私钥配对时才写 sparkle:edSignature（SUPublicEDKey 为空 / 不配就只警告、不签）——所以测试先给 R1 的 App 拷一份，
#     用 openssl 从种子推出公钥写进 Info.plist、ad-hoc 重签、dmg.sh 打包，再出 appcast。这同时说明：发布归档必须带 SPARKLE_PUBLIC_ED_KEY，否则 appcast 没签名、用户装不了。
#   - Sparkle 2.10 把 version / shortVersionString 写成 <sparkle:…> 元素（旧版是 enclosure 属性），两种都认。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_archived_app
openssl=""
for o in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
  if command -v "$o" >/dev/null 2>&1 && "$o" pkey -help 2>&1 | grep -q pubout && "$o" version 2>/dev/null | grep -q "^OpenSSL 3"; then openssl=$o; break; fi
done
[ -n "$openssl" ] || skip "BLOCKED-工具：要 OpenSSL 3（brew install openssl@3）从 ed25519 种子推公钥；系统的 LibreSSL 不行"
work=$(mktemp -d "$RELEASE_TEST_OUT/r5.XXXX")
head -c 32 /dev/urandom > "$work/seed.bin"
base64 < "$work/seed.bin" > "$work/private.key"
# PKCS#8 的 ed25519 私钥 = 固定 16 字节头 + 32 字节种子；公钥 = SPKI DER 的最后 32 字节
{ printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'; cat "$work/seed.bin"; } > "$work/pkcs8.der"
pub=$("$openssl" pkey -inform DER -in "$work/pkcs8.der" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
[ ${#pub} = 44 ] && ok "从种子推出公钥（44 字符 base64）" || { fail "推不出公钥：[$pub]"; finish; }
ver=$(marketing_version)
# 包名 / DMG 名跟 R1 的产物走（W4-D：PlusMix.app → PlusMix-<版本>.dmg；同名 .md 是更新说明）
name=$(basename "$RELEASE_TEST_APP"); product=${name%.app}
# 带公钥的测试副本：改 Info.plist → ad-hoc 重签 → DMG
cp -R "$RELEASE_TEST_APP" "$work/$name"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $pub" "$work/$name/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL https://example.invalid/appcast.xml" "$work/$name/Contents/Info.plist"
assert_true "副本注入公钥后 ad-hoc 重签通过" "$REPO_ROOT/scripts/release/sign.sh" "$work/$name" --adhoc --entitlements "$REPO_ROOT/App/Switcher.entitlements" --extension-entitlements "$REPO_ROOT/CameraExtension/CameraExtension.entitlements"
mkdir -p "$work/arch"
assert_true "dmg.sh 出 DMG" "$REPO_ROOT/scripts/release/dmg.sh" "$work/$name" --out "$work/arch/$product-$ver.dmg"
printf '# %s\n\n- 测试用的更新说明\n' "$ver" > "$work/arch/$product-$ver.md"
bin=$("$REPO_ROOT/scripts/release/appcast.sh" --print-bin-dir 2>/dev/null)
[ -x "$bin/generate_appcast" ] && ok "找到 Sparkle 工具：$bin" || { fail "找不到 Sparkle 工具（--print-bin-dir 给的是 [$bin]）"; finish; }
if ! "$REPO_ROOT/scripts/release/appcast.sh" "$work/arch" --ed-key-file "$work/private.key" --download-url-prefix "https://example.invalid/downloads/" --embed-release-notes >"$RELEASE_TEST_OUT/r5-appcast.log" 2>&1; then
  fail "appcast.sh 退出非 0（$RELEASE_TEST_OUT/r5-appcast.log）"; tail -20 "$RELEASE_TEST_OUT/r5-appcast.log"; finish
fi
assert_file "$work/arch/appcast.xml" "appcast.xml"
xml=$(cat "$work/arch/appcast.xml")
assert_not_contains "$(cat "$RELEASE_TEST_OUT/r5-appcast.log")" "does not match" "generate_appcast 没抱怨公钥不配（Info.plist 里的公钥与私钥配对）"
assert_contains "$xml" 'sparkle:edSignature="' "enclosure 带 EdDSA 签名"
printf '%s' "$xml" | grep -qE "sparkle:shortVersionString(=\"|>)$ver(\"|<)" && ok "shortVersionString = $ver" || fail "shortVersionString 不是 $ver"
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$RELEASE_TEST_APP/Contents/Info.plist")
printf '%s' "$xml" | grep -qE "sparkle:version(=\"|>)$build(\"|<)" && ok "version = CFBundleVersion（$build）" || fail "version 不是 $build"
assert_contains "$xml" "url=\"https://example.invalid/downloads/$product-$ver.dmg\"" "下载地址用了前缀（$product-$ver.dmg）"
assert_contains "$xml" "sparkle:minimumSystemVersion>15.0<" "最低系统 15.0（从 LSMinimumSystemVersion 推）"
assert_contains "$xml" "sparkle:hardwareRequirements>arm64<" "硬件要求 arm64（从二进制架构推）"
assert_contains "$xml" "测试用的更新说明" "同名 .md 的更新说明嵌进了 appcast（--embed-release-notes）"
sig=$(printf '%s' "$xml" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -1)
assert_true "sign_update --verify 验签通过" "$bin/sign_update" --ed-key-file "$work/private.key" --verify "$work/arch/$product-$ver.dmg" "$sig"
cp "$work/arch/$product-$ver.dmg" "$work/x.dmg" && printf 'x' >> "$work/x.dmg"
assert_false "改一个字节后验签失败" "$bin/sign_update" --ed-key-file "$work/private.key" --verify "$work/x.dmg" "$sig"
head -c 32 /dev/urandom | base64 > "$work/other.key"
sig2=$("$bin/sign_update" --ed-key-file "$work/other.key" -p "$work/arch/$product-$ver.dmg" 2>/dev/null)
assert_false "别的私钥的签名用本钥匙验不过" "$bin/sign_update" --ed-key-file "$work/private.key" --verify "$work/arch/$product-$ver.dmg" "$sig2"
# 从标准输入读密钥（CI 的 secret 走法）
rm -f "$work/arch/appcast.xml"
assert_true "--ed-key-file - 从标准输入读私钥也能出 appcast" bash -c "cat '$work/private.key' | '$REPO_ROOT/scripts/release/appcast.sh' '$work/arch' --ed-key-file - --download-url-prefix https://example.invalid/downloads/ >/dev/null 2>&1 && grep -q 'sparkle:edSignature=' '$work/arch/appcast.xml'"
# 公钥为空的 App（R1 原样）出的 appcast 没有签名——记录这个行为（发布归档必须带 SPARKLE_PUBLIC_ED_KEY）
mkdir -p "$work/plain" && cp "$(dirname "$RELEASE_TEST_APP")/$product-$ver.dmg" "$work/plain/"
"$REPO_ROOT/scripts/release/appcast.sh" "$work/plain" --ed-key-file "$work/private.key" --download-url-prefix https://example.invalid/d/ >/dev/null 2>&1
assert_not_contains "$(cat "$work/plain/appcast.xml" 2>/dev/null)" 'sparkle:edSignature="' "SUPublicEDKey 为空的 App 出的 appcast 没有签名（所以归档必须注入公钥）"
assert_true "sparkle-keys.sh 无参数打印用法" bash -c "'$REPO_ROOT/scripts/release/sparkle-keys.sh' 2>&1 | grep -q generate"
rm -rf "$work"
finish
