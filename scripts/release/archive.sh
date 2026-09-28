#!/bin/bash
# make archive（prompt 71 交付 1）：xcodebuild archive → 导出（Developer ID）/ 拷出（ad-hoc）→ 随包 libndi.dylib 与许可证 → 由内向外重签 →
# 校验（codesign / spctl）→ DMG → 公证 + staple（App 先、DMG 再）→ 终校验 → release-report.md。
# 发布构建必须用钉住的解析结果（prompt 71 第 6 条）：先 pin-deps.sh check，xcodebuild 带 -onlyUsePackageVersionsFromResolvedFile。
#
# 用法：archive.sh [--adhoc | --team TEAMID] [--identity "Developer ID Application: …"] [--skip-notarize] [--out DIR] [--no-dmg]
#                  [--feed-url URL] [--public-key BASE64] [--ndi-sdk DIR] [--verbose]
# 环境变量（参数优先）：DEVELOPMENT_TEAM、CODESIGN_IDENTITY、SPARKLE_FEED_URL、SPARKLE_PUBLIC_ED_KEY、NDI_SDK_DIR、公证凭据见 notarize.sh。
# 模式：有 Team ID + 钥匙串里有该 Team 的 "Developer ID Application" 身份 → Developer ID；否则 ad-hoc（公证标 BLOCKED-账号，其余步骤照走）。
# 产物：<out>/<版本>/{PlusMix.xcarchive, PlusMix.app, PlusMix-<版本>.dmg(.sha256), verify.json, release-report.md, logs/}
#       产物名 = project.yml 里 App target 的 PRODUCT_NAME（W4-D 改名后是 PlusMix；scheme / 工程仍叫代码名 Switcher），可执行名从包的 CFBundleExecutable 读。
set -uo pipefail
cd "$(dirname "$0")/../.."
repo=$PWD
S=scripts/release
mode=auto; team=${DEVELOPMENT_TEAM:-}; identity=${CODESIGN_IDENTITY:-}; skip_notarize=0; out=.build/release; make_dmg=1; verbose=0
feed=${SPARKLE_FEED_URL:-}; pubkey=${SPARKLE_PUBLIC_ED_KEY:-}; ndi_sdk=${NDI_SDK_DIR:-/Library/NDI SDK for Apple}
while [ $# -gt 0 ]; do
  case "$1" in
    --adhoc) mode=adhoc; shift ;;
    --team) mode=team; team=$2; shift 2 ;;
    --identity) identity=$2; shift 2 ;;
    --skip-notarize) skip_notarize=1; shift ;;
    --out) out=$2; shift 2 ;;
    --no-dmg) make_dmg=0; shift ;;
    --feed-url) feed=$2; shift 2 ;;
    --public-key) pubkey=$2; shift 2 ;;
    --ndi-sdk) ndi_sdk=$2; shift 2 ;;
    --verbose) verbose=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()    { red "[archive] $*"; exit 1; }

# ---- 0. 预检 ----
step "预检"
command -v xcodebuild >/dev/null || die "没有 xcodebuild"
ver=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9A-Za-z.-]*\)"\{0,1\}.*/\1/p' project.yml | head -1)
[ -n "$ver" ] || die "读不到 project.yml 的 MARKETING_VERSION"
# App target 的 PRODUCT_NAME（第一个 PRODUCT_NAME；扩展的在后面、等于它的 bundle id）→ .app / .xcarchive / DMG 的名字
product=$(sed -n 's/^[[:space:]]*PRODUCT_NAME:[[:space:]]*"\{0,1\}\([A-Za-z0-9][A-Za-z0-9._-]*\)"\{0,1\}.*/\1/p' project.yml | head -1)
[ -n "$product" ] || die "读不到 project.yml 的 PRODUCT_NAME（App target）"
identities=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)
if [ "$mode" = auto ]; then
  if [ -n "$team" ] && printf '%s' "$identities" | grep -q "($team)"; then mode=team; else
    mode=adhoc
    [ -n "$team" ] && yellow "[archive] 设了 DEVELOPMENT_TEAM=$team 但钥匙串里没有该 Team 的 Developer ID Application 身份，退成 ad-hoc"
  fi
fi
if [ "$mode" = team ]; then
  [ -n "$team" ] || die "--team 要给 Team ID"
  if [ -z "$identity" ]; then identity=$(printf '%s' "$identities" | grep "($team)" | head -1 | sed 's/.*"\(.*\)".*/\1/'); fi
  [ -n "$identity" ] || die "钥匙串里没有 Team $team 的 \"Developer ID Application\" 身份（security find-identity -v -p codesigning）：BLOCKED-账号"
  echo "模式：Developer ID（Team $team，身份 \"$identity\"）"
  [ -n "$pubkey" ] || yellow "[archive] SPARKLE_PUBLIC_ED_KEY 为空：这份构建不带自动更新（正式发布要给：scripts/release/sparkle-keys.sh public）"
  [ -n "$feed" ] || yellow "[archive] SPARKLE_FEED_URL 为空：这份构建不带自动更新"
