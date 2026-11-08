#!/bin/bash
# R16：三种签名模式（W4-B3，prompt 141 交付 1 / 2 / 4）——不要签名身份，CI 上也跑：
#   1. 权限表只有一份开发表（App/Switcher-dev.entitlements：camera + audio-input + cs.disable-library-validation，没有 system-extension.install），
#      scripts/ 下不再留第二份；发布表（Switcher-signed）不关库校验；ad-hoc 表是空的。
#   2. make gen 的自动识别（scripts/dev-signing/sign-mode.sh）按决策表出 SWITCHER_DEV_SIGN；钥匙串用 SWITCHER_SIGN_IDENTITIES 注入，不碰真钥匙串。
#   3. project.yml 生成的工程在三种模式下给三个 target 选对签名方式 / 身份 / 权限表（xcodebuild -showBuildSettings，命令行盖两个输入）：
#      (a) ad-hoc 与 (c) Developer ID 和 W4-B3 之前一字不差，(b) 开发签名 = Manual + Apple Development + 开发表 + 不要描述文件；
#      生成的 TargetAttributes 仍是 ProvisioningStyle = Automatic（(c) 本机测不了，生成物不许变）。
#   4. XcodeGen 把两个输入写进工程（临时目录生成，不动工作区的 Switcher.xcodeproj）；make gen 把自动识别的结果交给 XcodeGen（假 xcodegen 记环境）；
#      project.yml 变了 build-app 自动重新生成时沿用工程里原来的签名设置（假工程）；
#      make archive 那条钉 SWITCHER_DEV_SIGN=0（Developer ID 永远不会被自动识别成开发签名）；DEV_SIGN_TEAM 别名只在 xcodebuild 命令行盖两个输入；make help 有一句。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT" || exit 1
sm=scripts/dev-signing/sign-mode.sh
T=ABCDE12345     # 假 Team ID（只用来算设置，不签名）
U=ZYXWV98765     # 另一个假 Team
scratch=$(mktemp -d "$RELEASE_TEST_OUT/r16.XXXX")

# ---- 1. 权限表 ----
ent_keys() { plutil -convert json -o - "$1" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(k for k,v in d.items() if v)))' 2>/dev/null; }
dev_ent=App/Switcher-dev.entitlements
assert_file "$dev_ent" "开发签名的权限表 $dev_ent"
assert_eq "$(ent_keys "$dev_ent")" "com.apple.security.cs.disable-library-validation com.apple.security.device.audio-input com.apple.security.device.camera" \
  "开发表的键（camera + audio-input + 关库校验，没有 system-extension.install）"
assert_eq "$(ent_keys App/Switcher-signed.entitlements)" "com.apple.developer.system-extension.install com.apple.security.device.audio-input com.apple.security.device.camera" \
  "发布表（Developer ID）的键不变、不关库校验（sign.sh 用同一 Team 重签 libndi）"
assert_eq "$(ent_keys App/Switcher.entitlements)" "" "ad-hoc 表是空的"
assert_eq "$(find scripts -name '*.entitlements' -o -name '*.xcconfig' | tr '\n' ' ')" "" "scripts/ 下没有第二份权限表 / xcconfig（G13 旁路的两个文件已收进 App/ 或删掉）"
assert_true "$sm 可执行" test -x "$sm"

