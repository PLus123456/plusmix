#!/bin/bash
# R11：正式 bundle id 一键切换（prompt 71 第 7 条）：set-bundle-id.sh --list 列出所有要改的文件；在临时副本上真改一次后，
#      旧前缀一处不剩，新前缀出现在 project.yml、扩展 Info.plist / entitlements、VirtualCameraConstants、Stream Deck manifest（目录也改名）；仓库本体不动。
#      当前前缀从仓库读、不写死（W4-B2：G5 按用户 2026-09-28 的裁定切到 com.plusmix 后，原来写死的 com.example 让本测试必红；切换前后、再切一次都该绿）：
#      App 前缀 = project.yml 的 bundleIdPrefix，Stream Deck 前缀 = 插件 manifest.json 顶层 UUID 去掉 .switcher——与 set-bundle-id.sh 读的
#      PRODUCT_BUNDLE_IDENTIFIER / 目录名不是同一处，--check 报的和这两处对不上也会红。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
s="$REPO_ROOT/scripts/release/set-bundle-id.sh"
before=$(cd "$REPO_ROOT" && find project.yml CameraExtension Packages/SwitcherOutputs/Sources/VirtualCamera/Shared Tools/streamdeck-plugin docs/integrations -type f -not -path '*/node_modules/*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256)
cur=$("$s" --check 2>&1)
app_prefix=$(sed -n 's/^ *bundleIdPrefix: *\([^ #]*\).*/\1/p' "$REPO_ROOT/project.yml" | head -1)
manifest=$(ls -d "$REPO_ROOT"/Tools/streamdeck-plugin/*.sdPlugin/manifest.json 2>/dev/null | head -1)
sd_uuid=""
[ -n "$manifest" ] && sd_uuid=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["UUID"])' "$manifest" 2>/dev/null)
sd_prefix=${sd_uuid%.switcher}
sd_dir=${manifest%/manifest.json}; sd_dir=${sd_dir#"$REPO_ROOT"/}
[ -n "$app_prefix" ] && ok "project.yml 的 bundleIdPrefix = ${app_prefix}" || fail "读不到 project.yml 的 bundleIdPrefix"
[ -n "$sd_uuid" ] && [ "$sd_prefix" != "$sd_uuid" ] && ok "Stream Deck manifest 的 UUID = ${sd_uuid}（${sd_dir}）" || fail "读不到 Tools/streamdeck-plugin/*.sdPlugin/manifest.json 的顶层 UUID（<前缀>.switcher）"
assert_contains "$cur" "App / 扩展 bundle id 前缀：${app_prefix//./\\.}（" "--check 报出当前 App 前缀 ${app_prefix}（= project.yml 的 bundleIdPrefix）"
assert_contains "$cur" "Stream Deck 插件前缀：[[:space:]]*${sd_prefix//./\\.}（" "--check 报出当前 Stream Deck 前缀 ${sd_prefix}（= manifest 的 UUID 前缀）"
files=$("$s" --list)
for f in project.yml CameraExtension/Info.plist CameraExtension/CameraExtension.entitlements \
         Packages/SwitcherOutputs/Sources/VirtualCamera/Shared/VirtualCameraConstants.swift \
         "$sd_dir/manifest.json" Tools/streamdeck-plugin/package.json Tools/streamdeck-plugin/README.md \
         "$sd_dir/bin/plugin.js" docs/integrations/stream-deck.md App/Sources/AppController.swift; do
  assert_contains "$files" "$f" "--list 含 $f"
done
scratch=$(mktemp -d "$RELEASE_TEST_OUT/r11.XXXX")
while IFS= read -r f; do [ -n "$f" ] || continue; mkdir -p "$scratch/$(dirname "$f")"; cp "$REPO_ROOT/$f" "$scratch/$f"; done <<< "$files"
# Stream Deck 插件目录整体拷（要改目录名）
rm -rf "$scratch/Tools/streamdeck-plugin"; mkdir -p "$scratch/Tools"; cp -R "$REPO_ROOT/Tools/streamdeck-plugin" "$scratch/Tools/streamdeck-plugin"; rm -rf "$scratch/Tools/streamdeck-plugin/node_modules"
assert_true "在副本上切到 io.example-domain" "$s" io.example-domain --root "$scratch"
left=$(grep -rl -e "${app_prefix//./\\.}\.switcher" -e "${sd_prefix//./\\.}\.switcher" "$scratch" 2>/dev/null || true)
assert_eq "$left" "" "副本里旧前缀（${app_prefix}.switcher / ${sd_prefix}.switcher）一处不剩"
assert_contains "$(cat "$scratch/project.yml")" "PRODUCT_BUNDLE_IDENTIFIER: io.example-domain.switcher" "project.yml 的 App bundle id"
assert_contains "$(cat "$scratch/project.yml")" "io.example-domain.switcher.camera-extension" "project.yml 的扩展 bundle id"
assert_contains "$(cat "$scratch/CameraExtension/Info.plist")" "io.example-domain.switcher.camera<" "扩展 mach service 名"
assert_contains "$(cat "$scratch/Packages/SwitcherOutputs/Sources/VirtualCamera/Shared/VirtualCameraConstants.swift")" '"io.example-domain.switcher.camera-extension"' "VirtualCameraConstants.extensionBundleIdentifier"
assert_file "$scratch/Tools/streamdeck-plugin/io.example-domain.switcher.sdPlugin/manifest.json" "Stream Deck 插件目录改名"
assert_contains "$(cat "$scratch/Tools/streamdeck-plugin/io.example-domain.switcher.sdPlugin/manifest.json")" '"UUID": "io.example-domain.switcher.cut"' "动作 UUID 一起换"
assert_true "副本上 --check 报新前缀" bash -c "'$s' --check --root '$scratch' | grep -q io.example-domain"
# 仓库本体没动（校验和前后一致；工作树本来可能有未提交改动，不能用 git diff）
after=$(cd "$REPO_ROOT" && find project.yml CameraExtension Packages/SwitcherOutputs/Sources/VirtualCamera/Shared Tools/streamdeck-plugin docs/integrations -type f -not -path '*/node_modules/*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256)
assert_eq "$after" "$before" "仓库本体的校验和前后一致"
rm -rf "$scratch"
finish
