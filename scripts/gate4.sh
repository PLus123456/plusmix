#!/bin/bash
# G4 检查点自动部分（落地方案 §4 G4；G4 prompt 第 2 条 L2）：与 scripts/gate3.sh 同一条流水线，换成 G4 场景：
#   scenarios/g4-show.json（G3 的 8 路噪声底纹合成源 + 5–8 号抠像 + Overlay 1–4 各挂一路 + 9 号 Stinger PNG + 多画面自定义布局）
#   scenarios/g4.json（前 2 分钟同 G3：1000 Cut / 3000 Fade 30 / T-bar；120 s 起每 5 s 按 Cut / Fade / Wipe / Zoom / Stinger 轮流、每 15 s 翻一路叠加）
#   ＋ scripts/apitest 客户端（C1 从 150 s 起、相位 x.7 s 避开 0.4 s 的转场；C4 随后）
#   → frameprobe（W1-A3 起自证解码默认开：转场合成帧由帧内证据判成解不出，不再需要 --blank-ticks；--legacy-blank-ticks 回到 G4 第一版从场景文件标拍段的口径）
#   → frameprobe wipe / zoom（V7：场景里第一次 Wipe / Zoom 的进度曲线，W1-A3 的量法）
#   → ffprobe（E2 / E3 / E5）→ summarize → apitest evaluate（C1–C4）→ scripts/gate3-report.py --checkpoint G4 → reports/G4-run-<label>.md → reports/G4.md。
#   L0 / L1（各包 swift test，含 W3-B 的 V8 参考图集）由 make gate4 在本脚本之前跑；NDI 回环 L1 是 scripts/gate4-ndi.sh，编译矩阵是 scripts/gate4-matrix.sh，
#   E7–E9 沿用 G3（reports/G3-net.md：W3 五路没动推流），C5 的真 Companion 是人工项（docs/checklists/G4.md）。
#
# 用法：scripts/gate4.sh [--minutes 10] [--label 10min] [--baseline baselines/g3-m5max.json] [--write-baseline baselines/g4-m5max.json]
#                        [--out-dir .build/gate4/<label>] [--no-build] [--skip-run] [--no-api] [--port 8765] [--c1-start 150] [--c1-phase 0.7] [--iso-audio 4]
#                        [--waive '指标名=理由'] [--legacy-blank-ticks] [--checkpoint G4]
# 采集数据留在 out-dir，不入库；报告里写路径。
# --checkpoint（G6 加，默认 G4 = 老行为）：运行报告写 reports/<检查点>-run-<label>.md、基线 meta 的 checkpoint 跟着写；
#   只有 G4 才把运行报告拼进 reports/G4.md（G4-notes.md + 全部 G4-run-*.md 是 G4 的报告形态），别的检查点拼出来的整份放在 out-dir 里不入库——
#   G5 / W5-C / W5-E 都撞过"跑一次 gate4 就改了 reports/G4.md 和 g4 基线、要手工还原"（reports/issues/W1B3-g5-ownership-run-report-file.md、各报告 §5）。
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

minutes=10; label=""; baseline=""; write_baseline=""; out_dir=""; do_build=1; do_run=1; do_api=1; port=8765; c1_start=150; c1_phase=0.7; iso_audio=4; waives=(); legacy_blank=0; checkpoint="G4"
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
    --c1-phase) c1_phase="$2"; shift 2 ;;
    --iso-audio) iso_audio="$2"; shift 2 ;;
    --waive) waives+=(--waive "$2"); shift 2 ;;
    --legacy-blank-ticks) legacy_blank=1; shift ;;
    --checkpoint) checkpoint="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
