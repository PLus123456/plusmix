#!/bin/bash
# make perf-baseline（W4-A，测试标准 §5 L5 性能回归；prompt 70 第 3 条）：固定场景 5 分钟量 V1–V3、S3，再量 E4；与同机、同 macOS 大版本的上一版基线比，
# 任何一项退步 > 10%（E4 另按 §4：VMAF 降 > 1 分）或掉出 §4 必须档 → 非零退出。
#
#   场景：scenarios/g4-show.json + scenarios/g4.json 的前 5 分钟（G4 的负载：8 路噪声底纹合成源、5–8 号抠像、Overlay 1–4 动画、Stinger PNG、
#         多画面自定义布局、五种转场），--record + --iso-audio 4 + --audio-device null；不起 API（C 系列不归 L5，客户端的负载会让 CPU 抖）。
#   S3：CPU = stats.jsonl 的 cpu_pct（进程级，100 = 一个核）avg / p95；GPU = gpu_pct（IOKit Device Utilization，§3 S3 的正式口径）avg / p95，
#       有 sudo 时另用 powermetrics（-f plist，1 s 一样，GPU 占用 = 1 − idle_ratio）作对照（prompt 70："GPU 用 powermetrics，sudo 我给"）。
#   E4：scripts/perf/make-e4-clip.sh 的固定片段（静态 / 慢动 / 高动态各 10 s，ProRes 源）→ headless 文件输入（--preset perf-e4）→ 编码 → 录制；
#       逐帧亮度均值对齐录像与源，ffmpeg libvmaf（vmaf_v0.6.1，另出 PSNR-Y / SSIM）对源；没有 libvmaf 退到 psnr 滤镜。
#   基线：baselines/perf-<机器>-macos<大版本>.json（机器 = 芯片 + Air 标记，如 m5max / m1air）；同系统没有基线时这次就是第一版（写入、不判退步）；
#         已有时只在 --write-baseline 时覆盖（每个正式版本的 L5 结果存进仓库，§5）。baselines/g4-m5max.json（macOS 26.6.2）只作参考列、不判。
#
# 用法：scripts/perf/perf-baseline.sh [--minutes 5] [--label perf] [--out-dir .build/perf/<label>] [--no-build] [--skip-run] [--no-e4]
#                                     [--powermetrics auto|on|off] [--write-baseline] [--rules scripts/perf/regression.json] [--report <md>] [--baseline-dir baselines]
#                                     [--ambient "约 24 °C"]（室温，写进报告头；本机读不到）
#   --powermetrics auto：sudo -n 可用（刚 sudo -v 过，或 sudoers 给了 /usr/bin/powermetrics NOPASSWD）就采；在终端里先问一句要不要（60 s 不答 = 不采）；
#                        非交互（CI）不采。on：直接在终端里 sudo -v 问密码；off：不采。
#   --skip-run：只用 out-dir 里已有的产物重出报告（不跑、不算 VMAF 以外的东西）。
# 跑的时候别跑 App 测试 / 大编译（prompt 70 第 7 条）：脚本开头会列出机器上在跑的编译 / 测试进程并写进报告。
set -uo pipefail
# 从拷贝跑：跑的过程中有人改了这个脚本（git pull / 合并 / 编辑），正在跑的 bash 会按旧偏移读到错位的行（本会话 perf 连跑时就撞上了）。
# 先把自己拷到临时目录再 exec 拷贝，仓库里的脚本随便改，这一趟不受影响。
if [ -z "${SWITCHER_SCRIPT_COPY:-}" ]; then
  root="$(cd "$(dirname "$0")/../.." && pwd)"
  copy="$(mktemp "${TMPDIR:-/tmp}/perf-baseline.sh.XXXXXX")" && cp "$0" "$copy" && SWITCHER_SCRIPT_COPY="$copy" SWITCHER_REPO_ROOT="$root" exec bash "$copy" "$@"
fi
cd "$SWITCHER_REPO_ROOT"
export PATH="/opt/homebrew/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1