else
  team=""; identity=""
  echo "模式：ad-hoc（没有 Developer ID 身份：公证 BLOCKED-账号，Gatekeeper 会拦；其余步骤照走）"
fi
ndi_linked_expected=0; [ -f "$ndi_sdk/include/Processing.NDI.Lib.h" ] && ndi_linked_expected=1
[ "$ndi_linked_expected" = 1 ] || yellow "[archive] 没装 NDI SDK（$ndi_sdk）：这份构建的 NDI 输入 / 输出是空实现，Stats 标 unavailable"

dir="$out/$ver"
if [ -d "$dir" ]; then
  if [ -f "$dir/release-report.md" ] || [ -z "$(ls -A "$dir")" ]; then rm -rf "$dir"; else die "$dir 已存在且不是本脚本的产物，不敢删"; fi
fi
mkdir -p "$dir/logs"
report="$dir/release-report.md"
rows=()
row() { rows+=("| $1 | $2 | $3 |"); }
t0=$(date +%s)
elapsed() { echo "$(( $(date +%s) - t0 )) s"; }
run_logged() { # $1 = 日志名，其余 = 命令
  local log="$dir/logs/$1.log"; shift
  if [ "$verbose" = 1 ]; then "$@" 2>&1 | tee "$log"; return "${PIPESTATUS[0]}"; else "$@" >"$log" 2>&1; fi
}

# ---- 1. 钉版本 ----
step "依赖钉版本检查"
$S/pin-deps.sh check || die "依赖钉法不一致：发布构建必须用钉住的解析结果（scripts/release/pin-deps.sh）"
row "依赖钉版本" "通过" "pin-deps.sh check"

# ---- 2. 生成工程 ----
step "make gen（DEVELOPMENT_TEAM=${team:-<空，ad-hoc>}）"
DEVELOPMENT_TEAM="$team" run_logged gen make gen || die "make gen 失败（$dir/logs/gen.log）"
$S/pin-deps.sh check >/dev/null || die "make gen 之后工作区 Package.resolved 与模板不一致"

# ---- 3. archive ----
step "xcodebuild archive（Release, arm64）"
archive="$dir/$product.xcarchive"
xcb=(xcodebuild archive -project Switcher.xcodeproj -scheme Switcher -configuration Release -destination "generic/platform=macOS"
     -archivePath "$archive" -derivedDataPath .build/DerivedData -onlyUsePackageVersionsFromResolvedFile
     ARCHS=arm64 ONLY_ACTIVE_ARCH=NO SPARKLE_FEED_URL="$feed" SPARKLE_PUBLIC_ED_KEY="$pubkey")
[ "$mode" = team ] && xcb+=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$team")
run_logged archive "${xcb[@]}" || { tail -40 "$dir/logs/archive.log"; die "xcodebuild archive 失败（$dir/logs/archive.log）"; }
[ -d "$archive/Products/Applications/$product.app" ] || die "归档里没有 $product.app（project.yml 的 PRODUCT_NAME 与归档产物对不上：$(ls "$archive/Products/Applications" 2>/dev/null | tr '\n' ' ')）"
row "xcodebuild archive" "通过" "$archive（$(elapsed)）"

# ---- 4. 导出 ----
step "导出"
app="$dir/$product.app"
if [ "$mode" = team ]; then
  plist="$dir/logs/exportOptions.plist"
  cat > "$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PL
  run_logged export xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$plist" -exportPath "$dir/export" -allowProvisioningUpdates \
    || { tail -40 "$dir/logs/export.log"; die "xcodebuild -exportArchive 失败（$dir/logs/export.log）"; }
  ditto "$dir/export/$product.app" "$app"
  row "导出" "通过" "developer-id（自动签名，含描述文件）"
else
  ditto "$archive/Products/Applications/$product.app" "$app"
  row "导出" "通过" "ad-hoc：直接拷 xcarchive 里的 App"
fi
bin="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
[ -f "$bin" ] || die "包里没有可执行：$bin"

