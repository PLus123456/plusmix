#!/bin/bash
# R2：verify.sh 对没签名 / 被改过的包要报错（否则 spctl 那一步形同虚设）。用 R1 的 App 拷一份，去掉主二进制签名。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_archived_app
work=$(mktemp -d "$RELEASE_TEST_OUT/r2.XXXX")
cp -R "$RELEASE_TEST_APP" "$work/Switcher.app"
assert_true "拷贝出来的 App 先能过校验" "$REPO_ROOT/scripts/release/verify.sh" "$work/Switcher.app"
codesign --remove-signature "$work/Switcher.app/Contents/MacOS/Switcher"
assert_false "去掉主二进制签名后 verify.sh 退出非 0" "$REPO_ROOT/scripts/release/verify.sh" "$work/Switcher.app"
cp -R "$RELEASE_TEST_APP" "$work/Tampered.app"
echo "x" >> "$work/Tampered.app/Contents/Resources/Licenses/NDI/libndi_licenses.txt"
assert_false "改了包内资源后 verify.sh 退出非 0（--deep --strict 抓到）" "$REPO_ROOT/scripts/release/verify.sh" "$work/Tampered.app"
assert_false "--expect-notarized 在 ad-hoc 包上退出非 0" "$REPO_ROOT/scripts/release/verify.sh" "$RELEASE_TEST_APP" --expect-notarized
rm -rf "$work"
finish