# ---- 2. 自动识别（决策表）----
# run_sm <期望输出> <期望退出码> <说明> <环境赋值...>：env -i 起一个干净环境，只给 PATH / HOME 和这里列的变量
run_sm() {
  local want=$1 wantcode=$2 msg=$3; shift 3
  local out code
  out=$(env -i PATH="$PATH" HOME="$HOME" "$@" "$sm" 2>"$scratch/sm.err"); code=$?
  if [ "$code" = "$wantcode" ] && { [ "$wantcode" != 0 ] || [ "$out" = "$want" ]; }; then ok "${msg}（输出 [$out]，退出 ${code}）"
  else fail "${msg}：期望输出 [$want] 退出 ${wantcode}，实际 [$out] 退出 ${code}；stderr：$(tr '\n' ' ' < "$scratch/sm.err")"; fi
}
run_sm ""  0 "没给 Team → ad-hoc（SWITCHER_DEV_SIGN 留空）"                       DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="dev $T"
run_sm "0" 0 "没给 Team、显式 0（archive.sh --adhoc 这么调）→ 照写 0，仍是 ad-hoc"  DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=0 SWITCHER_SIGN_IDENTITIES=""
run_sm ""  2 "SWITCHER_DEV_SIGN=1 却没给 Team → 退出 2（不悄悄退成 ad-hoc）"         DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=1 SWITCHER_SIGN_IDENTITIES="dev $T"
assert_contains "$(cat "$scratch/sm.err")" "DEVELOPMENT_TEAM=$T" "没给 Team 时提示钥匙串里 Apple Development 身份的 Team"
run_sm "1" 0 "Team + 显式 1 → 开发签名"                                            DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=1 SWITCHER_SIGN_IDENTITIES="dev $T"
run_sm "1" 0 "Team + 显式 1、钥匙串里没有该 Team 的身份 → 仍听用户的（只警告）"     DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=1 SWITCHER_SIGN_IDENTITIES=""
run_sm "0" 0 "Team + 显式 0 → Developer ID 设置（即便钥匙串只有 Apple Development）" DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=0 SWITCHER_SIGN_IDENTITIES="dev $T"
run_sm ""  2 "SWITCHER_DEV_SIGN 只认 1 / 0 / 空"                                   DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=yes SWITCHER_SIGN_IDENTITIES=""
run_sm "1" 0 "自动：只有该 Team 的 Apple Development（Personal Team）→ 开发签名"     DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="dev $T"
run_sm "0" 0 "自动：有该 Team 的 Developer ID → Developer ID 设置（W4-B 原样）"      DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="$(printf 'devid %s\ndev %s' $T $T)"
run_sm "0" 0 "自动：只有别的 Team 的 Apple Development → Developer ID 设置（原样）"  DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="dev $U"
assert_contains "$(cat "$scratch/sm.err")" "$U" "Team 对不上时提示钥匙串里的 Team（证书名括号里那串不是 Team ID）"
run_sm "0" 0 "自动：钥匙串里什么身份都没有 → Developer ID 设置（原样）"            DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES=""
out=$(env -i PATH="$PATH" HOME="$HOME" SWITCHER_SIGN_IDENTITIES="$(printf 'devid %s\ndev %s\ndev %s' $U $T $U)" "$sm" --dev-team 2>/dev/null)
assert_eq "$out" "$T" "--dev-team 给第一个 Apple Development 身份的 Team"
assert_false "--dev-team 没有 Apple Development 身份时退出非 0" env -i PATH="$PATH" HOME="$HOME" SWITCHER_SIGN_IDENTITIES="devid $U" "$sm" --dev-team

# ---- 3. 工程按模式选设置 ----
if [ ! -f Switcher.xcodeproj/project.pbxproj ] || [ project.yml -nt Switcher.xcodeproj/project.pbxproj ]; then
  note "工作区的 Switcher.xcodeproj 没有或比 project.yml 旧：按 Makefile 的规则重新生成（沿用工程里原来的签名模式；下面的命令行覆盖与它无关）"
  make --no-print-directory Switcher.xcodeproj/project.pbxproj >"$scratch/gen.log" 2>&1 || { fail "重新生成工程失败（$scratch/gen.log）"; finish; }
fi
# settings <标签> <覆盖...> → $scratch/<标签>.json（test 动作：三个 target 都在）
settings() {
  local tag=$1; shift
  xcodebuild -showBuildSettings -json -project Switcher.xcodeproj -scheme Switcher -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/DerivedData "$@" test >"$scratch/$tag.json" 2>"$scratch/$tag.err"
}
# get <标签> <target> <设置名>：没有这个设置时输出 <无>
get() {
  python3 - "$scratch/$1.json" "$2" "$3" <<'PY'
import json, sys
path, target, key = sys.argv[1:]
for t in json.load(open(path)):
    if t.get("target") == target:
        v = t["buildSettings"].get(key)
        print("<无>" if v is None else v); break
else:
    print("<没有 target>")
PY
}
# expect <标签> <target> <设置名=期望值>...
expect() {
  local tag=$1 target=$2; shift 2
  local kv k v
  for kv in "$@"; do k=${kv%%=*}; v=${kv#*=}; assert_eq "$(get "$tag" "$target" "$k")" "$v" "[$tag] $target $k"; done
}
modes_ok=1
settings adhoc   DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=   || modes_ok=0
settings adhoc1  DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=1  || modes_ok=0
settings dev     DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=1 || modes_ok=0
settings devid   DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=0 || modes_ok=0
settings devid_  DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=  || modes_ok=0
if [ "$modes_ok" = 1 ]; then ok "xcodebuild -showBuildSettings 五种组合都出得来"; else fail "xcodebuild -showBuildSettings 失败（$scratch/*.err）"; fi

# (a) ad-hoc：与 W4-B3 之前相同
for tag in adhoc adhoc1; do
  expect $tag Switcher SWITCHER_SIGN_MODE=adhoc CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=App/Switcher.entitlements ENABLE_HARDENED_RUNTIME=YES
done
expect adhoc SwitcherCameraExtension CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=CameraExtension/CameraExtension.entitlements
expect adhoc SwitcherTests CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- "CODE_SIGN_ENTITLEMENTS=<无>"
# (b) 开发签名
expect dev Switcher SWITCHER_SIGN_MODE=dev DEVELOPMENT_TEAM=$T CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" \
  CODE_SIGN_ENTITLEMENTS=App/Switcher-dev.entitlements ENABLE_HARDENED_RUNTIME=YES
for k in PROVISIONING_PROFILE_SPECIFIER PROVISIONING_PROFILE; do
  v=$(get dev Switcher $k); case "$v" in ""|"<无>") ok "[dev] Switcher $k 空（不要描述文件）" ;; *) fail "[dev] Switcher ${k}：应为空，实际 [$v]" ;; esac
