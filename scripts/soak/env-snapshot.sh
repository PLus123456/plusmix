#!/bin/bash
# 环境快照（测试标准 §2.8、§7 报告头）：key=value 一行一项，soak / perf 脚本开跑前写进 environment.txt。
#   机器 / 芯片 / 核数 / 内存、macOS、Xcode / Swift / ffmpeg（有没有 libvmaf）/ MediaMTX / NDI SDK、电源（AC / 电池、电量、适配器瓦数）、
#   powermode（0 自动 / 1 低电量 / 2 高性能）、温度状态（thermal-state 探针 + pmset -g therm）、负载、占 CPU 前几名、
#   **在跑的编译 / 测试进程**（别的会话的 swift build / xcodebuild test 会让 V1 / V3 / S3 偏高，prompt 70 第 7 条：soak / perf 期间不要跑 App 测试）。
# 用法：scripts/soak/env-snapshot.sh [--busy-only] [--ambient <室温说明>] [--thermal-bin <编好的 thermal-state>]
set -uo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"

busy_only=0; ambient=""; thermal_bin=""
while [ $# -gt 0 ]; do
  case "$1" in
    --busy-only) busy_only=1; shift ;;
    --ambient) ambient="$2"; shift 2 ;;
    --thermal-bin) thermal_bin="$2"; shift 2 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done

# 编译 / 测试 / 编码类进程（本脚本、本会话的 headless 与 ffmpeg 分析步骤不算）：名字 + CPU%
busy_processes() {
  ps -Ao pcpu=,comm= | awk '
    { n=split($2, a, "/"); base=a[n] }
    base ~ /^(swift-build|swift-frontend|swift-driver|xcodebuild|xctest|clang|ld|XCBBuildService|SWBBuildService|swift-test|sourcekit-lsp)$/ && $1 > 1.0 {
      cnt[base]++; cpu[base] += $1 }
    END { for (b in cnt) printf "%s×%d(%.0f%%) ", b, cnt[b], cpu[b] }'
}
if [ "$busy_only" = 1 ]; then busy_processes; echo; exit 0; fi

kv() { printf '%s=%s\n' "$1" "$2"; }
kv date "$(date '+%Y-%m-%d %H:%M:%S %z')"
kv epoch "$(date +%s)"
kv commit "$(git rev-parse --short HEAD 2>/dev/null)"
kv branch "$(git symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
kv dirty "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
hw=$(system_profiler SPHardwareDataType 2>/dev/null)
kv chip "$(printf '%s\n' "$hw" | sed -n 's/^ *Chip: //p' | head -1)"
kv model "$(printf '%s\n' "$hw" | sed -n 's/^ *Model Name: //p' | head -1)"
kv model_id "$(printf '%s\n' "$hw" | sed -n 's/^ *Model Identifier: //p' | head -1)"
kv cores "$(sysctl -n hw.ncpu)（perflevel0 $(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null) / perflevel1 $(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null)）"
kv memory_gb "$(( $(sysctl -n hw.memsize) / 1073741824 ))"
kv macos "$(sw_vers -productVersion)"
kv macos_build "$(sw_vers -buildVersion)"
kv xcode "$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
kv swift "$(swift --version 2>&1 | head -1)"
vmaf=no; ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' libvmaf ' && vmaf=yes
kv ffmpeg "$(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f1-3)（libvmaf $vmaf）"
kv mediamtx "$(mediamtx --version 2>/dev/null | head -1)"
kv ndi_sdk "$(cat '/Library/NDI SDK for Apple/Version.txt' 2>/dev/null | head -1 | tr -d '\r')"
batt=$(pmset -g batt 2>/dev/null)
src=$(printf '%s\n' "$batt" | head -1 | sed "s/.*'\(.*\)'.*/\1/")
case "$src" in "AC Power") power=AC ;; "Battery Power") power=Battery ;; *) power="$src" ;; esac
kv power "$power"
kv battery_pct "$(printf '%s\n' "$batt" | grep -o '[0-9]*%' | head -1 | tr -d '%')"
kv adapter_watts "$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -o '"Watts"=[0-9]*' | head -1 | cut -d= -f2)"
kv system_power_in_mw "$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -o '"SystemPowerIn"=[0-9]*' | head -1 | cut -d= -f2)"
powermode=$(pmset -g 2>/dev/null | awk '$1=="powermode"{print $2}' | head -1)
kv powermode "${powermode:-?}"
kv low_power_mode "$([ "${powermode:-0}" = 1 ] && echo 1 || echo 0)"
if [ -n "$thermal_bin" ] && [ -x "$thermal_bin" ]; then
  kv thermal_state "$("$thermal_bin" 2>/dev/null | sed 's/^thermal=//; s/ low_power=\(.\)/（ProcessInfo 低电量 \1）/')"
fi
kv pmset_therm "$(pmset -g therm 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
kv display_sleep "$(pmset -g 2>/dev/null | awk '$1=="displaysleep"{print $2}' | head -1)"
kv ambient "${ambient:-未记录（--ambient 可写室温，例如 \"约 24 °C，空调房\"）}"
kv load_before "$(uptime | sed 's/.*load averages: //')"
kv top_processes_before "$(ps -Ao pcpu,comm -r | sed -n '2,6p' | awk '{n=split($2,a,"/"); printf "%s%%%s; ", $1, a[n]}')"
kv busy_processes "$(busy_processes)"
kv free_disk_gb "$(df -g . | awk 'NR==2{print $4}')"