minutes=5; label=perf; out_dir=""; do_build=1; do_run=1; do_e4=1; pm_mode=auto; write_baseline=0
rules=scripts/perf/regression.json; report=""; baseline_dir=baselines; ambient=""
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --skip-run) do_run=0; shift ;;
    --no-e4) do_e4=0; shift ;;
    --powermetrics) pm_mode="$2"; shift 2 ;;
    --write-baseline) write_baseline=1; shift ;;
    --rules) rules="$2"; shift 2 ;;
    --report) report="$2"; shift 2 ;;
    --baseline-dir) baseline_dir="$2"; shift 2 ;;
    --ambient) ambient="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
[ -n "$out_dir" ] || out_dir=".build/perf/$label"
mkdir -p "$out_dir"
duration=$((minutes * 60))
show=scenarios/g4-show.json; script=scenarios/g4.json

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }

command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { red "没有 ffmpeg / ffprobe（brew install ffmpeg）"; exit 2; }
[ -f "$show" ] && [ -f "$script" ] || { red "缺 $show / ${script}（G4 检查点入库的场景；scenarios/ 不归 W4-A，本脚本不生成）"; exit 2; }

# ---- 0. 环境（§2.8：接电源、关低电量模式、记录机型和 macOS、关掉占 GPU 的程序；§7 报告头）----
env_file="$out_dir/environment.txt"
thermal_bin=.build/soak/thermal-state
if [ ! -x "$thermal_bin" ] || [ scripts/soak/thermal-state.swift -nt "$thermal_bin" ]; then
  mkdir -p .build/soak && swiftc -O -o "$thermal_bin" scripts/soak/thermal-state.swift 2>/dev/null || thermal_bin=""
fi
if [ "$do_run" = 1 ]; then
  scripts/soak/env-snapshot.sh ${thermal_bin:+--thermal-bin "$thermal_bin"} ${ambient:+--ambient "$ambient"} > "$env_file"
  step "环境：$(grep -E '^(chip|model|macos|power|low_power_mode|load_before)=' "$env_file" | tr '\n' ' ')"
  busy=$(grep '^busy_processes=' "$env_file" | cut -d= -f2-)
  [ -n "$busy" ] && yellow "机器上还有编译 / 测试进程在跑（数字会偏高，报告里会注明）：$busy"
  grep -q '^power=AC' "$env_file" || yellow "没接电源（§2.8 要求接电源）：$(grep '^power=' "$env_file")"
  grep -q '^low_power_mode=0' "$env_file" || yellow "低电量模式开着或读不到（§2.8 要求关）"
fi

# ---- 1. 编译 ----
if [ "$do_build" = 1 ] && [ "$do_run" = 1 ]; then
  step "编译 release switcher-headless"
  swift build -c release --package-path Tools/switcher-headless 2>&1 | grep -E 'error|Build complete' | tail -3 || true
fi
headless="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
[ -x "$headless" ] || { red "没编出 $headless"; exit 2; }

# ---- 2. powermetrics（sudo）----
pm_file="$out_dir/powermetrics.plist"
pm_ok=0
if [ "$do_run" = 1 ] && [ "$pm_mode" != off ]; then
  if sudo -n true 2>/dev/null; then
    pm_ok=1
  elif [ "$pm_mode" = on ] && [ -t 0 ]; then
    echo "powermetrics 要 root：输入本机密码（只这一次，脚本里的 sudo 都是 -n）"
    sudo -v && pm_ok=1
  elif [ -t 0 ]; then
    # auto + 终端：问一句，60 s 没人答就跳过
    ans=""; read -r -t 60 -p "要采 powermetrics（GPU 对照，要 sudo 密码）吗？[y/N]（60 s 不答 = 不采）" ans || true; echo
    if [ "$ans" = y ] || [ "$ans" = Y ]; then sudo -v && pm_ok=1; fi
  fi
  if [ "$pm_ok" = 0 ]; then
    yellow "powermetrics 不采（sudo 要密码；在自己的终端跑 make perf-baseline PERF_ARGS='--powermetrics on'，或 sudoers 给 /usr/bin/powermetrics NOPASSWD）；GPU 用 IOKit 口径"
  fi
fi

