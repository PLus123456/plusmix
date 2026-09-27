#!/bin/bash
# S2 的 Instruments Leaks（测试标准 §2.8："Instruments 的 Allocations / Leaks 跑 S2"；prompt 70 第 4 条：配合 Leaks 跑一次 30 分钟）。
# xctrace record --template Leaks 启动 headless 跑 soak 负载（与 make soak 同一个节目 / 场景，少了推流与 NDI 以外不变——见下），到点导出 Leaks 表 →
# reports/W4-leaks.md（泄漏块数、字节、按类型 / 负责库 / 负责帧归类的前几名）。
#   - Leaks 模板会周期性挂起目标进程扫堆：这次运行的 V2 / A1 / V3 没有意义（报告只列不判），S2 的斜率以 make soak 为准。
#   - 负载：soak 预设（8 路合成源 + 摄像头（授权了才接）+ 文件 + 录制 + 2 路推流 + NDI）；--light 只跑 G4 场景 + 录制（出问题时二分用）。
# 用法：scripts/soak/leaks.sh [--minutes 30] [--out-dir .build/soak/leaks] [--light] [--no-build] [--skip-run] [--report reports/W4-leaks.md]
set -uo pipefail
# 从拷贝跑：跑的过程中有人改了这个脚本（git pull / 合并 / 编辑），正在跑的 bash 会按旧偏移读到错位的行（本会话 perf 连跑时就撞上了）。
# 先把自己拷到临时目录再 exec 拷贝，仓库里的脚本随便改，这一趟不受影响。
if [ -z "${SWITCHER_SCRIPT_COPY:-}" ]; then
  root="$(cd "$(dirname "$0")/../.." && pwd)"
  copy="$(mktemp "${TMPDIR:-/tmp}/leaks.sh.XXXXXX")" && cp "$0" "$copy" && SWITCHER_SCRIPT_COPY="$copy" SWITCHER_REPO_ROOT="$root" exec bash "$copy" "$@"
fi
cd "$SWITCHER_REPO_ROOT"
export PATH="/opt/homebrew/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1

minutes=30; out_dir=.build/soak/leaks; light=0; do_build=1; do_run=1; report=reports/W4-leaks.md
rtmp_port=19351; mtx_api_port=19998; mtx_srt_port=18891
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --light) light=1; shift ;;
    --no-build) do_build=0; shift ;;
    --skip-run) do_run=0; shift ;;
    --report) report="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }
mkdir -p "$out_dir"
duration=$((minutes * 60))
trace="$out_dir/leaks.trace"

blocked_report() {
  mkdir -p "$(dirname "$report")"
  printf '# W4-A S2 · Instruments Leaks\n\n**%s**\n\n解锁：在自己的终端里跑 `scripts/soak/leaks.sh`，Instruments 附加进程时系统会弹一次管理员密码框（"开发者工具访问"），输入即可；\n或者先执行一次 `DevToolsSecurity -enable`（管理员，之后 _developer 组的账号附加不再问）。生成：%s。\n' \
    "$1" "$(date '+%Y-%m-%d %H:%M')" > "$report"
  yellow "$1 → $report"
}

