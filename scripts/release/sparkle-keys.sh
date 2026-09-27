#!/bin/bash
# Sparkle 的 EdDSA（ed25519）签名密钥（prompt 71 交付 2）。私钥存在打包机当前用户的登录钥匙串（服务名 https://sparkle-project.org），永远不进仓库；
# 公钥进 App 的 Info.plist（SUPublicEDKey，由 archive.sh 从 SPARKLE_PUBLIC_ED_KEY 传入）。一套密钥对应产品的全部版本：换了私钥，旧版本就更新不了
# （Sparkle 用公钥验 appcast 里每个包的签名）。CI 上用 export 出来的文件当 secret，appcast.sh --ed-key-file - 从标准输入读。详见 docs/release/sparkle.md。
#
# 用法：
#   sparkle-keys.sh generate [--account NAME]     生成（已有就直接打印公钥与 Info.plist 用法）
#   sparkle-keys.sh public   [--account NAME]     只打印公钥（base64）
#   sparkle-keys.sh export --to FILE [--account NAME]   把私钥导出到文件（放到 CI secret 后删掉文件）
#   sparkle-keys.sh import FILE [--account NAME]  从文件导入私钥到钥匙串（新打包机）
# --account 默认 ed25519（Sparkle 的默认账户名）；测试用临时名字，测完 security delete-generic-password -s https://sparkle-project.org -a NAME。
set -uo pipefail
. "$(dirname "$0")/sparkle-bin.sh"
cmd=${1:-}; [ $# -gt 0 ] && shift
account=ed25519; to=""; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --account) account=$2; shift 2 ;;
    --to) to=$2; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) file=$1; shift ;;
  esac
done
bin=$(sparkle_bin_dir) || exit 2
case "$cmd" in
  generate)
    "$bin/generate_keys" --account "$account"
    ;;
  public)
    "$bin/generate_keys" --account "$account" -p
    ;;
  export)
    [ -n "$to" ] || { echo "用法：sparkle-keys.sh export --to FILE [--account NAME]" >&2; exit 2; }
    "$bin/generate_keys" --account "$account" -x "$to" && chmod 600 "$to" && echo "[sparkle] 私钥已导出到 $to（放进 CI secret SPARKLE_PRIVATE_KEY 后删掉它；不要提交）"
    ;;
  import)
    [ -n "$file" ] && [ -f "$file" ] || { echo "用法：sparkle-keys.sh import FILE [--account NAME]" >&2; exit 2; }
    "$bin/generate_keys" --account "$account" -f "$file"
    ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
