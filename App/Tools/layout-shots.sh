#!/bin/bash
# 检查点 1 的截图（W6-A，prompt 144 交付 11）。照 docs/ui-study/README.md"想让 App 在隔离环境里跑起来截图"那一条：
#   1. 拷一份构建好的 PlusMix.app，主 App 和虚拟摄像头扩展的 bundle id 一起改（窗口位置存在标准 defaults 里；扩展的 id 要以主 App 的 id 开头，
#      不然过不了嵌入校验），重签 ad-hoc；
#   2. XCTestConfigurationFilePath=/dev/null 进测试宿主模式：独立 defaults（按构建位置分开）、空节目、不恢复上次节目、API 端口 0、音频设备空；
#   3. 直接执行二进制（不用 open：截屏权限跟着启动它的终端），App 里的 LayoutShotTour 按清单一张张摆好、用 screencapture -l 只截自己的窗口，
#      写 shots.tsv 后自己退出。不用示意图代替。
# 用法：App/Tools/layout-shots.sh [输出目录，默认 reports/w6-app-layout/shots] [PlusMix.app 路径，默认 .build/DerivedData 里 Debug 那份]
# 先 make build-app（或 make gen && make build-app）。截图时 App 不在前台：工具条是非活动窗口的暗色（G7 / W4-C3 同样）。
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-reports/w6-app-layout/shots}"
app="${2:-.build/DerivedData/Build/Products/Debug/PlusMix.app}"
bundle_id="com.plusmix.switcher.layoutshots"
[ -d "$app" ] || { echo "找不到 ${app}：先 make build-app" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/plusmix-shots.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp -R "$app" "$work/PlusMix.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$work/PlusMix.app/Contents/Info.plist"
for ext in "$work/PlusMix.app/Contents/Library/SystemExtensions/"*.systemextension; do
  [ -d "$ext" ] || continue
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id.camera-extension" "$ext/Contents/Info.plist"
done
codesign --force --deep --sign - "$work/PlusMix.app" >/dev/null 2>&1
mkdir -p "$out"
rm -f "$out"/*.png "$out"/shots.tsv
abs_out="$(cd "$out" && pwd)"
echo "截图 → $abs_out"
# macOS 没有 timeout：perl alarm 兜底（G7 的做法），十分钟没截完就停
XCTestConfigurationFilePath=/dev/null SWITCHER_LAYOUT_SHOTS="$abs_out" \
  perl -e 'alarm shift; exec @ARGV' 600 "$work/PlusMix.app/Contents/MacOS/PlusMix" -ApplePersistenceIgnoreState YES || true
count=$(ls "$abs_out"/*.png 2>/dev/null | wc -l | tr -d ' ')
echo "截了 $count 张；清单 $abs_out/shots.tsv"
defaults delete "$bundle_id" >/dev/null 2>&1 || true   # 隔离运行留下的窗口位置等，不留在用户机器上
[ "$count" -gt 0 ]