done
expect dev SwitcherCameraExtension DEVELOPMENT_TEAM=$T CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" \
  CODE_SIGN_ENTITLEMENTS=CameraExtension/CameraExtension.entitlements ENABLE_HARDENED_RUNTIME=YES
expect dev SwitcherTests DEVELOPMENT_TEAM=$T CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" "CODE_SIGN_ENTITLEMENTS=<无>"
# (c) Developer ID：与 W4-B3 之前相同（显式 0 与没给一样）
for tag in devid devid_; do
  expect $tag Switcher SWITCHER_SIGN_MODE=devid DEVELOPMENT_TEAM=$T CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- \
    CODE_SIGN_ENTITLEMENTS=App/Switcher-signed.entitlements ENABLE_HARDENED_RUNTIME=YES
done
expect devid SwitcherCameraExtension CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=CameraExtension/CameraExtension.entitlements
expect devid SwitcherTests CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- "CODE_SIGN_ENTITLEMENTS=<无>"

# ---- 4. 生成与入口 ----
# 4a. XcodeGen 把两个输入写进工程：临时目录生成（只看 pbxproj 里的值，不编译，所以相对路径解析到哪无所谓——G13 §10 第 6 条 ③）
gen_into() { local dir=$1; shift; mkdir -p "$dir"; env "$@" "${XCODEGEN:-/opt/homebrew/bin/xcodegen}" generate --spec project.yml --project "$dir" --quiet >"$dir.log" 2>&1; }
if gen_into "$scratch/gen-dev" DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=1 && gen_into "$scratch/gen-adhoc" DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=; then
  pdev=$(cat "$scratch/gen-dev/Switcher.xcodeproj/project.pbxproj"); padhoc=$(cat "$scratch/gen-adhoc/Switcher.xcodeproj/project.pbxproj")
  assert_contains "$pdev" "DEVELOPMENT_TEAM = $T;" "开发签名生成：DEVELOPMENT_TEAM 写进工程"
  assert_contains "$pdev" "SWITCHER_DEV_SIGN = 1;" "开发签名生成：SWITCHER_DEV_SIGN = 1 写进工程"
  assert_contains "$padhoc" 'SWITCHER_DEV_SIGN = "";' "ad-hoc 生成：SWITCHER_DEV_SIGN 是空串（不是原样的 \${…}）"
  pstyle=$(grep 'ProvisioningStyle' "$scratch/gen-dev/Switcher.xcodeproj/project.pbxproj")
  assert_eq "$(grep -c 'ProvisioningStyle = Automatic;' <<< "$pstyle")/$(grep -c . <<< "$pstyle")" "3/3" \
    "TargetAttributes：三个 target 的 ProvisioningStyle 都还是 Automatic（生成物与 W4-B3 之前一样；签名方式只看构建设置 CODE_SIGN_STYLE）"
else
  fail "xcodegen 生成到临时目录失败（$scratch/gen-*.log）"
