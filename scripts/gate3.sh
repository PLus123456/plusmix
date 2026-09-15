#!/bin/bash
# G3 检查点自动部分（落地方案 §4 G3；G3 prompt 第 2 条 a / b / d）：
#   编 release 的 switcher-headless / frameprobe → 跑 G3 场景 N 分钟（8 路合成源：1 号灰 64、2 号灰 192、1–4 号带音频；
#   第 1000 拍 Cut、第 3000 拍 Fade 30、T-bar 25/50/75、之后每 5 s Cut、每 30 s 开关 Overlay 1；录制 + 4 路 ISO 音轨 + stats + --api）
#   ＋ 同时跑 scripts/apitest 的客户端（C1 从 150 s 起、C4 随后）
#   → frameprobe stats / switches / fade / frames / av / av(多文件) → ffprobe 包表（E2 / E3 / E5）→ StatsSummary（summarize）
#   → apitest evaluate（C1–C4）→ scripts/gate3-report.py 生成 reports/G3-run-<label>.md，再拼 reports/G3-notes.md + 各次运行 → reports/G3.md。
#   L0 / L1（各包 swift test）由 make gate3 在本脚本之前跑（Makefile）；E7–E9 由 scripts/gate3-net.sh（需要用户 sudo 起 netem 代理）。
#
# 用法：scripts/gate3.sh [--minutes 10] [--label 10min] [--baseline baselines/g3-m5max.json] [--write-baseline PATH]
#                        [--out-dir .build/gate3/<label>] [--no-build] [--skip-run]（只重算已有输出）[--no-api]（不跑 C 系列）
#                        [--port 8765] [--c1-start 150] [--iso-audio 4] [--waive '指标名=理由']（用户裁定的个案放行，可多次；硬性项不能放行）
# 采集数据（stats.jsonl、out.mov、out.isoN.mov、frames.json、session.json …）留在 out-dir，不入库；报告里写路径。
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

minutes=10; label=""; baseline=""; write_baseline=""; out_dir=""; do_build=1; do_run=1; do_api=1; port=8765; c1_start=150; iso_audio=4; waives=()
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    --write-baseline) write_baseline="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --skip-run) do_run=0; shift ;;
    --no-api) do_api=0; shift ;;
    --port) port="$2"; shift 2 ;;
    --c1-start) c1_start="$2"; shift 2 ;;
    --iso-audio) iso_audio="$2"; shift 2 ;;
    --waive) waives+=(--waive "$2"); shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
[ -n "$label" ] || label="${minutes}min"
[ -n "$out_dir" ] || out_dir=".build/gate3/$label"
mkdir -p "$out_dir"
show=scenarios/g3-show.json
script=scenarios/g3.json
duration=$((minutes * 60))

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }

# ---- 0. 环境记录（测试标准 §2.8）----
env_file="$out_dir/environment.txt"
if [ "$do_run" = 1 ]; then
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
fi
step "环境：$(grep -E '^(cpu|macos|power|load_before)=' "$env_file" | tr '\n' ' ')"
if pgrep -x Cyberpunk2077 >/dev/null 2>&1 || [ "$(uptime | sed 's/.*load averages: //' | cut -d' ' -f1 | cut -d. -f1)" -ge 8 ]; then
  red "警告：机器上有其它重负载（见 $env_file），V1/V3 的数字不可信；建议等机器空闲再跑"
fi

# ---- 1. 编译 ----
if [ "$do_build" = 1 ]; then
  step "编译 release：switcher-headless、frameprobe"
  swift build -c release --package-path Tools/switcher-headless 2>&1 | grep -E 'error|Build complete' | tail -3 || true
  swift build -c release --package-path Tools/frameprobe 2>&1 | grep -E 'error|Build complete' | tail -2 || true
fi
headless="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
frameprobe="$(swift build -c release --package-path Tools/frameprobe --show-bin-path)/frameprobe"
[ -x "$headless" ] || { red "没编出 $headless"; exit 1; }
[ -x "$frameprobe" ] || { red "没编出 $frameprobe"; exit 1; }
[ -f "$show" ] || "$headless" make-show --preset g3 --out "$show"
[ -f "$script" ] || "$headless" make-scenario --preset g3 --minutes 10 --out "$script"

# ---- 2. 跑：headless（--api、录制、ISO 音轨、stats）+ apitest 客户端 ----
stats="$out_dir/stats.jsonl"; movie="$out_dir/out.mov"; run_log="$out_dir/headless.log"; session="$out_dir/session.json"
if [ "$do_run" = 1 ]; then
  if [ "$do_api" = 1 ] && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    red "端口 $port 被占：$(lsof -nP -iTCP:"$port" -sTCP:LISTEN | tail -1)"; exit 1
  fi
  rm -f "$stats" "$movie" "$out_dir"/out.iso*.mov "$session"
  api_args=(); [ "$do_api" = 1 ] && api_args=(--api --api-listen "127.0.0.1:$port")
  step "跑 $minutes 分钟：$headless run --show $show --script $script --duration $duration --stats $stats --record $movie --iso-audio $iso_audio --audio-device null ${api_args[*]}"
  load_log="$out_dir/load.log"; : > "$load_log"
  ( while true; do
      l=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)
      t=$(ps -eo pcpu,comm | sort -rn | head -5 | tail -4 | awk '{n=split($2,a,"/"); printf "%s%%%s; ", $1, a[n]}')
      echo "$(date +%T) load $l top: $t" >> "$load_log"; sleep 5
    done ) &
  sampler_pid=$!
  "$headless" run --show "$show" --script "$script" --duration "$duration" --stats "$stats" --record "$movie" --iso-audio "$iso_audio" \
      --audio-device null "${api_args[@]}" > "$run_log" 2>&1 &
  headless_pid=$!
  trap 'kill $headless_pid $sampler_pid 2>/dev/null' EXIT
  client_status=0
  if [ "$do_api" = 1 ]; then
    step "客户端：C1 50 次 cut（t0 + $c1_start s 起，相位避开 5 s 切换点），C4 2 × 100/s × 60 s，C2 / C3 全程记录"
    python3 scripts/apitest/apitest.py run --url "http://127.0.0.1:$port" --out "$session" \
      --c1-count 50 --c1-start "$c1_start" --scenario-period 5 --c4-seconds 60 --c4-rate 100 --c4-clients 2 \
      --max-seconds $((duration + 90)) 2>&1 | tee "$out_dir/apitest.log"
    client_status=${PIPESTATUS[0]}
  fi
  wait "$headless_pid"; rc=$?
  kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null
  trap - EXIT
  echo "load_after=$(uptime | sed 's/.*load averages: //')" >> "$env_file"
  tail -n 30 "$run_log"
  [ "$rc" = 0 ] || { red "headless 退出码 $rc"; exit 1; }
  [ "$client_status" = 0 ] || red "apitest 客户端退出码 $client_status（C 系列可能不完整，继续出报告）"
