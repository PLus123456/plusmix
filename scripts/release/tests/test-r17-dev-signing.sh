#!/bin/bash
# R17：开发签名真签一次（W4-B3，prompt 141 交付 4）。钥匙串里有 Apple Development 身份（Personal Team 也行）时，按 make build-app 的别名路径
#      （xcodebuild 命令行盖 DEVELOPMENT_TEAM=<Team> SWITCHER_DEV_SIGN=1，不重新生成工程）build-for-testing 一次，然后查：
#      App：codesign -dvv 的 TeamIdentifier = 给的 Team、flags 含 runtime、Authority 是 Apple Development；权限表有 camera / audio-input /
#           cs.disable-library-validation、没有 system-extension.install；指定要求（designated requirement）按证书写、不含 cdhash
#           ——TCC 按它记授权，所以重编译不重问（ad-hoc 的指定要求就是 cdhash，每次编译都变）；codesign --verify --deep --strict 过；
#      扩展：同一 Team、沙盒 + app group <Team>.com.plusmix.switcher.camera；测试包：同一 Team、不带受限权限；
#      App 起来 4 秒不崩（硬化运行时开着、库校验关掉之后，SDK 目录里 NDI 签的 libndi 能加载——没关库校验 dyld 当场拒，G13 §4.4）。
# 跳过（退出 77，BLOCKED-签名）：钥匙串里没有 Apple Development 身份（CI / 没登 Apple ID 的机器）；CI 上默认不跑（runner 没有 GUI 会话时
#      登录钥匙串锁着、私钥授权框没人点会挂住；RELEASE_TEST_DEV_SIGN=1 强制跑）；签名时钥匙串锁着（errSecInternalComponent）。
# Team：RELEASE_TEST_DEV_TEAM > DEVELOPMENT_TEAM（钥匙串里得有它的 Apple Development 身份）> 钥匙串第一个 Apple Development 身份的 Team。
# 产物落在 .build/DerivedData（和 make build-app / test-app 同一处，所以是增量编、几十秒；之后 make build-app 不给别名会按工程里的设置重签回去）。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
sm=scripts/dev-signing/sign-mode.sh
if [ -n "${CI:-}" ] && [ "${RELEASE_TEST_DEV_SIGN:-}" != 1 ]; then
  skip "BLOCKED-签名：CI 上不碰登录钥匙串里的私钥（RELEASE_TEST_DEV_SIGN=1 强制跑）；本机 make release-test 会跑这条"
fi
[ -x "$sm" ] || { fail "$sm 不存在或不可执行"; finish; }
team=${RELEASE_TEST_DEV_TEAM:-}
if [ -z "$team" ] && [ -n "${DEVELOPMENT_TEAM:-}" ] && "$sm" --list 2>/dev/null | grep -qx "dev $DEVELOPMENT_TEAM"; then team=$DEVELOPMENT_TEAM; fi
[ -n "$team" ] || team=$("$sm" --dev-team 2>/dev/null)
[ -n "$team" ] || skip "BLOCKED-签名：钥匙串里没有 Apple Development 身份（security find-identity -v -p codesigning；CI / 没登 Apple ID 的机器）。解锁 = Xcode › Settings › Accounts 登 Apple ID（免费的也行）→ Manage Certificates → + Apple Development"
note "Team $team（$("$sm" --list 2>/dev/null | tr '\n' ' ')）"

if [ ! -f Switcher.xcodeproj/project.pbxproj ] || [ project.yml -nt Switcher.xcodeproj/project.pbxproj ]; then
  note "工作区的 Switcher.xcodeproj 没有或比 project.yml 旧：先 make gen（ad-hoc；下面的命令行覆盖照样出开发签名）"
  DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=0 make --no-print-directory gen >"$RELEASE_TEST_OUT/r17-gen.log" 2>&1 || { fail "make gen 失败（$RELEASE_TEST_OUT/r17-gen.log）"; finish; }
