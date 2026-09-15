#!/bin/bash
# S5 热插拔计时：用户手动拔插 USB 摄像头 / UVC 采集卡 20 次，脚本计时、计数、验证编号不变（跑在带权限的 .app 里）。
# 用法：Scripts/hotplug-timer.sh <摄像头 uniqueID 或 devices 里的下标> [次数=20] [每步超时秒=120]
# 先 `Scripts/probe-app.sh devices` 看 uniqueID。结果表直接贴进报告 §2 的 S5。
set -euo pipefail
cd "$(dirname "$0")/.."
ID=${1:?用法：$0 <uniqueID|下标> [次数] [超时秒]}
CYCLES=${2:-20}
TIMEOUT=${3:-120}
exec Scripts/probe-app.sh hotplug --camera "$ID" --cycles "$CYCLES" --timeout "$TIMEOUT"
