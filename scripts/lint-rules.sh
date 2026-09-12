#!/bin/bash
# 仓库规则 lint（make lint 的一部分）。三项检查，任一失败退出 1：
#   1. 禁词：产品文案、类型名、UI 字符串里不许出现竞品名（docs/plan/prompts/00-通用前言.md 铁律 6）。
#      扫描代码与资源树：Packages/ App/ Tools/ CameraExtension/ project.yml。
#      不扫 docs/（规格和 UI 稿本来就提到它们）、reports/、scripts/、根目录 .md。
#      唯一例外：模块名 VMixCompat（落地方案 §2 指定的第三方 API 兼容层 target，默认不编译进产品）。
#      这个 token 本身允许出现；除此之外任何形式（字符串、注释、其他标识符）都不行。
#   2. 版本号一致：project.yml 的 MARKETING_VERSION == SwitcherContracts/Version.swift 的 SwitcherVersion.current。
#   3. 包骨架约束：每个 Package.swift 必须是 tools-version 6.0、swiftLanguageModes [.v6]、平台 macOS 15。
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# ---------- 1. 禁词 ----------
scan_roots=()
for r in Packages App Tools CameraExtension project.yml; do
  [ -e "$r" ] && scan_roots+=("$r")
done
grep_common=(-rIn --exclude-dir=.build --exclude-dir=.swiftpm --exclude-dir='*.xcodeproj' --exclude-dir=DerivedData)

# 把允许的 token 抹掉再匹配：这样 "VMixCompat" 过，"vMix API" / "VMixCompatServer 之外的 vmix 变体" 不过。
allowed_token='VMixCompat'
hits=$( { grep "${grep_common[@]}" -i 'vmix' "${scan_roots[@]}" 2>/dev/null || true; } \
        | sed "s/${allowed_token}//g" | grep -i 'vmix' || true )
hits2=$( { grep "${grep_common[@]}" -w 'OBS' "${scan_roots[@]}" 2>/dev/null || true; } )
hits3=$( { grep "${grep_common[@]}" -i -E 'obs[-_ ]?studio|obsproject' "${scan_roots[@]}" 2>/dev/null || true; } )
all_hits=$(printf '%s\n%s\n%s\n' "$hits" "$hits2" "$hits3" | sed '/^$/d' | sort -u)
if [ -n "$all_hits" ]; then
  red "[lint-rules] 禁词：以下位置出现了竞品名（铁律 6）。改文案 / 改名，或写提案问我。"
  printf '%s\n' "$all_hits" | sed 's/^/    /'
  status=1
else
  green "[lint-rules] 禁词检查通过（扫描：${scan_roots[*]}）"
fi

# ---------- 2. 版本号一致 ----------
yml_ver=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' project.yml | head -1)
swift_ver=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Packages/SwitcherCore/Sources/SwitcherContracts/Version.swift | head -1)
if [ -z "$yml_ver" ] || [ -z "$swift_ver" ]; then
  red "[lint-rules] 版本号：读不到 MARKETING_VERSION（project.yml）或 SwitcherVersion.current（Version.swift）"
  status=1
elif [ "$yml_ver" != "$swift_ver" ]; then
  red "[lint-rules] 版本号不一致：project.yml=$yml_ver，Version.swift=$swift_ver（两处都归 G5 改）"
  status=1
else
  green "[lint-rules] 版本号一致：$yml_ver"
fi

# ---------- 3. 包骨架约束 ----------
pkg_bad=0
for m in Packages/*/Package.swift Tools/*/Package.swift; do
  [ -f "$m" ] || continue
  head -1 "$m" | grep -q '^// swift-tools-version: *6\.0' || { red "[lint-rules] $m：首行必须是 // swift-tools-version: 6.0"; pkg_bad=1; }
  grep -q 'swiftLanguageModes: *\[\.v6\]' "$m" || { red "[lint-rules] $m：必须声明 swiftLanguageModes: [.v6]"; pkg_bad=1; }
  grep -q '\.macOS(\.v15)' "$m" || { red "[lint-rules] $m：platforms 必须是 .macOS(.v15)"; pkg_bad=1; }
done
if [ "$pkg_bad" = 0 ]; then green "[lint-rules] Package.swift 约束通过（tools 6.0 / 语言模式 v6 / macOS 15）"; else status=1; fi

exit $status