# ---- 5. NDI 运行库 + 许可证 ----
step "随包的第三方运行库与许可证"
lic="$app/Contents/Resources/Licenses"
mkdir -p "$lic"
if otool -L "$bin" | grep -q "@rpath/libndi.dylib"; then
  [ -f "$ndi_sdk/lib/macOS/libndi.dylib" ] || die "主二进制链接了 libndi，但 $ndi_sdk/lib/macOS/libndi.dylib 不在：装 NDI SDK 或设 NDI_SDK_DIR"
  mkdir -p "$app/Contents/Frameworks" "$lic/NDI"
  cp "$ndi_sdk/lib/macOS/libndi.dylib" "$app/Contents/Frameworks/libndi.dylib"
  cp "$ndi_sdk/lib/macOS/libndi_licenses.txt" "$lic/NDI/libndi_licenses.txt"
  cp "$repo/THIRD_PARTY/NDI/NOTICE.md" "$lic/NDI/NOTICE.md" 2>/dev/null || true
  # 删掉指向 SDK 目录的 LC_RPATH：包内 @executable_path/../Frameworks 已经在前面，但发布包不该引用打包机的路径
  otool -l "$bin" | grep -A2 LC_RPATH | sed -n 's/^ *path \(.*\) (offset.*/\1/p' | grep "NDI SDK" | while IFS= read -r rp; do
    install_name_tool -delete_rpath "$rp" "$bin" 2>/dev/null || true
  done
  row "NDI 运行库" "通过" "libndi.dylib → Contents/Frameworks；许可证 → Resources/Licenses/NDI；主二进制删掉 SDK 目录 rpath"
else
  row "NDI 运行库" "跳过" "这份构建没链接 libndi（编译机没装 SDK）"
fi
# Sparkle 与其他 SwiftPM 依赖的许可证（发布包附带署名：Sparkle MIT、HaishinKit BSD-3、swift-* Apache-2.0…）
spk_src=$(ls -d .build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle 2>/dev/null | head -1)
if [ -n "$spk_src" ] && [ -f "$spk_src/LICENSE" ]; then mkdir -p "$lic/Sparkle"; cp "$spk_src/LICENSE" "$lic/Sparkle/LICENSE"; fi
for co in .build/DerivedData/SourcePackages/checkouts/*; do
  [ -d "$co" ] || continue; name=$(basename "$co")
  f=$(ls "$co"/LICENSE* "$co"/License* "$co"/COPYING* 2>/dev/null | head -1); [ -n "$f" ] || continue
  mkdir -p "$lic/$name"; cp "$f" "$lic/$name/$(basename "$f")"
done
for tp in THIRD_PARTY/*/; do
  name=$(basename "$tp"); [ -d "$tp" ] || continue
  for f in "$tp"/COPYING "$tp"/LICENSE* "$tp"/NOTICE.md; do [ -f "$f" ] && { mkdir -p "$lic/$name"; cp "$f" "$lic/$name/"; }; done
done
row "第三方许可证" "通过" "$(ls "$lic" | tr '\n' ' ')"

# ---- 6. 重签 ----
step "签名（由内向外）"
if [ "$mode" = team ]; then
  run_logged sign $S/sign.sh "$app" --identity "$identity" --entitlements App/Switcher-signed.entitlements --extension-entitlements CameraExtension/CameraExtension.entitlements \
    || { cat "$dir/logs/sign.log"; die "签名失败"; }
  row "签名" "通过" "Developer ID：\"$identity\"，硬化运行时 + 时间戳；扩展 / Sparkle / libndi 同一身份"
else
  run_logged sign $S/sign.sh "$app" --adhoc --entitlements App/Switcher.entitlements --extension-entitlements CameraExtension/CameraExtension.entitlements \
    || { cat "$dir/logs/sign.log"; die "签名失败"; }
  row "签名" "通过（ad-hoc）" "没有 Developer ID：Gatekeeper 会拦，虚拟摄像头扩展装不上（BLOCKED-签名）"
fi

# ---- 7. 校验 ----
step "校验 App"
$S/verify.sh "$app" --json "$dir/verify.json" | tee "$dir/logs/verify-app.log" || die "App 校验失败"
sp=$(python3 -c "import json;d=json.load(open('$dir/verify.json'));print(d.get('spctl_output',''))")
row "spctl -a -vv（App）" "$( [ "$mode" = team ] && echo 见公证后 || echo 'rejected（预期：ad-hoc）')" "$sp"

# ---- 8. 公证 App（先 App 后 DMG，都 staple）----
notarized=0
if [ "$mode" = team ] && [ "$skip_notarize" = 0 ]; then
  step "公证 App"
  if $S/notarize.sh "$app" 2>&1 | tee "$dir/logs/notarize-app.log"; then notarized=1; row "公证 App" "通过" "已 staple"; else
    code=${PIPESTATUS[0]}; [ "$code" = 3 ] && { row "公证 App" "BLOCKED-账号" "没有公证凭据（notarize.sh 文件头）"; } || die "App 公证失败（$dir/logs/notarize-app.log）"; fi
