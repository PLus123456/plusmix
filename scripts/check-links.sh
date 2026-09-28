#!/bin/bash
# 文档链接检查挂进 make lint（W4-B2，prompt 83 交付 2）：scripts/ 下以 check- 开头、可执行的脚本会被 Makefile 的 EXTRA_LINTS 与 CI 的
# scripts/release/ci-ownership.sh 自动带上（docs/OWNERSHIP.md 补充规则 4）。实现是 W4-C 的 docs/tools/check-links.py（归 docs/），这里只转调：
# 按本脚本的位置找它（不看当前目录），参数与退出码原样传。
# 用法：scripts/check-links.sh [范围 ...]（不给 = docs/、Samples/、README.md 全查；范围相对仓库根，例如 scripts/check-links.sh docs/user）
exec python3 "$(dirname "$0")/../docs/tools/check-links.py" "$@"