[ -n "$label" ] || label="${minutes}min"
[ -n "$out_dir" ] || out_dir=".build/gate4/$label"
mkdir -p "$out_dir"
show=scenarios/g4-show.json
script=scenarios/g4.json
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
  echo "top_processes_before=$(ps -eo pcpu,comm | tail -n +2 | sort -rn | head -3 | awk '{printf "%s%%%s; ", $1, $2}' | sed 's|/.*/||g')"
} > "$env_file"
fi
step "环境：$(grep -E '^(cpu|macos|power|load_before)=' "$env_file" | tr '\n' ' ')"
if pgrep -x Cyberpunk2077 >/dev/null 2>&1 || [ "$(uptime | sed 's/.*load averages: //' | cut -d' ' -f1 | cut -d. -f1)" -ge 8 ]; then
  red "警告：机器上有其它重负载（见 ${env_file}），V1/V3 的数字不可信；建议等机器空闲再跑"
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
[ -f "$show" ] || "$headless" make-show --preset g4 --out "$show"
[ -f "$script" ] || "$headless" make-scenario --preset g4 --minutes 10 --out "$script"
[ -f scenarios/g4-stinger.png ] || "$headless" make-show --preset g4 --out "$show"

# 非 Cut 转场的中间拍 [t + 1, t + d]（fade 事件；setTransition(t − 1) + autoTransition(t)）——frameprobe --blank-ticks
blank_ticks=$(python3 - "$script" <<'PY'
import json, sys
sc = json.load(open(sys.argv[1]))
windows = []; pending = None
for e in sc["events"]:
    if e["tick"] < 7200: continue
    c = e["command"]
    if "fade" in c: windows.append((e["tick"] + 1, e["tick"] + c["fade"]["durationTicks"]))
    elif "setTransition" in c: pending = c["setTransition"]["durationTicks"]
    elif "autoTransition" in c and pending is not None: windows.append((e["tick"] + 1, e["tick"] + pending)); pending = None
print(",".join(f"{a}-{b}" for a, b in windows))
PY
)
if [ "$legacy_blank" = 1 ]; then
  step "frameprobe --blank-ticks（老口径）：$(echo "$blank_ticks" | tr ',' '\n' | wc -l | tr -d ' ') 段（首 3 段 $(echo "$blank_ticks" | cut -d, -f1-3)）"
else
  step "frameprobe 自证解码（W1-A3）默认开，不带 --blank-ticks（场景里非 Cut 转场 $(echo "$blank_ticks" | tr ',' '\n' | wc -l | tr -d ' ') 段，只写进报告作对照）"
  blank_ticks=""
fi
# V7 的 Wipe / Zoom：场景里第一次 setTransition(wipe|zoom) + autoTransition 的拍与时长；方向从节目文件取
read -r wipe_at wipe_d zoom_at zoom_d wipe_dir <<< "$(python3 - "$script" "$show" <<'PY'
import json, sys
sc = json.load(open(sys.argv[1])); show = json.load(open(sys.argv[2]))
pending = None; first = {}
for e in sc["events"]:
    c = e["command"]
    if "setTransition" in c: pending = (c["setTransition"]["type"], c["setTransition"]["durationTicks"])
    elif "autoTransition" in c and pending:
        first.setdefault(pending[0], (e["tick"], pending[1])); pending = None