elif [ "$mode" = team ]; then row "公证 App" "跳过" "--skip-notarize"
else row "公证 App" "BLOCKED-账号" "没有 Developer ID / Apple Developer Program 账号；解锁 = 付费账号 + Team ID + notarytool 凭据"; fi

# ---- 9. DMG ----
if [ "$make_dmg" = 1 ]; then
  step "DMG"
  dmg="$dir/$product-$ver.dmg"
  if [ "$mode" = team ]; then $S/dmg.sh "$app" --out "$dmg" --identity "$identity" || die "DMG 失败"; else $S/dmg.sh "$app" --out "$dmg" || die "DMG 失败"; fi
  row "DMG" "通过" "$(basename "$dmg")（$(du -h "$dmg" | cut -f1 | tr -d ' ')，sha256 见同名 .sha256）"
  if [ "$notarized" = 1 ]; then
    step "公证 DMG"
    $S/notarize.sh "$dmg" 2>&1 | tee "$dir/logs/notarize-dmg.log" && row "公证 DMG" "通过" "已 staple" || die "DMG 公证失败"
  elif [ "$mode" = adhoc ]; then row "公证 DMG" "BLOCKED-账号" "同上"; else row "公证 DMG" "跳过" "同上"; fi
  step "校验 DMG"
  if [ "$notarized" = 1 ]; then $S/verify.sh "$dmg" --expect-notarized --json "$dir/verify.json" | tee "$dir/logs/verify-dmg.log" || die "DMG 终校验失败（要求已公证）"
  else $S/verify.sh "$dmg" --json "$dir/verify.json" | tee "$dir/logs/verify-dmg.log" || die "DMG 校验失败"; fi
  sp=$(python3 -c "import json;d=json.load(open('$dir/verify.json'));print(d.get('spctl_output',''))")
  row "spctl -a -vv（DMG 里的 App）" "$( [ "$notarized" = 1 ] && echo accepted || echo "$( [ "$mode" = adhoc ] && echo 'rejected（预期：ad-hoc）' || echo '未公证')")" "$sp"
else
  row "DMG" "跳过" "--no-dmg"
fi

# ---- 10. 报告 ----
step "报告"
{
  echo "# 发布归档报告：$product $ver"
  echo
  echo "- 时间：$(date '+%Y-%m-%d %H:%M:%S')；用时 $(elapsed)；机器：$(sysctl -n hw.model 2>/dev/null) / macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))；Xcode $(xcodebuild -version | head -1 | sed 's/Xcode //')"
  echo "- 提交：$(git rev-parse --short HEAD 2>/dev/null)$( [ -n "$(git status --porcelain 2>/dev/null)" ] && echo '（工作树有未提交改动）')；分支 $(git symbolic-ref --short -q HEAD 2>/dev/null)"
  echo "- 模式：$( [ "$mode" = team ] && echo "Developer ID（Team $team）" || echo 'ad-hoc（BLOCKED-账号）')；Sparkle feed：${feed:-<空：不带更新>}；公钥：$( [ -n "$pubkey" ] && echo 已注入 || echo '<空>')"
  echo "- 产物：\`$dir/\`（$product.xcarchive、$product.app、$( [ "$make_dmg" = 1 ] && echo "$product-$ver.dmg + .sha256、" )verify.json、logs/）"
  echo
  echo "| 步骤 | 结果 | 说明 |"; echo "|---|---|---|"
  printf '%s\n' "${rows[@]}"
  echo
  echo "## verify.json"; echo; echo '```json'; cat "$dir/verify.json"; echo '```'
  echo
  echo "## 干净机器验证（人工，docs/release/README.md §4）"; echo
  echo "- [ ] 新建 macOS 用户账户，拷 DMG 过去，拖到 /Applications，首次启动$( [ "$mode" = team ] && echo '无 Gatekeeper 拦截' || echo '：ad-hoc 构建会被拦（右键 → 打开），正式版不会')"
  echo "- [ ] 输出 → 虚拟摄像头 → 安装 / 激活扩展，系统设置里允许$( [ "$mode" = adhoc ] && echo '（ad-hoc：BLOCKED-签名）')"
  echo "- [ ] 偏好设置 → 更新 → 检查更新…（本地 appcast：docs/release/sparkle.md §5）"
} > "$report"
green "[archive] 完成：$report"
cat "$report" | sed -n '1,30p'