# ---- 3. 跑 5 分钟 ----
stats="$out_dir/stats.jsonl"; movie="$out_dir/perf.mov"; run_log="$out_dir/headless.log"
if [ "$do_run" = 1 ]; then
  rm -f "$stats" "$movie" "$out_dir"/perf.iso*.mov "$pm_file"
  step "跑 $minutes 分钟：G4 场景 + 录制 + 4 路 ISO 音轨（不起 API）"
  load_log="$out_dir/load.log"; : > "$load_log"
  ( while true; do
      l=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)
      t=$(ps -Ao pcpu,comm -r | sed -n '2,5p' | awk '{n=split($2,a,"/"); printf "%s%%%s; ", $1, a[n]}')
      echo "$(date +%s) $(date +%T) load $l top: $t" >> "$load_log"; sleep 5
    done ) &
  sampler_pid=$!
  "$headless" run --show "$show" --script "$script" --duration "$duration" --stats "$stats" --record "$movie" --iso-audio 4 \
      --audio-device null > "$run_log" 2>&1 &
  headless_pid=$!
  # 无人值守必须 -u -i -d -s（prompt 70 第 7 条；只 -i 时用户"空闲"下实时线程会晚醒 10–18 ms，G4 的 g4c / g4d）
  caffeinate -u -i -d -s -w "$headless_pid" >/dev/null 2>&1 &
  caffeinate_pid=$!
  pm_pid=""
  if [ "$pm_ok" = 1 ]; then
    # 等过 --lead-ms（1 s）再采，只覆盖运行中段；-n 到点自己退出。管道另一头是本用户的 cat：提前结束时杀掉 cat，powermetrics 下一次写就 SIGPIPE 退出
    ( sleep 2; sudo -n /usr/bin/powermetrics -f plist -i 1000 -n $((duration - 4)) --samplers cpu_power,gpu_power,thermal 2>"$out_dir/powermetrics.err" | cat > "$pm_file" ) &
    pm_pid=$!
  fi
  trap 'kill $headless_pid $sampler_pid $caffeinate_pid 2>/dev/null; [ -n "$pm_pid" ] && pkill -P "$pm_pid" cat 2>/dev/null' EXIT
  wait "$headless_pid"; rc=$?
  kill "$sampler_pid" "$caffeinate_pid" 2>/dev/null; wait "$sampler_pid" "$caffeinate_pid" 2>/dev/null
  [ -n "$pm_pid" ] && { sleep 1; pkill -P "$pm_pid" cat 2>/dev/null; wait "$pm_pid" 2>/dev/null; }
  trap - EXIT
  echo "load_after=$(uptime | sed 's/.*load averages: //')" >> "$env_file"
  echo "busy_processes_after=$(scripts/soak/env-snapshot.sh --busy-only)" >> "$env_file"
  [ -n "$thermal_bin" ] && echo "thermal_state_after=$("$thermal_bin" | sed 's/^thermal=//; s/ low_power=.*//')" >> "$env_file"
  tail -n 12 "$run_log"
  [ "$rc" = 0 ] || { red "headless 退出码 ${rc}（${run_log}）"; exit 1; }
fi
[ -s "$stats" ] || { red "没有 $stats"; exit 1; }

