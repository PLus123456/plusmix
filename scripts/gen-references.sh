#!/bin/bash
# 生成 / 更新合成引擎的参考图（Tests/References/*.png，测试标准 V8）。
#
# 用法：scripts/gen-references.sh [--filter <XCTest 过滤>]
#   默认跑 SwitcherRenderTests.V8ReferenceTests/testV8_generateOrCompareAllReferences，
#   设 SWITCHER_GEN_REFERENCES=1 让它把离线渲染结果写成参考图而不是比对。
#
# 规矩（Tests/References/README.md）：
#   - 参考图 = 离线渲染 API（OfflineRenderer.renderOffline）对固定状态 + 代码生成的固定输入图的输出。
#   - 首次生成后必须人工看一眼（Tests/References/README.md 写了每张该长什么样）。
#   - 有意更新参考图时，在报告 / PR 里说明每张为什么变，并附 PSNR / SSIM。
#   - 生成前会先跑一遍比对；差异会打印出来，方便判断是"预期变化"还是"回归"。
set -uo pipefail
cd "$(dirname "$0")/.."

filter="SwitcherRenderTests.V8ReferenceTests/testV8_generateOrCompareAllReferences"
while [ $# -gt 0 ]; do
  case "$1" in
    --filter) filter="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

pkg=Packages/SwitcherCore
if ls Tests/References/*.png >/dev/null 2>&1; then
  echo "== 先和现有参考图比一遍（差异只是提示，不会阻止生成）"
  swift test --package-path "$pkg" --filter "$filter" 2>&1 | grep -E "^V8 |error:|failed" || true
fi
echo "== 生成参考图"
SWITCHER_GEN_REFERENCES=1 swift test --package-path "$pkg" --filter "$filter" 2>&1 | grep -E "已写参考图|error:|failed|passed \(" || { echo "生成失败" >&2; exit 1; }
echo "== 结果"
ls -la Tests/References/*.png
echo "记得：人工看一眼，改了要在报告 / PR 里说明。"
