#!/bin/bash
# G2 检查点自动部分（落地方案 §4 G2；G2 prompt 第 4、5 条）：
#   编 release 的 switcher-headless / frameprobe → 跑 M0 标准负载 N 分钟（8 路合成源、每 30 s Cut、每 5 min Fade、录制 + stats）
#   → frameprobe stats / switches / av → StatsSummary（summarize）→ scripts/gate2-report.py 生成 reports/G2-run-<label>.md，
#   再把 reports/G2-notes.md（人工写的部分）+ 各次运行的结果拼成 reports/G2.md。
#
# 用法：scripts/gate2.sh [--minutes 10] [--label 10min] [--baseline baselines/m0-m5max.json] [--write-baseline PATH]
#                        [--out-dir .build/gate2/<label>] [--no-build] [--skip-run]（只重算已有输出）
# 采集数据（stats.jsonl、out.mov、frameprobe JSON）留在 out-dir，不入库；报告里写路径。
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

minutes=10; label=""; baseline=""; write_baseline=""; out_dir=""; do_build=1; do_run=1
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    --write-baseline) write_baseline="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --skip-run) do_run=0; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
[ -n "$label" ] || label="${minutes}min"
[ -n "$out_dir" ] || out_dir=".build/gate2/$label"
mkdir -p "$out_dir"
show=scenarios/m0-show.json
script=scenarios/m0.json
duration=$((minutes * 60))

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }

# ---- 0. 环境记录（测试标准 §2.8：接电源、记机型 / macOS、关闭其它占 GPU 的程序）----
env_file="$out_dir/environment.txt"
{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "commit=$(git rev-parse --short HEAD)"
  echo "branch=$(git symbolic-ref --short -q HEAD || echo detached)"
  echo "dirty=$(git status --porcelain | wc -l | tr -d ' ')"
  echo "cpu=$(sysctl -n machdep.cpu.brand_string)"
  echo "cores=$(sysctl -n hw.ncpu)"
  echo "memory_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))"
  echo "macos=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "swift=$(swift --version 2>&1 | head -1)"
  echo "ffprobe=$(ffprobe -version 2>/dev/null | head -1)"
  echo "power=$(pmset -g batt | head -1 | sed "s/.*'//;s/'.*//")"
  echo "thermal=$(pmset -g therm 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
  echo "load_before=$(uptime | sed 's/.*load averages: //')"
  echo "top_processes_before=$(ps -eo pcpu,comm | sort -rn | head -4 | tail -3 | awk '{printf "%s%%%s; ", $1, $2}' | sed 's|/.*/||g')"
} > "$env_file"
step "环境：$(grep -E '^(cpu|macos|power|load_before)=' "$env_file" | tr '\n' ' ')"
if pgrep -x Cyberpunk2077 >/dev/null 2>&1 || [ "$(uptime | sed 's/.*load averages: //' | cut -d' ' -f1 | cut -d. -f1)" -ge 8 ]; then
  red "警告：机器上有其它重负载（见 $env_file），V1/V3 的数字不可信；建议等机器空闲再跑"
fi

# ---- 1. 编译 ----
if [ "$do_build" = 1 ]; then
  step "编译 release：switcher-headless、frameprobe"
  swift build -c release --package-path Tools/switcher-headless 2>&1 | grep -E 'error|warning: unre|Compiling|Build complete' | tail -3 || true
  swift build -c release --package-path Tools/frameprobe 2>&1 | grep -E 'error|Build complete' | tail -2 || true
fi
headless="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
frameprobe="$(swift build -c release --package-path Tools/frameprobe --show-bin-path)/frameprobe"
[ -x "$headless" ] || { red "没编出 $headless"; exit 1; }
[ -x "$frameprobe" ] || { red "没编出 $frameprobe"; exit 1; }
[ -f "$show" ] || "$headless" make-show --out "$show"
[ -f "$script" ] || "$headless" make-scenario --out "$script"

