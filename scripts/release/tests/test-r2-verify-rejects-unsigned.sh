#!/bin/bash
# R2：verify.sh 对没签名 / 被改过的包要报错（否则 spctl 那一步形同虚设）。用 R1 的 App 拷一份，去掉主二进制签名。
# 包名与可执行名从 R1 的产物读（W4-D：PlusMix.app / Contents/MacOS/PlusMix），不写死。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_archived_app
name=$(basename "$RELEASE_TEST_APP")
exe=$(app_executable "$RELEASE_TEST_APP")
work=$(mktemp -d "$RELEASE_TEST_OUT/r2.XXXX")
cp -R "$RELEASE_TEST_APP" "$work/$name"
assert_true "拷贝出来的 App 先能过校验" "$REPO_ROOT/scripts/release/verify.sh" "$work/$name"
codesign --remove-signature "$work/$name/Contents/MacOS/$exe"
assert_false "去掉主二进制签名后 verify.sh 退出非 0" "$REPO_ROOT/scripts/release/verify.sh" "$work/$name"
cp -R "$RELEASE_TEST_APP" "$work/Tampered.app"
echo "x" >> "$work/Tampered.app/Contents/Resources/Licenses/NDI/libndi_licenses.txt"
assert_false "改了包内资源后 verify.sh 退出非 0（--deep --strict 抓到）" "$REPO_ROOT/scripts/release/verify.sh" "$work/Tampered.app"
assert_false "--expect-notarized 在 ad-hoc 包上退出非 0" "$REPO_ROOT/scripts/release/verify.sh" "$RELEASE_TEST_APP" --expect-notarized
rm -rf "$work"
finish
