#!/bin/bash
# R4：发布构建用的是钉住的解析结果——归档出来的主二进制与 frameprobe 不引用只有 Swift 6.4 运行时才有的符号（_swift_initBorrow 等，
#     issues W3C2-g5-swift-collections-1.7-dyld-crash / W3E2-…-unpinned-deps-swift-runtime）。这里只能查已知的坏符号；macOS 15 / 26 上真起一次是人工项。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_archived_app
pin="$REPO_ROOT/scripts/release/pin-deps.sh"
bin="$RELEASE_TEST_APP/Contents/MacOS/Switcher"
assert_true "主二进制不引用 _swift_initBorrow 一类符号" "$pin" verify-runtime "$bin"
for f in "$RELEASE_TEST_APP"/Contents/Frameworks/*.dylib; do
  [ -f "$f" ] || continue
  assert_true "$(basename "$f") 不引用新运行时符号" "$pin" verify-runtime "$f"
done
fp=$(ls "$REPO_ROOT"/Tools/frameprobe/.build/release/frameprobe "$REPO_ROOT"/Tools/frameprobe/.build/debug/frameprobe 2>/dev/null | head -1)
if [ -n "$fp" ]; then assert_true "frameprobe 不引用新运行时符号" "$pin" verify-runtime "$fp"; else note "没编过 frameprobe，跳过"; fi
# 反例：一个引用了 _swift_initBorrow 的假 Mach-O 没法凭空造，退而查脚本的坏符号表本身
assert_true "坏符号表里有 _swift_initBorrow" grep -q "_swift_initBorrow" "$REPO_ROOT/scripts/release/pin-deps.sh"
finish