# ---- 2. 跑 ----
stats="$out_dir/stats.jsonl"; movie="$out_dir/out.mov"; run_log="$out_dir/headless.log"
if [ "$do_run" = 1 ]; then
  step "跑 $minutes 分钟：$headless run --show $show --script $script --duration $duration --stats $stats --record $movie --audio-device null"
  rm -f "$stats" "$movie"
  # 运行期间每 5 s 记一次负载与前 4 个占 CPU 的进程（测试标准 §2.8 要求环境干净；出了 missed_render 靠它归因）
  load_log="$out_dir/load.log"; : > "$load_log"
  ( while true; do
      l=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)
      t=$(ps -eo pcpu,comm | sort -rn | head -5 | tail -4 | awk '{n=split($2,a,"/"); printf "%s%%%s; ", $1, a[n]}')
      echo "$(date +%T) load $l top: $t" >> "$load_log"; sleep 5
    done ) &
  sampler_pid=$!
  "$headless" run --show "$show" --script "$script" --duration "$duration" --stats "$stats" --record "$movie" --audio-device null 2>&1 | tee "$run_log"
  rc=${PIPESTATUS[0]}
  kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null
  echo "load_after=$(uptime | sed 's/.*load averages: //')" >> "$env_file"
  [ "$rc" = 0 ] || { red "headless 退出码 $rc"; exit 1; }
fi
[ -s "$stats" ] || { red "没有 $stats"; exit 1; }
[ -s "$movie" ] || { red "没有 $movie"; exit 1; }

# ---- 3. frameprobe ----
# --input-fps：按节目文件的合成源设置算每路的真实帧率（含漂移），id = 输入编号 − 1（patternID 默认值）
input_fps=$(python3 - "$show" <<'PY'
import json, sys
show = json.load(open(sys.argv[1]))
parts = []
for inp in show["inputs"]:
    s = inp["source"]["synthetic"]["settings"]
    fr = s["frameRate"]; fps = fr["numerator"] / fr["denominator"]
    fps *= 1 + s.get("clockDriftPpm", 0) / 1e6
    pid = s.get("patternID")
    if pid is None: pid = (inp["number"] - 1) % 16
    parts.append(f"{pid}={fps:.6f}")
print(",".join(parts))
PY
)
program_fps=$(python3 -c "import json,sys; fr=json.load(open('$show'))['mixer']['format']['frameRate']; print(fr['numerator']/fr['denominator'])")
step "frameprobe stats（V4 / V5，--fps $program_fps --input-fps $input_fps）"
# --out + --markdown 并用：一遍解码同时写 JSON 文件并打印人读表（60 分钟的文件每遍约 7 分钟）
"$frameprobe" stats "$movie" --fps "$program_fps" --input-fps "$input_fps" --max-events 20 --out "$out_dir/probe-stats.json" --markdown > "$out_dir/probe-stats.md"
step "frameprobe switches（V6，M0 只记录不判定）"
"$frameprobe" switches "$movie" --out "$out_dir/probe-switches.json" --markdown > "$out_dir/probe-switches.md"
step "frameprobe av（A2 / A3，M0 只记录不判定）"
"$frameprobe" av "$movie" --fps "$program_fps" --out "$out_dir/probe-av.json" --markdown > "$out_dir/probe-av.md"
step "ffprobe"
ffprobe -v error -show_entries format=duration:stream=codec_name,nb_frames,avg_frame_rate,width,height -of json "$movie" > "$out_dir/ffprobe.json" 2>/dev/null || true

# ---- 4. StatsSummary ----
step "summarize"
sum_args=(summarize --stats "$stats" --v1-avg-ms 2)
[ -n "$baseline" ] && [ -f "$baseline" ] && sum_args+=(--baseline "$baseline")
"$headless" "${sum_args[@]}" > "$out_dir/summary.md"
"$headless" "${sum_args[@]}" --json > "$out_dir/summary.json"
if [ -n "$write_baseline" ]; then
  "$headless" summarize --stats "$stats" --write-baseline "$write_baseline" \
    --meta checkpoint=G2 --meta machine=m5max --meta "commit=$(git rev-parse --short HEAD)" --meta "scenario=$script" \
    --meta "show=$show" --meta "label=$label" --meta "macos=$(sw_vers -productVersion)" \
    --meta "power=$(grep '^power=' "$env_file" | cut -d= -f2-)" >/dev/null
  green "基线：$write_baseline"
fi

# ---- 5. 报告 ----
step "生成 reports/G2-run-$label.md 并拼 reports/G2.md"
python3 scripts/gate2-report.py --out-dir "$out_dir" --label "$label" --minutes "$minutes" --show "$show" --script "$script" \
  --baseline "$baseline" --run-report "reports/G2-run-$label.md" --notes reports/G2-notes.md --report reports/G2.md
rc=$?
if [ "$rc" = 0 ]; then
  green "G2 通过标准全部满足：$out_dir → reports/G2-run-$label.md → reports/G2.md"
else
  red "G2 有指标未过（看 reports/G2-run-$label.md 的判定表）：$out_dir"
fi
exit $rc