fi
log="$RELEASE_TEST_OUT/r17-build.log"
note "xcodebuild build-for-testing DEVELOPMENT_TEAM=$team SWITCHER_DEV_SIGN=1（= make build-app DEV_SIGN_TEAM=$team 的覆盖，另带测试包）"
if ! xcodebuild -project Switcher.xcodeproj -scheme Switcher -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
     DEVELOPMENT_TEAM="$team" SWITCHER_DEV_SIGN=1 build-for-testing >"$log" 2>&1; then
  if grep -q 'errSecInternalComponent' "$log"; then skip "BLOCKED-签名：签名时钥匙串锁着（errSecInternalComponent；屏幕锁着 / SSH 会话）——解锁登录钥匙串再跑"; fi
  fail "开发签名构建失败（$log）"; grep -E 'error:|requires a development|No signing certificate|provisioning' "$log" | head -8; finish
fi
ok "开发签名的 build-for-testing 退出 0"

app=.build/DerivedData/Build/Products/Debug/$(product_name).app
assert_file "$app" "$app"
[ -d "$app" ] || finish
sig=$(codesign -dvv "$app" 2>&1)
assert_contains "$sig" "TeamIdentifier=$team" "App 的 TeamIdentifier = $team"
assert_true "App 的 CodeDirectory flags 含 runtime（硬化运行时）" bash -c "grep -Eq 'flags=0x[0-9a-f]+\\([^)]*runtime' <<< \"\$1\"" _ "$sig"
assert_contains "$sig" "Authority=Apple Development" "App 用 Apple Development 身份签（不是 ad-hoc、不是 Developer ID）"
ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)
for k in com.apple.security.device.camera com.apple.security.device.audio-input com.apple.security.cs.disable-library-validation; do
  assert_contains "$ents" "\"$k\":true" "App 权限：$k"
done
assert_not_contains "$ents" "system-extension.install" "App 权限表没有 system-extension.install（受限权限，Personal Team 拿不到）"
req=$(codesign -d -r- "$app" 2>&1)
assert_contains "$req" "anchor apple generic" "指定要求按 Apple 证书链写（TCC 按它记授权）"
assert_contains "$req" "identifier \"com.plusmix.switcher\"" "指定要求含 bundle id"
assert_not_contains "$req" "cdhash" "指定要求不含 cdhash（重编译后不变 → TCC 不重问）"
assert_true "codesign --verify --deep --strict 通过" codesign --verify --deep --strict --verbose=2 "$app"

ext=$(ls -d "$app"/Contents/Library/SystemExtensions/*.systemextension 2>/dev/null | head -1)
assert_file "$ext" "扩展嵌在 Contents/Library/SystemExtensions/"
if [ -n "$ext" ]; then
  assert_contains "$(codesign -dvv "$ext" 2>&1)" "TeamIdentifier=$team" "扩展同一 Team"
  eents=$(codesign -d --entitlements - --xml "$ext" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)
  assert_contains "$eents" '"com.apple.security.app-sandbox":true' "扩展带沙盒"
  assert_contains "$eents" "$team.com.plusmix.switcher.camera" "扩展的 app group = <Team>.com.plusmix.switcher.camera"
fi
xct="$app/Contents/PlugIns/SwitcherTests.xctest"
assert_file "$xct" "测试包嵌在 Contents/PlugIns/"
if [ -d "$xct" ]; then
  assert_contains "$(codesign -dvv "$xct" 2>&1)" "TeamIdentifier=$team" "测试包同一 Team（make test-app 的宿主与测试包都是这个身份）"
  assert_not_contains "$(codesign -d --entitlements - --xml "$xct" 2>/dev/null)" "system-extension.install" "测试包不带受限权限"
fi

bin="$app/Contents/MacOS/$(app_executable "$app")"
smoke="$RELEASE_TEST_OUT/r17-smoke.log"
"$bin" --show "$REPO_ROOT/scenarios/g4-ndi-show.json" --no-api --audio-device null >"$smoke" 2>&1 &
pid=$!
sleep 4
if kill -0 "$pid" 2>/dev/null; then ok "开发签名的 App 起来 4 秒没崩（硬化运行时 + 关库校验下 libndi / Sparkle 都加载成功）"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
else wait "$pid"; code=$?; fail "开发签名的 App 4 秒内退出（码 ${code}）：$(tail -3 "$smoke")"; fi
finish
