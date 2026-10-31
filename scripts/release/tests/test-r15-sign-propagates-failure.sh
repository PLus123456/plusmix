#!/bin/bash
# R15：sign.sh 重签失败要退出非 0、原签名不动（Codex 2026-10-22 N13 / CT02，G12 修）；codesign 退出 0 但签上去的不是请求的身份也要退出非 0；
#      --adhoc 的正常路径照旧退出 0 且 Signature=adhoc。用 /usr/bin/true 造一个最小 App（reports/codex-bug-audit-20261022-tests/reproduce-sign.py.txt 的法子），
#      不碰 R1 的产物、不需要签名身份（真身份的成功路径在这台机器上 BLOCKED-账号，只记一句）。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
sign="$REPO_ROOT/scripts/release/sign.sh"
work=$(mktemp -d "$RELEASE_TEST_OUT/r15.XXXX")
app="$work/SignProbe.app"
mkdir -p "$app/Contents/MacOS"
cp /usr/bin/true "$app/Contents/MacOS/SignProbe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>invalid.g12.sign-probe</string>
<key>CFBundleExecutable</key><string>SignProbe</string>
<key>CFBundleName</key><string>SignProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app" 2>/dev/null || { fail "造不出 ad-hoc 签名的最小 App"; finish; }
cdhash() { /usr/bin/codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
before=$(cdhash "$app")
if [ -n "$before" ]; then ok "最小 App 先有 ad-hoc 签名（CDHash $before）"; else fail "读不到最小 App 的 CDHash"; fi

# 1. 不存在的身份：codesign 报 no identity found → 脚本退出非 0、不报"完成"、原签名不动（修前：退出 0 + "完成：Signature=adhoc"）
out=$("$sign" "$app" --identity "G12 definitely missing identity" 2>&1); code=$?
if [ "$code" != 0 ]; then ok "不存在的身份：退出码 $code（非 0）"; else fail "不存在的身份：退出 0（N13 的现象）"; fi
assert_contains "$out" "codesign 失败" "错误原因写明是 codesign 失败"
assert_not_contains "$out" "完成：" "没有报完成"
assert_eq "$(cdhash "$app")" "$before" "原 ad-hoc 签名不动（CDHash）"

# 2. --verbose 分支同样不吞退出码
out=$("$sign" "$app" --identity "G12 definitely missing identity" --verbose 2>&1); code=$?
if [ "$code" != 0 ]; then ok "--verbose 分支：退出码 $code（非 0）"; else fail "--verbose 分支：退出 0"; fi
assert_eq "$(cdhash "$app")" "$before" "--verbose 分支：原签名不动（CDHash）"

# 3. codesign 退出 0 但没签上请求的身份：PATH 里放一个假 codesign（遇 --sign 直接退 0 不签，其他转给真的），脚本要靠 codesign -dvv 的核对抓出来
mkdir -p "$work/bin"
cat > "$work/bin/codesign" <<'FAKE'
#!/bin/bash
for a in "$@"; do [ "$a" = "--sign" ] && exit 0; done
exec /usr/bin/codesign "$@"
FAKE
chmod +x "$work/bin/codesign"
out=$(PATH="$work/bin:$PATH" "$sign" "$app" --identity "Developer ID Application: Nobody (G12G12G12G)" 2>&1); code=$?
if [ "$code" != 0 ]; then ok "codesign 退出 0 但签名仍是 ad-hoc：退出码 $code（非 0）"; else fail "签上去的不是请求的身份仍报成功"; fi
assert_contains "$out" "仍是 ad-hoc" "错误原因写明签完仍是 ad-hoc"
assert_not_contains "$out" "完成：" "身份不符时没有报完成"

# 4. 正常路径：--adhoc 退出 0、完成行写 Signature=adhoc、整包 --deep --strict 验得过
out=$("$sign" "$app" --adhoc 2>&1); code=$?
assert_eq "$code" 0 "--adhoc 退出码"
assert_contains "$out" "完成：Signature=adhoc" "完成行写 Signature=adhoc"
assert_true "签完整包 --deep --strict 验得过" /usr/bin/codesign --verify --deep --strict "$app"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q ' 0 valid identities'; then
  note "BLOCKED-账号：机器上 0 个签名身份，真身份的成功路径（Authority 与请求一致）没测，只测了假 codesign 那一段"
else
  note "机器上有签名身份：真身份的成功路径由 archive.sh（team 模式）走到"
fi
rm -rf "$work"
finish