w = first.get("wipe", (0, 0)); z = first.get("zoom", (0, 0))
print(w[0], w[1], z[0], z[1], show["mixer"]["transition"].get("wipe", {}).get("direction", "leftToRight"))
PY
)"

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
      # 先 tail -n +2 去掉表头再排：以前 sort -rn 把 "%CPU" 当 0 排到末尾，tail -4 跳掉的是最忙的那个进程（W5-E 报告 §5 第 4 条）
      t=$(ps -eo pcpu,comm | tail -n +2 | sort -rn | head -4 | awk '{n=split($2,a,"/"); printf "%s%%%s; ", $1, a[n]}')
      echo "$(date +%T) load $l top: $t" >> "$load_log"; sleep 5
    done ) &
  sampler_pid=$!
  "$headless" run --show "$show" --script "$script" --duration "$duration" --stats "$stats" --record "$movie" --iso-audio "$iso_audio" \
      --audio-device null ${api_args[@]+"${api_args[@]}"} > "$run_log" 2>&1 &
  headless_pid=$!
  # 用户不在（合盖 / 锁屏 / 空闲）时 macOS 的电源与定时器策略会让生产者线程晚醒 10–18 ms（G4 第二批合入的 g4c / g4d：V4 设计外 8–25 帧、V2 1 帧），
  # 声明"用户活跃 + 不许空闲 / 显示器 / 系统睡眠"后同一场景迟到 0、唤醒 ≤ 0.11 ms（g4e 19 / 19）。-w 跟着 headless 的进程活，它退出就退出。
  caffeinate -u -i -d -s -w "$headless_pid" >/dev/null 2>&1 &
  caffeinate_pid=$!
  trap 'kill $headless_pid $sampler_pid $caffeinate_pid 2>/dev/null' EXIT
  client_status=0
  if [ "$do_api" = 1 ]; then
    step "客户端：C1 50 次 cut（t0 + $c1_start s 起，相位 $c1_phase s：转场 0.4 s 已结束、离 5 s 切换点 ≥ 0.4 s），C4 2 × 100/s × 60 s，C2 / C3 全程记录"
    python3 scripts/apitest/apitest.py run --url "http://127.0.0.1:$port" --out "$session" \
      --c1-count 50 --c1-start "$c1_start" --c1-phase "$c1_phase" --scenario-period 5 --c4-seconds 60 --c4-rate 100 --c4-clients 2 \
      --max-seconds $((duration + 90)) 2>&1 | tee "$out_dir/apitest.log"
    client_status=${PIPESTATUS[0]}
  fi
  wait "$headless_pid"; rc=$?
  kill "$sampler_pid" "$caffeinate_pid" 2>/dev/null; wait "$sampler_pid" "$caffeinate_pid" 2>/dev/null
  trap - EXIT
  echo "load_after=$(uptime | sed 's/.*load averages: //')" >> "$env_file"
  tail -n 30 "$run_log"
  [ "$rc" = 0 ] || { red "headless 退出码 $rc"; exit 1; }
  [ "$client_status" = 0 ] || red "apitest 客户端退出码 ${client_status}（C 系列可能不完整，继续出报告）"
fi
[ -s "$stats" ] || { red "没有 $stats"; exit 1; }
[ -s "$movie" ] || { red "没有 $movie"; exit 1; }

# ---- 3. frameprobe ----
# 注意：macOS 自带 bash 3.2 在 set -u 下把空数组的 "${arr[@]}" 当未定义变量，空数组一律写成 ${arr[@]+"${arr[@]}"}（bt / api_args / waives）
input_fps=$(python3 - "$show" <<'PY'
import json, sys
show = json.load(open(sys.argv[1]))
parts = []
for inp in show["inputs"]:
    syn = inp["source"].get("synthetic")
    if not syn: continue
    s = syn["settings"]
    fr = s["frameRate"]; fps = fr["numerator"] / fr["denominator"]
    fps *= 1 + s.get("clockDriftPpm", 0) / 1e6
    pid = s.get("patternID")
    if pid is None: pid = (inp["number"] - 1) % 16
    parts.append(f"{pid}={fps:.6f}")
print(",".join(parts))
PY
)
program_fps=$(python3 -c "import json,sys; fr=json.load(open('$show'))['mixer']['format']['frameRate']; print(fr['numerator']/fr['denominator'])")
bt=(); [ -n "$blank_ticks" ] && bt=(--blank-ticks "$blank_ticks")
step "frameprobe stats（V4 / V5）"
"$frameprobe" stats "$movie" --fps "$program_fps" --input-fps "$input_fps" --max-events 20 ${bt[@]+"${bt[@]}"} --out "$out_dir/probe-stats.json" --markdown > "$out_dir/probe-stats.md"
step "frameprobe switches（V6）"
"$frameprobe" switches "$movie" ${bt[@]+"${bt[@]}"} --out "$out_dir/probe-switches.json" --markdown > "$out_dir/probe-switches.md"
step "frameprobe fade（V7 曲线：第 3000 拍 Fade 30，A = 64 / B = 192）"
"$frameprobe" fade "$movie" --fade-at 3000 --duration 30 --gray-a 64 --gray-b 192 --out "$out_dir/probe-fade.json" --markdown > "$out_dir/probe-fade.md"
if [ "${wipe_at:-0}" -gt 0 ]; then
  step "frameprobe wipe（V7：第 $wipe_at 拍 Wipe $wipe_dir $wipe_d 拍，W1-A3 的擦边 50% 点量法）"
  "$frameprobe" wipe "$movie" --at "$wipe_at" --duration "$wipe_d" --wipe-direction "$wipe_dir" --fps "$program_fps" --out "$out_dir/probe-wipe.json" --markdown > "$out_dir/probe-wipe.md"
