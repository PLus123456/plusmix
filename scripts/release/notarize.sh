#!/bin/bash
# 公证 + staple（prompt 71 交付 1）：xcrun notarytool submit --wait，通过就 stapler staple；失败把 notarytool log 拉下来打印。
# 凭据（三选一，环境变量或参数）：
#   NOTARY_KEYCHAIN_PROFILE=<名字>       事先 xcrun notarytool store-credentials <名字>（Apple ID + app 专用密码 + Team ID，存钥匙串）——本机推荐
#   NOTARY_KEY_ID + NOTARY_KEY_ISSUER + NOTARY_KEY_PATH   App Store Connect API 密钥（.p8）——CI 推荐（secret 里放 base64 的 .p8）
#   NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID    直接给 Apple ID / app 专用密码
# 用法：notarize.sh <.dmg | .zip | .app> [--profile NAME] [--timeout 30m] [--no-staple]
#   .app 会先 ditto 成 zip 提交，票据 staple 到 .app 上（先公证 App 再打 DMG，DMG 再公证一次并 staple，用户离线首启也能过）。
set -uo pipefail
target=""; profile=${NOTARY_KEYCHAIN_PROFILE:-}; timeout=30m; staple=1
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --no-staple) staple=0; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "不认识的参数：$1" >&2; exit 2 ;;
    *) target=$1; shift ;;
  esac
done
[ -e "$target" ] || { echo "用法：notarize.sh <.dmg | .zip | .app> [--profile NAME]" >&2; exit 2; }
creds=()
if [ -n "$profile" ]; then creds=(--keychain-profile "$profile")
elif [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_KEY_ISSUER:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then creds=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER")
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then creds=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else echo "[notarize] 没有公证凭据（NOTARY_KEYCHAIN_PROFILE / NOTARY_KEY_* / NOTARY_APPLE_ID…，见文件头）：BLOCKED-账号" >&2; exit 3; fi
submit=$target; tmpzip=""
case "$target" in
  *.app) tmpzip=$(mktemp -d)/$(basename "$target" .app).zip; ditto -c -k --keepParent "$target" "$tmpzip"; submit=$tmpzip ;;
esac
echo "[notarize] 提交 $(basename "$submit")（最多等 $timeout）"
out=$(xcrun notarytool submit "$submit" "${creds[@]}" --wait --timeout "$timeout" 2>&1); code=$?
printf '%s\n' "$out" | sed 's/^/    /'
id=$(printf '%s' "$out" | sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' | head -1)
[ -n "$tmpzip" ] && rm -rf "$(dirname "$tmpzip")"
status=$(printf '%s' "$out" | sed -n 's/^ *status: \(.*\)$/\1/p' | tail -1)
if [ $code != 0 ] || [ "$status" != Accepted ]; then
  echo "[notarize] 没通过（status=${status:-?}）" >&2
  [ -n "$id" ] && xcrun notarytool log "$id" "${creds[@]}" 2>&1 | sed 's/^/    /' >&2
  exit 1
fi
if [ "$staple" = 1 ]; then xcrun stapler staple "$target" || { echo "[notarize] stapler staple 失败" >&2; exit 1; }; xcrun stapler validate "$target" >/dev/null && echo "[notarize] 已 staple：$target"; fi
echo "[notarize] Accepted（id $id）"