if [ "$do_run" = 1 ]; then
  command -v xctrace >/dev/null || { red "没有 xctrace（装 Xcode）"; exit 2; }
  # 本机"开发者工具访问"没开时，Instruments 附加进程要当场输管理员密码；非交互环境里没人输，xctrace 会一直挂着（目标进程停在 T 状态）
  if DevToolsSecurity -status 2>&1 | grep -qi disabled; then
    if [ -t 0 ]; then
      yellow "开发者工具访问没开（DevToolsSecurity）：马上会弹一次管理员密码框，请输入（或先 DevToolsSecurity -enable）"
    else
      blocked_report "BLOCKED-权限：开发者工具访问没开，非交互环境里没人输管理员密码，Instruments 附加不上（$(date '+%F %T')）"
      exit 0
    fi
  fi
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
  run_args=()
  mtx_pid=""
  if [ "$light" = 1 ]; then
    "$headless" make-scenario --preset g4 --minutes "$minutes" --out "$out_dir/scenario.json" >/dev/null || exit 2
    run_args=(run --show "$PWD/scenarios/g4-show.json" --script "$PWD/$out_dir/scenario.json")
  else
    scripts/perf/make-e4-clip.sh --out .build/perf/e4 >/dev/null || exit 2
    # 摄像头：与 soak.sh 同一条规则（已授权才接；Leaks 这一趟不弹授权框）
    cam=none
    if swiftc -O -o .build/soak/camera-auth scripts/soak/camera-auth.swift 2>/dev/null && [ "$(.build/soak/camera-auth status)" = "video=authorized" ]; then cam=auto; fi
    "$headless" make-show --preset soak --camera "$cam" --file .build/perf/e4/e4-source.mov --out "$out_dir/soak-show.json" >/dev/null || exit 2
    "$headless" make-scenario --preset soak --minutes "$minutes" --out "$out_dir/soak.json" >/dev/null || exit 2
    MTX_RTMPADDRESS="127.0.0.1:$rtmp_port" MTX_APIADDRESS="127.0.0.1:$mtx_api_port" MTX_SRTADDRESS="127.0.0.1:$mtx_srt_port" MTX_PATHDEFAULTS_RECORD=no \
      mediamtx scripts/mediamtx.yml > "$out_dir/mediamtx.log" 2>&1 &
    mtx_pid=$!
    for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$mtx_api_port/v3/paths/list" >/dev/null 2>&1 && break; sleep 0.2; done
    run_args=(run --show "$PWD/$out_dir/soak-show.json" --script "$PWD/$out_dir/soak.json" --ndi-send "Switcher leaks"
              --stream "rtmp://127.0.0.1:$rtmp_port/s1" --stream "rtmp://127.0.0.1:$rtmp_port/s2")
    echo "camera=$cam" > "$out_dir/run.txt"
  fi
  run_args+=(--duration "$duration" --stats "$PWD/$out_dir/stats.jsonl" --record "$PWD/$out_dir/leaks.mov" --audio-device null)
  rm -rf "$trace" "$out_dir/stats.jsonl" "$out_dir/leaks.mov"
  step "xctrace record --template Leaks（$minutes 分钟）：${run_args[*]}"
  # time-limit 多给 3 分钟：headless 自己按 --duration 停、收尾（录制封口 / 推流排空），xctrace 等目标退出后收 trace
  caffeinate -u -i -d -s xctrace record --template Leaks --time-limit "$((duration + 180))s" --output "$trace" --launch -- "$headless" "${run_args[@]}" \
      > "$out_dir/xctrace.log" 2>&1 &
  xc_pid=$!
  # 看门狗：90 s 内还没有 stats.jsonl = 目标进程一直没被放行（多半是授权框没人点），停掉，不要挂一整晚
  for _ in $(seq 1 90); do [ -s "$out_dir/stats.jsonl" ] && break; kill -0 "$xc_pid" 2>/dev/null || break; sleep 1; done
  if [ ! -s "$out_dir/stats.jsonl" ] && kill -0 "$xc_pid" 2>/dev/null; then
    kill -INT "$xc_pid" 2>/dev/null; sleep 3; kill -9 "$xc_pid" 2>/dev/null
    pkill -9 -f "$headless run" 2>/dev/null
    [ -n "$mtx_pid" ] && kill "$mtx_pid" 2>/dev/null
    blocked_report "BLOCKED-权限：xctrace 启动 90 s 了目标进程还没跑起来（停在等附加），多半是开发者工具访问的授权框没人确认"
    exit 0
  fi
  wait "$xc_pid"; rc=$?
  echo "xctrace_exit=$rc" >> "$out_dir/run.txt"
  [ -n "$mtx_pid" ] && kill "$mtx_pid" 2>/dev/null
  [ -d "$trace" ] || { red "没有 trace（$out_dir/xctrace.log）"; tail -20 "$out_dir/xctrace.log"; exit 1; }
fi
step "导出 Leaks 表"
xctrace export --input "$trace" --toc > "$out_dir/toc.xml" 2>"$out_dir/export.err" || { red "xctrace export --toc 失败"; cat "$out_dir/export.err"; exit 1; }
python3 scripts/soak/leaks_report.py --out-dir "$out_dir" --trace "$trace" --minutes "$minutes" --report "$report" $([ "$light" = 1 ] && echo --light)
