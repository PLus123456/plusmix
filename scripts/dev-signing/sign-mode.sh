#!/bin/bash
# make gen 的签名模式自动识别（W4-B3，prompt 141；docs/release/signing.md"三种签名模式"）。
#
# 用法：
#   sign-mode.sh             stdout：要写进工程的 SWITCHER_DEV_SIGN（1 / 0 / 空），stderr：一行说明；配置不对退出 2
#   sign-mode.sh --dev-team  stdout：钥匙串里第一个 Apple Development 身份的 Team ID；没有退出 1
#   sign-mode.sh --list      stdout：钥匙串里的有效签名身份，每行 "dev <Team ID>"（Apple Development）或 "devid <Team ID>"（Developer ID Application）
# 环境：DEVELOPMENT_TEAM、SWITCHER_DEV_SIGN（make gen 传进来）；SWITCHER_SIGN_IDENTITIES（测试用：设了——哪怕是空串——就不查钥匙串，内容同 --list）。
#
# 决策（project.yml 再按 DEVELOPMENT_TEAM + SWITCHER_DEV_SIGN 派生 SWITCHER_SIGN_MODE = adhoc / dev / devid）：
#   没给 Team                   → ad-hoc；SWITCHER_DEV_SIGN 原样（1 报错：开发签名要 Team ID）
#   Team + SWITCHER_DEV_SIGN=1  → 开发签名；=0 → Developer ID（make archive 那条，archive.sh 钉 0）
#   Team + 没给                 → 看钥匙串：有该 Team 的 Developer ID 身份 → 0（W4-B 原样）；没有、但有它的 Apple Development 身份 → 1
#                                （Personal Team / 没有 Developer ID 的机器：Developer ID 那套设置在这里根本签不出来，G13 §4.4）；都没有 → 0（原样，构建多半停在签名）
# 只读钥匙串（security find-identity / find-certificate），不碰私钥、不联网。
set -uo pipefail

say() { printf '[sign-mode] %s\n' "$*" >&2; }

# 钥匙串里的有效签名身份 → "dev <Team>" / "devid <Team>"
list_identities() {
  if [ -n "${SWITCHER_SIGN_IDENTITIES+x}" ]; then
    printf '%s\n' "$SWITCHER_SIGN_IDENTITIES" | sed '/^[[:space:]]*$/d'
    return 0
  fi
  command -v security >/dev/null 2>&1 || return 0
  local ids hashes pems h
  ids=$(security find-identity -v -p codesigning 2>/dev/null) || return 0
  # Developer ID Application：证书名括号里就是 Team ID
  printf '%s\n' "$ids" | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]\{10\}\))"$/devid \1/p'
  # Apple Development：证书名括号里是个人证书的编号、不是 Team ID（G13 §10 第 6 条），Team 在证书主题的 OU 里
  hashes=$(printf '%s\n' "$ids" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*"$/\1/p')
  [ -n "$hashes" ] || return 0
  pems=$(security find-certificate -a -Z -p -c "Apple Development" 2>/dev/null) || return 0
  for h in $hashes; do
    printf '%s\n' "$pems" \
      | awk -v h="$h" '/^SHA-1 hash:/ { on = ($3 == h) } on && /BEGIN CERTIFICATE/ { p = 1 } p && on { print } /END CERTIFICATE/ { p = 0 }' \
      | /usr/bin/openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/dev \1/p'
  done
}

ids=$(list_identities)
dev_teams=$(printf '%s\n' "$ids" | sed -n 's/^dev \([A-Z0-9]*\)$/\1/p')
first_dev_team=$(printf '%s\n' "$dev_teams" | sed -n '1p')

case "${1:-}" in
  --list) [ -n "$ids" ] && printf '%s\n' "$ids"; exit 0 ;;
  --dev-team) [ -n "$first_dev_team" ] || exit 1; printf '%s\n' "$first_dev_team"; exit 0 ;;
  "") ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) say "不认识的参数：$1"; exit 2 ;;
esac

team=${DEVELOPMENT_TEAM:-}
dev=${SWITCHER_DEV_SIGN:-}
has() { printf '%s\n' "$ids" | grep -qx "$1"; }
case "$dev" in 0|1|"") ;; *) say "SWITCHER_DEV_SIGN 只认 1（开发签名）/ 0（Developer ID）/ 空（自动），拿到的是 [$dev]"; exit 2 ;; esac

if [ -z "$team" ]; then
  if [ "$dev" = 1 ]; then
    say "SWITCHER_DEV_SIGN=1 要配 Team ID：$( [ -n "$first_dev_team" ] && echo "钥匙串里的 Apple Development 身份是 Team $first_dev_team → DEVELOPMENT_TEAM=$first_dev_team SWITCHER_DEV_SIGN=1 make gen" || echo "钥匙串里也没有 Apple Development 身份（Xcode › Settings › Accounts 登 Apple ID 建一个）")"
    exit 2
  fi
  if [ -n "$first_dev_team" ]; then
    say "ad-hoc（没给 DEVELOPMENT_TEAM）。钥匙串里有 Apple Development（Team ${first_dev_team}）：要本机开发签名（TCC 授权跨重编译不重问）用 DEVELOPMENT_TEAM=$first_dev_team make gen"
  else
    say "ad-hoc（没给 DEVELOPMENT_TEAM）"
  fi
  printf '%s\n' "$dev"; exit 0
fi

hint_teams() { [ -n "$dev_teams" ] && echo "；钥匙串里的 Apple Development 身份是 Team $(printf '%s' "$dev_teams" | tr '\n' ' ' | sed 's/ *$//')（证书名括号里那串不是 Team ID，Team 看证书的 OU）"; }
case "$dev" in
  1)
    if has "dev $team"; then say "开发签名（DEVELOPMENT_TEAM=${team}，SWITCHER_DEV_SIGN=1）"
    else say "开发签名（SWITCHER_DEV_SIGN=1），但钥匙串里没有 Team $team 的 Apple Development 身份：构建会停在签名那步$(hint_teams)"; fi ;;
  0)
    say "Developer ID 设置（DEVELOPMENT_TEAM=${team}，SWITCHER_DEV_SIGN=0；make archive 那条）" ;;
  "")
    if has "devid $team"; then dev=0; say "Developer ID 设置（DEVELOPMENT_TEAM=${team}：钥匙串里有该 Team 的 Developer ID 身份；本机开发签名要显式 SWITCHER_DEV_SIGN=1）"
    elif has "dev $team"; then dev=1; say "开发签名（DEVELOPMENT_TEAM=${team}：钥匙串里只有该 Team 的 Apple Development 身份、没有 Developer ID——Personal Team 也是这样；SWITCHER_DEV_SIGN=0 强制 Developer ID 设置）"
    else dev=0; say "Developer ID 设置（DEVELOPMENT_TEAM=${team}，钥匙串里没有该 Team 的签名身份：构建多半停在签名那步$(hint_teams)）"; fi ;;
esac
printf '%s\n' "$dev"