fi
# 4b. make gen 把自动识别的结果交给 XcodeGen：假 xcodegen 把收到的两个环境变量记下来；SWITCHER_KEEP_RESOLVED=1 不碰工作区的 Package.resolved
fake="$scratch/fake-xcodegen"
printf '#!/bin/bash\nprintf "TEAM=[%%s] DEV=[%%s]\\n" "$DEVELOPMENT_TEAM" "$SWITCHER_DEV_SIGN" > "%s/fake.env"\n' "$scratch" > "$fake"; chmod +x "$fake"
mkgen() { rm -f "$scratch/fake.env"; env SWITCHER_KEEP_RESOLVED=1 "$@" make --no-print-directory gen XCODEGEN="$fake" >"$scratch/mkgen.log" 2>&1; }
mkgen DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="dev $T"
assert_eq "$(cat "$scratch/fake.env" 2>/dev/null)" "TEAM=[$T] DEV=[1]" "make gen：Team 给了、只有该 Team 的 Apple Development → XcodeGen 收到 SWITCHER_DEV_SIGN=1"
mkgen DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="$(printf 'devid %s\ndev %s' $T $T)"
assert_eq "$(cat "$scratch/fake.env" 2>/dev/null)" "TEAM=[$T] DEV=[0]" "make gen：有 Developer ID → XcodeGen 收到 SWITCHER_DEV_SIGN=0"
mkgen DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="dev $T"
assert_eq "$(cat "$scratch/fake.env" 2>/dev/null)" "TEAM=[] DEV=[]" "make gen：不给 Team → ad-hoc，两个都是空串"
assert_contains "$(cat "$scratch/mkgen.log")" "$T" "make gen 的 ad-hoc 提示里带上钥匙串里能用的 Team"
if mkgen DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN=1 SWITCHER_SIGN_IDENTITIES=""; then fail "make gen：SWITCHER_DEV_SIGN=1 却没给 Team 应失败"; else ok "make gen：SWITCHER_DEV_SIGN=1 却没给 Team → 失败"; fi
assert_no_file "$scratch/fake.env" "配置不对时不调 XcodeGen"
# 4b'. project.yml 比工程新时 build-app / test-app 自动重新生成：环境里两个签名变量都没给就沿用工程里原来写的（拉一次 bump 版本号不该悄悄退回 ad-hoc）
fp="$scratch/fake.xcodeproj"; mkdir -p "$fp"
printf '\t\t\t\tDEVELOPMENT_TEAM = %s;\n\t\t\t\tSWITCHER_DEV_SIGN = 1;\n' $T > "$fp/project.pbxproj"
regen() { rm -f "$scratch/fake.env"; touch -t 200001010000 "$fp/project.pbxproj"
  env SWITCHER_KEEP_RESOLVED=1 "$@" make --no-print-directory "$fp/project.pbxproj" XCODEPROJ="$fp" XCODEGEN="$fake" >"$scratch/regen.log" 2>&1; }
regen DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="dev $T"
assert_eq "$(cat "$scratch/fake.env" 2>/dev/null)" "TEAM=[$T] DEV=[1]" "project.yml 变了自动重新生成：沿用工程里原来的 Team 与开发签名开关"
assert_contains "$(cat "$scratch/regen.log")" "沿用工程里原来的" "自动重新生成时说一声沿用了什么"
regen DEVELOPMENT_TEAM=$U SWITCHER_DEV_SIGN=0 SWITCHER_SIGN_IDENTITIES=""
assert_eq "$(cat "$scratch/fake.env" 2>/dev/null)" "TEAM=[$U] DEV=[0]" "自动重新生成时环境里给了就听环境的"
printf '\t\t\t\tDEVELOPMENT_TEAM = "";\n\t\t\t\tSWITCHER_DEV_SIGN = "";\n' > "$fp/project.pbxproj"
regen DEVELOPMENT_TEAM= SWITCHER_DEV_SIGN= SWITCHER_SIGN_IDENTITIES="dev $T"
assert_eq "$(cat "$scratch/fake.env" 2>/dev/null)" "TEAM=[] DEV=[]" "原来是 ad-hoc 的工程自动重新生成后仍是 ad-hoc"
# 4c. make archive（Developer ID）钉 SWITCHER_DEV_SIGN=0
assert_contains "$(grep -n 'run_logged gen' scripts/release/archive.sh)" "SWITCHER_DEV_SIGN=0" "archive.sh 生成工程时钉 SWITCHER_DEV_SIGN=0"
assert_contains "$(grep -n 'xcb=(xcodebuild archive' -A3 scripts/release/archive.sh)" "SWITCHER_DEV_SIGN=0" "archive.sh 的 xcodebuild archive 命令行也钉 SWITCHER_DEV_SIGN=0"
# 4d. DEV_SIGN_TEAM 别名：只在 xcodebuild 命令行盖两个输入，不再带 -xcconfig
for t in build-app test-app; do
  n=$(make -n --no-print-directory "$t" DEV_SIGN_TEAM=$T 2>/dev/null | grep xcodebuild | tail -1)
  assert_contains "$n" "DEVELOPMENT_TEAM=$T SWITCHER_DEV_SIGN=1" "make $t DEV_SIGN_TEAM=${T}：xcodebuild 命令行盖 DEVELOPMENT_TEAM + SWITCHER_DEV_SIGN=1"
  assert_not_contains "$n" "-xcconfig" "make $t DEV_SIGN_TEAM：不再走 G13 的 -xcconfig 旁路"
  n=$(make -n --no-print-directory "$t" 2>/dev/null | grep xcodebuild | tail -1)
  assert_not_contains "$n" "SWITCHER_DEV_SIGN" "make $t 不给别名：命令行不盖签名设置（用工程里写好的）"
done
assert_contains "$(make --no-print-directory help 2>/dev/null)" "SWITCHER_DEV_SIGN=1" "make help 有开发签名一句"
rm -rf "$scratch"
finish