fi
if [ "${zoom_at:-0}" -gt 0 ]; then
  step "frameprobe zoom（V7：第 $zoom_at 拍 Zoom $zoom_d 拍，中心行带新画面宽度）"
  "$frameprobe" zoom "$movie" --at "$zoom_at" --duration "$zoom_d" --fps "$program_fps" --out "$out_dir/probe-zoom.json" --markdown > "$out_dir/probe-zoom.md"
fi
step "frameprobe frames（V7 T-bar 映射 + C3 逐帧输入 ID）"
"$frameprobe" frames "$movie" --fps "$program_fps" ${bt[@]+"${bt[@]}"} --out "$out_dir/frames.json" > /dev/null
step "frameprobe av（A2 / A3）"
"$frameprobe" av "$movie" --fps "$program_fps" ${bt[@]+"${bt[@]}"} --out "$out_dir/probe-av.json" --markdown > "$out_dir/probe-av.md"
iso_files=$(ls "$out_dir"/out.iso*.mov 2>/dev/null | sort)
if [ -n "$iso_files" ]; then
  step "frameprobe av 多文件（A4：PGM + ISO 音轨 $(echo "$iso_files" | wc -l | tr -d ' ') 个）"
  # shellcheck disable=SC2086
  "$frameprobe" av "$movie" $iso_files --fps "$program_fps" ${bt[@]+"${bt[@]}"} --out "$out_dir/probe-av-multi.json" --markdown > "$out_dir/probe-av-multi.md"
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
    --meta "checkpoint=$checkpoint" --meta machine=m5max --meta "commit=$(git rev-parse --short HEAD)" --meta "scenario=$script" \
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
run_report="reports/$checkpoint-run-$label.md"
if [ "$checkpoint" = G4 ]; then
  report=reports/G4.md; notes=reports/G4-notes.md
  step "生成 $run_report 并拼 $report"
else
  # 别的检查点：运行报告入库，拼出来的整份只留在 out-dir（它们的报告是 reports/<检查点>.md 手写的五段 / §7 模板，不是 notes + run 的形态）
  report="$out_dir/$checkpoint-assembled.md"; notes="reports/$checkpoint-notes.md"
  step "生成 ${run_report}（拼好的整份只放 ${report}，不入库；判定口径与 G4 相同）"
fi
python3 scripts/gate3-report.py --checkpoint G4 --out-dir "$out_dir" --label "$label" --minutes "$minutes" --show "$show" --script "$script" \
  --baseline "$baseline" --blank-ticks "$blank_ticks" --run-report "$run_report" --notes "$notes" --report "$report" ${waives[@]+"${waives[@]}"}
rc=$?
if [ "$rc" = 0 ]; then
  green "$checkpoint 自动项全部满足（G4 口径）：$out_dir → $run_report → ${report}（NDI 回环 L1：scripts/gate4-ndi.sh；编译矩阵：scripts/gate4-matrix.sh）"
else
  red "$checkpoint 有指标未过（看 $run_report 的判定表）：$out_dir"
fi
exit $rc
