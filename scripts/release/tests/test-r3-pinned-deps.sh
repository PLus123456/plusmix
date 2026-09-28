#!/bin/bash
# R3：依赖钉版本一致（prompt 71 第 6 条）：入库的五份 Package.resolved 与 scripts/xcode-workspace-Package.resolved 对同一依赖钉同一版本 / 提交，
#     swift-collections 不是 1.7.x（macOS 26.6.2 的运行时没有 _swift_initBorrow）；故意改坏一份时 check 要红。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
pin="$REPO_ROOT/scripts/release/pin-deps.sh"
assert_true "pin-deps.sh check 在仓库上通过" "$pin" check
out=$("$pin" list 2>&1)
assert_contains "$out" "swift-collections" "list 列出了 swift-collections"
sc=$(printf '%s\n' "$out" | grep "swift-collections" | head -1)
assert_not_contains "$sc" "1.7." "swift-collections 没钉到 1.7.x"
# 坏一份：把模板里 swift-collections 改成 1.7.0
scratch=$(mktemp -d "$RELEASE_TEST_OUT/r3.XXXX")
mkdir -p "$scratch/scripts" "$scratch/Packages/SwitcherControl" "$scratch/Tools/switcher-headless"
cp "$REPO_ROOT/scripts/xcode-workspace-Package.resolved" "$scratch/scripts/"
cp "$REPO_ROOT/Packages/SwitcherControl/Package.resolved" "$scratch/Packages/SwitcherControl/"
cp "$REPO_ROOT/Tools/switcher-headless/Package.resolved" "$scratch/Tools/switcher-headless/"
python3 - "$scratch/Packages/SwitcherControl/Package.resolved" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for pin in d["pins"]:
    if pin["identity"] == "swift-collections":
        pin["state"]["version"] = "1.7.0"; pin["state"]["revision"] = "0" * 40
json.dump(d, open(p, "w"), indent=2)
PY
assert_false "一份钉到 1.7.0 时 check 退出非 0" "$pin" check --root "$scratch"
msg=$("$pin" check --root "$scratch" 2>&1 || true)
assert_contains "$msg" "swift-collections" "错误信息点名 swift-collections"
rm -rf "$scratch"
# 工作区（生成物）的 Package.resolved 若存在，必须与模板一致（make gen 会拷；xcodebuild 不该改它）
ws="$REPO_ROOT/Switcher.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ -f "$ws" ]; then
  assert_true "工作区 Package.resolved 与模板同一套（sync 后）" "$pin" check
else
  note "没有生成工程，跳过工作区一致性"
fi
finish