# ---- 4. E4 ----
e4_dir="$out_dir/e4"
if [ "$do_e4" = 1 ]; then
  mkdir -p "$e4_dir"
  scripts/perf/make-e4-clip.sh --out .build/perf/e4 || { red "E4 片段生成失败"; exit 2; }
  clip=.build/perf/e4/e4-source.mov
  if [ "$do_run" = 1 ]; then
    step "E4：文件输入 → 编码 → 录制（30 s 片段）"
    "$headless" make-show --preset perf-e4 --file "$clip" --out "$e4_dir/e4-show.json" >/dev/null
    rm -f "$e4_dir/e4.mov" "$e4_dir/vmaf.json"
    "$headless" run --show "$e4_dir/e4-show.json" --duration 31 --stats "$e4_dir/e4-stats.jsonl" --record "$e4_dir/e4.mov" \
        --audio-device null > "$e4_dir/headless.log" 2>&1 &
    e4_pid=$!
    caffeinate -u -i -d -s -w "$e4_pid" >/dev/null 2>&1 &
    wait "$e4_pid" || { red "E4 的 headless 退出码非零（$e4_dir/headless.log）"; exit 1; }
    # 对齐：两边都转成 8-bit 4:2:0 再取逐帧 Y 均值（源是 10-bit，直接取是 4 倍刻度）
    yavg() {
      ffmpeg -hide_banner -loglevel error -i "$1" -vf "scale=320:180:flags=area,format=yuv420p,signalstats,metadata=mode=print:key=lavfi.signalstats.YAVG:file=$2" -f null - \
        || { red "取 $1 的亮度序列失败"; exit 1; }
    }
    yavg "$e4_dir/e4.mov" "$e4_dir/rec-yavg.txt"
    yavg "$clip" "$e4_dir/src-yavg.txt"
    offset=$(python3 - "$e4_dir" <<'PY'
import re, sys
sys.path.insert(0, "scripts/perf")
import perfjudge as pj
d = sys.argv[1]
load = lambda p: [float(m.group(1)) for m in re.finditer(r"YAVG=([0-9.]+)", open(p).read())]
k, cost = pj.align_offset(load(f"{d}/rec-yavg.txt"), load(f"{d}/src-yavg.txt"), 120)
open(f"{d}/alignment.txt", "w").write(f"offset={k}\ncost={cost}\n")
print(k if k is not None else -1)
PY
)
    [ "$offset" -ge 0 ] 2>/dev/null || { red "E4 对齐失败（$e4_dir/alignment.txt）"; exit 1; }
    frames=$(python3 -c "import json; print(json.load(open('.build/perf/e4/e4-source.json'))['frames'])")
    if ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' libvmaf '; then
      step "E4：libvmaf（录像第 $offset 帧起对源第 0 帧，$frames 帧）"
      ffmpeg -hide_banner -loglevel error -i "$e4_dir/e4.mov" -i "$clip" -filter_complex \
        "[0:v]trim=start_frame=$offset:end_frame=$((offset + frames)),setpts=PTS-STARTPTS,format=yuv420p[d];[1:v]trim=end_frame=$frames,setpts=PTS-STARTPTS,format=yuv420p[r];[d][r]libvmaf=log_path=$e4_dir/vmaf.json:log_fmt=json:n_threads=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 8):feature=name=psnr|name=float_ssim" \
        -f null - || { red "libvmaf 失败"; exit 1; }
    else
      step "E4：没有 libvmaf，退到 PSNR"
      ffmpeg -hide_banner -loglevel error -i "$e4_dir/e4.mov" -i "$clip" -filter_complex \
        "[0:v]trim=start_frame=$offset:end_frame=$((offset + frames)),setpts=PTS-STARTPTS,format=yuv420p[d];[1:v]trim=end_frame=$frames,setpts=PTS-STARTPTS,format=yuv420p[r];[d][r]psnr=stats_file=$e4_dir/psnr.log" \
        -f null - || { red "psnr 失败"; exit 1; }
    fi
  fi
fi

# ---- 5. StatsSummary（summary 段与 G2–G4 的基线同结构，headless summarize --baseline 能直接读）----
"$headless" summarize --stats "$stats" --write-baseline "$out_dir/summary-baseline.json" \
  --meta checkpoint=W4-A-L5 --meta "commit=$(git rev-parse --short HEAD)" --meta "scenario=${script}（前 $minutes 分钟）" \
  --meta "show=$show" --meta "label=$label" --meta "macos=$(sw_vers -productVersion)" >/dev/null 2>&1 || { red "summarize 失败"; exit 1; }

# ---- 6. 判定 + 报告 + 基线 ----
args=(--out-dir "$out_dir" --label "$label" --minutes "$minutes" --show "$show" --script "$script" --rules "$rules" --baseline-dir "$baseline_dir"
      --reference baselines/g4-m5max.json)
[ -n "$report" ] && args+=(--report "$report")
[ "$write_baseline" = 1 ] && args+=(--write-baseline)
[ "$do_e4" = 1 ] && args+=(--e4-dir "$e4_dir" --e4-meta .build/perf/e4/e4-source.json)
python3 scripts/perf/perf_report.py "${args[@]}"
rc=$?
if [ "$rc" = 0 ]; then green "L5 无退步（${out_dir}）"; else red "L5 有退步或掉出必须档（看报告的判定表）：$out_dir"; fi
exit $rc