fi
[ -s "$stats" ] || { red "没有 $stats"; exit 1; }
[ -s "$movie" ] || { red "没有 $movie"; exit 1; }

# ---- 3. frameprobe ----
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
step "frameprobe stats（V4 / V5）"
"$frameprobe" stats "$movie" --fps "$program_fps" --input-fps "$input_fps" --max-events 20 --out "$out_dir/probe-stats.json" --markdown > "$out_dir/probe-stats.md"
step "frameprobe switches（V6）"
"$frameprobe" switches "$movie" --out "$out_dir/probe-switches.json" --markdown > "$out_dir/probe-switches.md"
step "frameprobe fade（V7 曲线：第 3000 拍 Fade 30，A = 64 / B = 192）"
"$frameprobe" fade "$movie" --fade-at 3000 --duration 30 --gray-a 64 --gray-b 192 --out "$out_dir/probe-fade.json" --markdown > "$out_dir/probe-fade.md"
step "frameprobe frames（V7 T-bar 映射 + C3 逐帧输入 ID）"
"$frameprobe" frames "$movie" --fps "$program_fps" --out "$out_dir/frames.json" > /dev/null
step "frameprobe av（A2 / A3）"
"$frameprobe" av "$movie" --fps "$program_fps" --out "$out_dir/probe-av.json" --markdown > "$out_dir/probe-av.md"
iso_files=$(ls "$out_dir"/out.iso*.mov 2>/dev/null | sort)
if [ -n "$iso_files" ]; then
  step "frameprobe av 多文件（A4：PGM + ISO 音轨 $(echo "$iso_files" | wc -l | tr -d ' ') 个）"
  # shellcheck disable=SC2086
  "$frameprobe" av "$movie" $iso_files --fps "$program_fps" --out "$out_dir/probe-av-multi.json" --markdown > "$out_dir/probe-av-multi.md"
fi
step "ffprobe（E2 / E3 / E5）"
ffprobe -v error -show_entries format=duration:stream=index,codec_type,codec_name,nb_frames,avg_frame_rate,width,height,duration,start_time -of json "$movie" > "$out_dir/ffprobe.json" 2>/dev/null || true
ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,size,flags -of csv=p=0 "$movie" > "$out_dir/packets-v.csv" 2>/dev/null || true
ffprobe -v error "$movie" > "$out_dir/ffprobe-errors.txt" 2>&1 || true

# ---- 4. StatsSummary ----
step "summarize"
sum_args=(summarize --stats "$stats" --v1-avg-ms 2)
[ -n "$baseline" ] && [ -f "$baseline" ] && sum_args+=(--baseline "$baseline")
"$headless" "${sum_args[@]}" > "$out_dir/summary.md"
"$headless" "${sum_args[@]}" --json > "$out_dir/summary.json"
if [ -n "$write_baseline" ]; then
  "$headless" summarize --stats "$stats" --write-baseline "$write_baseline" \
    --meta checkpoint=G3 --meta machine=m5max --meta "commit=$(git rev-parse --short HEAD)" --meta "scenario=$script" \
    --meta "show=$show" --meta "label=$label" --meta "macos=$(sw_vers -productVersion)" \
    --meta "power=$(grep '^power=' "$env_file" | cut -d= -f2-)" >/dev/null
  green "基线：$write_baseline"
fi

# ---- 5. C 系列评估 ----
if [ -s "$session" ]; then
  step "apitest evaluate（C1–C4）"
  python3 scripts/apitest/apitest.py evaluate --session "$session" --frames "$out_dir/frames.json" --show "$show" --fps "$program_fps" \
    --out "$out_dir/report-c.md" --json "$out_dir/summary-c.json" > /dev/null || red "C 系列有硬性项未过（看 $out_dir/report-c.md）"
fi

# ---- 6. 报告 ----
step "生成 reports/G3-run-$label.md 并拼 reports/G3.md"
python3 scripts/gate3-report.py --out-dir "$out_dir" --label "$label" --minutes "$minutes" --show "$show" --script "$script" \
  --baseline "$baseline" --run-report "reports/G3-run-$label.md" --notes reports/G3-notes.md --report reports/G3.md "${waives[@]}"
rc=$?
if [ "$rc" = 0 ]; then
  green "G3 自动项全部满足：$out_dir → reports/G3-run-$label.md → reports/G3.md（E7–E9 另见 scripts/gate3-net.sh）"
else
  red "G3 有指标未过（看 reports/G3-run-$label.md 的判定表）：$out_dir"
fi
exit $rc
