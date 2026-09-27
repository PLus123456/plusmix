#!/bin/bash
# CI 上的临时钥匙串（.github/workflows/release.yml）：import 把 secret 里的 Developer ID .p12 导进一个一次性钥匙串并加进搜索列表；cleanup 删掉。
# 环境变量：DEVELOPER_ID_P12_BASE64、DEVELOPER_ID_P12_PASSWORD；钥匙串路径 $RUNNER_TEMP/switcher-release.keychain-db（没有 RUNNER_TEMP 用 /tmp）。
# 本机手工发布不用它：证书装在登录钥匙串里，archive.sh 自己找 "Developer ID Application" 身份。
set -uo pipefail
kc="${RUNNER_TEMP:-/tmp}/switcher-release.keychain-db"
case "${1:-}" in
  import)
    [ -n "${DEVELOPER_ID_P12_BASE64:-}" ] && [ -n "${DEVELOPER_ID_P12_PASSWORD:-}" ] || { echo "::error::没有 DEVELOPER_ID_P12_BASE64 / DEVELOPER_ID_P12_PASSWORD：发布包必须用 Developer ID 签名（BLOCKED-账号）"; exit 1; }
    p12="${RUNNER_TEMP:-/tmp}/developer-id.p12"
    printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -d > "$p12"
    kcpass=$(uuidgen)
    security delete-keychain "$kc" 2>/dev/null || true
    security create-keychain -p "$kcpass" "$kc"
    security set-keychain-settings -lut 7200 "$kc"
    security unlock-keychain -p "$kcpass" "$kc"
    security import "$p12" -k "$kc" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign
    rm -f "$p12"
    # 让 codesign 不弹授权框
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" >/dev/null
    security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')
    echo "导入的身份："; security find-identity -v -p codesigning "$kc" | grep "Developer ID Application" || { echo "::error::.p12 里没有 Developer ID Application 身份"; exit 1; }
    ;;
  cleanup)
    if [ -f "$kc" ]; then
      security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | grep -v "switcher-release") 2>/dev/null || true
      security delete-keychain "$kc" && echo "已删临时钥匙串"
    fi
    ;;
  *) echo "用法：ci-keychain.sh import | cleanup" >&2; exit 2 ;;
esac
