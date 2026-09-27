#!/bin/bash
# S4 热降频（测试标准 §1 S4、§3 S4、§4 S4；prompt 70 第 5 条）：无风扇机型（M1 Air）跑标准负载 1 小时，powermetrics 记 CPU 各簇 / GPU 频率与 thermal pressure，
# 按分钟对照 V2：出现降频（pressure ≠ Nominal，或频率比前 5 分钟中位数低 15% 以上）之后的 V2 ≤ 0.02% = "V2 仍达标"（必须档）；
# 引擎目前没有"降级策略"，所以只能按这一条判。1 小时里没降频 = S4 条件没触发，按全程 V2 报。
#
#   负载：scenarios/g4-show.json（§3 的 1080p60 八路标准负载 + G4 的抠像 / 叠加 / 多画面）+ headless 生成的 60 分钟 G4 场景，--record，--audio-device null。
#   频率：sudo powermetrics -f plist -i 5000 --samplers cpu_power,gpu_power,thermal（这一项必须有 sudo：在终端里跑会问一次密码）。
#   有风扇的机器（这台 M5 Max 的 MacBook Pro）：BLOCKED-机型，只写报告头不跑；--force 可以在任何机器上把整条流程走一遍（验证脚本用）。
#
# 用法：scripts/perf/s4-thermal.sh [--minutes 60] [--force] [--out-dir .build/perf/s4] [--no-build] [--skip-run] [--report reports/W4-s4-<机器>.md]
set -uo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1

minutes=60; force=0; out_dir=.build/perf/s4; do_build=1; do_run=1; report=""
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --skip-run) do_run=0; shift ;;
    --report) report="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }
mkdir -p "$out_dir"
duration=$((minutes * 60))
model=$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Model Name: //p' | head -1)
chip=$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Chip: //p' | head -1)
machine=$(python3 -c "import sys; sys.path.insert(0, 'scripts/perf'); import perfjudge as pj; print(pj.machine_tag('$chip', '$model'))")
[ -n "$report" ] || report="reports/W4-s4-$machine.md"

if [[ "$model" != *"MacBook Air"* ]] && [ "$force" = 0 ]; then
  yellow "BLOCKED-机型：$chip · $model 有风扇，S4 要无风扇机型（M1 Air 8 GB，测试标准 §2.7）。--force 可以在本机把流程走一遍（不作 S4 判定）。"
  python3 scripts/perf/s4_report.py --blocked "BLOCKED-机型：$chip · $model 有风扇" --machine "$machine" --report "$report"
  exit 0
fi

show=scenarios/g4-show.json
script="$out_dir/g4-${minutes}min.json"
stats="$out_dir/stats.jsonl"; pm_file="$out_dir/powermetrics.plist"
if [ "$do_run" = 1 ]; then
  thermal_bin=.build/soak/thermal-state
  if [ ! -x "$thermal_bin" ] || [ scripts/soak/thermal-state.swift -nt "$thermal_bin" ]; then
    mkdir -p .build/soak && swiftc -O -o "$thermal_bin" scripts/soak/thermal-state.swift 2>/dev/null || thermal_bin=""
  fi
  scripts/soak/env-snapshot.sh ${thermal_bin:+--thermal-bin "$thermal_bin"} > "$out_dir/environment.txt"
  if [ "$do_build" = 1 ]; then
    step "编译 release switcher-headless"
    swift build -c release --package-path Tools/switcher-headless 2>&1 | grep -E 'error|Build complete' | tail -3 || true
  fi
  headless="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
  [ -x "$headless" ] || { red "没编出 $headless"; exit 2; }
  "$headless" make-scenario --preset g4 --minutes "$minutes" --out "$script" >/dev/null || exit 2
  pm_ok=0
  if sudo -n true 2>/dev/null; then pm_ok=1
  elif [ -t 0 ]; then echo "powermetrics 要 root：输入本机密码（只这一次）"; sudo -v && pm_ok=1; fi
  if [ "$pm_ok" = 0 ]; then
    red "BLOCKED-sudo：S4 靠 powermetrics 记频率，没有 sudo 就没有判据（在自己的终端里跑，或 sudoers 给 /usr/bin/powermetrics NOPASSWD）"
    python3 scripts/perf/s4_report.py --blocked "BLOCKED-sudo：没有 powermetrics" --machine "$machine" --report "$report"
    exit 0
  fi
  rm -f "$stats" "$pm_file" "$out_dir/s4.mov"
  step "跑 $minutes 分钟标准负载 + powermetrics（5 s 一样）"
  "$headless" run --show "$show" --script "$script" --duration "$duration" --stats "$stats" --record "$out_dir/s4.mov" --audio-device null \
      > "$out_dir/headless.log" 2>&1 &
  headless_pid=$!
  caffeinate -u -i -d -s -w "$headless_pid" >/dev/null 2>&1 &
  echo "powermetrics_start_epoch=$(date +%s)" > "$out_dir/run.txt"
  ( sudo -n /usr/bin/powermetrics -f plist -i 5000 -n $((duration / 5 + 4)) --samplers cpu_power,gpu_power,thermal 2>"$out_dir/powermetrics.err" | cat > "$pm_file" ) &
  pm_pid=$!
  trap 'kill $headless_pid 2>/dev/null; pkill -P $pm_pid cat 2>/dev/null' EXIT
  wait "$headless_pid"; rc=$?
  echo "exit_code=$rc" >> "$out_dir/run.txt"
  sleep 1; pkill -P "$pm_pid" cat 2>/dev/null; wait "$pm_pid" 2>/dev/null
  trap - EXIT
  [ "$rc" = 0 ] || red "headless 退出码 $rc（$out_dir/headless.log）"
fi
python3 scripts/perf/s4_report.py --out-dir "$out_dir" --machine "$machine" --report "$report" $([ "$force" = 1 ] && [[ "$model" != *"MacBook Air"* ]] && echo --not-fanless)
