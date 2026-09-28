#!/bin/bash
# 把签好名的 Switcher.app 打成 DMG（prompt 71 交付 1）：临时目录放 App + Applications 链接 → hdiutil create（UDZO 压缩）→（有身份就）签名 → sha256。
# 用法：dmg.sh <Switcher.app> --out <路径.dmg> [--volname NAME] [--identity "Developer ID Application: …"]
set -uo pipefail
app=""; out=""; volname=""; identity=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --volname) volname=$2; shift 2 ;;
    --identity) identity=$2; shift 2 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    -*) echo "不认识的参数：$1" >&2; exit 2 ;;
    *) app=$1; shift ;;
  esac
done
[ -d "$app" ] && [ -n "$out" ] || { echo "用法：dmg.sh <Switcher.app> --out <路径.dmg> [--volname NAME] [--identity ID]" >&2; exit 2; }
ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo "")
[ -n "$volname" ] || volname="Switcher ${ver:-}"
stage=$(mktemp -d /tmp/switcher-dmg.XXXX); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/root"
# ditto 保留扩展属性 / 符号链接 / 签名
ditto "$app" "$stage/root/$(basename "$app")"
ln -s /Applications "$stage/root/Applications"
rm -f "$out"
mkdir -p "$(dirname "$out")"
hdiutil create -quiet -volname "$volname" -srcfolder "$stage/root" -ov -format UDZO -fs HFS+ "$out" || { echo "[dmg] hdiutil create 失败" >&2; exit 1; }
hdiutil verify -quiet "$out" || { echo "[dmg] hdiutil verify 失败" >&2; exit 1; }
if [ -n "$identity" ]; then codesign --force --sign "$identity" --timestamp "$out" || { echo "[dmg] DMG 签名失败" >&2; exit 1; }; fi
(cd "$(dirname "$out")" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256")
echo "[dmg] $out（$(du -h "$out" | cut -f1 | tr -d ' ')）$( [ -n "$identity" ] && echo '已签名' || echo '未签名（没有身份）')"
