#!/bin/bash
# R5：Sparkle appcast 生成（prompt 71 交付 2）：用临时账户名生成一对 EdDSA 密钥（进登录钥匙串，测完删），对 R1 的 DMG 出 appcast.xml，
#     检查 enclosure 的 sparkle:edSignature / sparkle:version / sparkle:shortVersionString / url 前缀，再用 sign_update --verify 验签。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_archived_app
acct="switcher-release-test-$$"
cleanup() { security delete-generic-password -s "https://sparkle-project.org" -a "$acct" >/dev/null 2>&1 || true; }
trap cleanup EXIT
keys="$REPO_ROOT/scripts/release/sparkle-keys.sh"
gen=$("$keys" generate --account "$acct" 2>&1) || { fail "sparkle-keys.sh generate 失败：$gen"; finish; }
pub=$("$keys" public --account "$acct" 2>/dev/null | tr -d '[:space:]')
[ ${#pub} -ge 40 ] && ok "生成了公钥（${#pub} 字符 base64）" || fail "公钥不像样：[$pub]"
assert_contains "$gen" "SUPublicEDKey" "generate 打印了 Info.plist 用法"
work=$(mktemp -d "$RELEASE_TEST_OUT/r5.XXXX")
ver=$(marketing_version)
cp "$(dirname "$RELEASE_TEST_APP")/Switcher-$ver.dmg" "$work/"
printf '# %s\n\n- 测试用的更新说明\n' "$ver" > "$work/Switcher-$ver.md"
if ! "$REPO_ROOT/scripts/release/appcast.sh" "$work" --account "$acct" --download-url-prefix "https://example.invalid/downloads/" >"$RELEASE_TEST_OUT/r5-appcast.log" 2>&1; then
  fail "appcast.sh 退出非 0（$RELEASE_TEST_OUT/r5-appcast.log）"; tail -20 "$RELEASE_TEST_OUT/r5-appcast.log"; finish
fi
assert_file "$work/appcast.xml" "appcast.xml"
xml=$(cat "$work/appcast.xml")
assert_contains "$xml" 'sparkle:edSignature="' "有 EdDSA 签名"
assert_contains "$xml" "sparkle:shortVersionString=\"$ver\"" "shortVersionString = $ver"
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$RELEASE_TEST_APP/Contents/Info.plist")
assert_contains "$xml" "sparkle:version=\"$build\"" "version = CFBundleVersion（$build）"
assert_contains "$xml" "url=\"https://example.invalid/downloads/Switcher-$ver.dmg\"" "下载地址用了前缀"
assert_contains "$xml" "sparkle:minimumSystemVersion" "带最低系统版本"
sig=$(printf '%s' "$xml" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -1)
bin=$("$REPO_ROOT/scripts/release/appcast.sh" --print-bin-dir 2>/dev/null)
assert_true "sign_update --verify 验签通过" "$bin/sign_update" --account "$acct" --verify "$work/Switcher-$ver.dmg" "$sig"
assert_false "改一个字节后验签失败" bash -c "cp '$work/Switcher-$ver.dmg' '$work/x.dmg' && printf 'x' >> '$work/x.dmg' && '$bin/sign_update' --account '$acct' --verify '$work/x.dmg' '$sig'"
# 导出私钥到文件、再用文件签：CI 用 secret 走的就是这条路
"$keys" export --account "$acct" --to "$work/private.key" >/dev/null 2>&1 && ok "私钥能导出到文件（CI secret 用）" || fail "私钥导出失败"
rm -f "$work/appcast.xml"
assert_true "用 --ed-key-file 也能出 appcast" "$REPO_ROOT/scripts/release/appcast.sh" "$work" --ed-key-file "$work/private.key" --download-url-prefix "https://example.invalid/downloads/"
rm -rf "$work"
finish
