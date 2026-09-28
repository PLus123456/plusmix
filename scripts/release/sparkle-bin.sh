#!/bin/bash
# 找 Sparkle 随 SwiftPM 产物带的命令行工具（generate_keys / sign_update / generate_appcast）。被 sparkle-keys.sh / appcast.sh source。
# 顺序：SPARKLE_BIN 环境变量 → 本仓库 .build/DerivedData 里解析出来的包 → ~/Library/Developer/Xcode/DerivedData 里任何一份 → 报错。
# 工具版本必须与 App 链接的 Sparkle 同版本（project.yml exactVersion），所以优先本仓库的解析结果；make gen build-app 就会把包解析下来。
sparkle_bin_dir() {
  local repo; repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then printf '%s' "$SPARKLE_BIN"; return 0; fi
  local d="$repo/.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
  if [ -x "$d/generate_appcast" ]; then printf '%s' "$d"; return 0; fi
  local found
  found=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)
  if [ -n "$found" ] && [ -x "$found/generate_appcast" ]; then printf '%s' "$found"; return 0; fi
  echo "[sparkle] 找不到 Sparkle 的命令行工具（generate_appcast）。先 make gen build-app 让 Xcode 解析 Sparkle 包，或设 SPARKLE_BIN=<Sparkle 发行包的 bin 目录>" >&2
  return 1
}
