#!/bin/bash
# 随包手册与 docs/user 一致（W4-C2 / prompt 103 建议，G8b 挂进 make lint：scripts/ 下名字以 check- 开头的脚本自动带上，docs/OWNERSHIP.md 补充规则 4）。
# docs/tools/build-help.py --check 只比较不写：docs/user 改了没重跑 make manual，App/Resources/Help 里的手册就是旧的，这里红。
set -uo pipefail
cd "$(dirname "$0")/.."
if python3 docs/tools/build-help.py --check; then
  exit 0
else
  printf '\033[31m%s\033[0m\n' "[check-help] App/Resources/Help 与 docs/user 不一致：先 make manual 重生成再提交（产物入库）"
  exit 1
fi
