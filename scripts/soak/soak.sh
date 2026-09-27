#!/bin/bash
# make soak（8 小时）/ make soak-1h（每晚缩短版）——W4-A 长稳（测试标准 §5 L4：S1、S2、S3、A3；§3 S1 / S2 / A1 / A3；prompt 70 第 1、2、4、6、7 条）。
#
# 负载（§3 S1 + prompt 70 第 1 条）：headless --preset soak = G4 节目的 8 路噪声底纹合成源（5–8 号抠像、9 号 Stinger PNG）+ 10 号内置摄像头 + 11 号文件
#   （E4 的测试片段，循环）；每 30 s 一次转场（Cut / Fade / Wipe / Zoom / Stinger 轮流），每 5 min 翻一路叠加（1 / 2 路叠的是摄像头 / 文件）；
#   输出全程开：1 路录制 + 2 路推流（本地 MediaMTX 的 s1 / s2）+ NDI 发送 + 多画面（渲染不显示）。
# 采集：stats.jsonl 每秒一行（引擎自己的 Stats，铁律 4）；每分钟采一次进程 RSS / CPU（ps）、电源 / 温度 / 负载 / 在跑的编译进程（env.log）、MediaMTX 各路收到的字节（mtx.log）；
#   有 sudo 时 powermetrics（-f plist，默认 10 s 一样：GPU 占用、频率、thermal pressure）。
# 判定（跑完自动）：每 5 分钟窗口 V2 / A1 / E1（scripts/soak/soakjudge.py）；S2 预热 30 分钟后每分钟 RSS 拟合；S3 CPU / GPU avg / p95；
#   A3 = frameprobe av（按 5 分钟分段跑、合到整条时间轴）的整秒配对斜率 × 时长（短跑外推到 8 h）；异常（窗口超阈值、missed_render、欠载、编码跳帧、重连、状态切换、stats 断档、输入停帧……）
#   自动截前后 5 分钟的 stats / headless / 采样 / 系统日志；结束出 §7 报告 reports/W4-soak-<label>.md。
#
# 无人值守：caffeinate -u -i -d -s -w <headless>（prompt 70 第 7 条，照 scripts/gate4.sh；只 -i 时用户"空闲"下实时线程晚醒 10–18 ms）。
# 跑的时候不要跑 App 测试 / 大编译（App 的 S7 那条 missed_render 在机器忙时偶发 +1；别的会话的编译也会让本次的 V2 / V3 / S3 偏高）——脚本会记录在跑的编译 / 测试进程。
#
# 用法：scripts/soak/soak.sh [--hours 8 | --minutes N] [--label 8h] [--out-dir .build/soak/<label>] [--no-build] [--skip-run] [--no-probe]
#                            [--camera auto|none|<uniqueID>] [--no-file] [--no-ndi] [--streams 2] [--rtmp-port 19350] [--mtx-record]
#                            [--powermetrics auto|on|off] [--pm-interval 10] [--ambient "约 24 °C"] [--allow-battery] [--write-baseline] [--report <md>]
#   --skip-run：只用 out-dir 里的产物重新判定、重出报告（改了判定脚本后用）。--no-probe：不跑 frameprobe（A3 / 离线 A1 不判）。
#   --powermetrics auto：sudo -n 可用就采；在终端里先问一句要不要（60 s 不答 = 不采）；非交互不采。on：直接在终端里 sudo -v 问密码；off：不采。
#   --mtx-record：MediaMTX 把两路推流落盘（每路约 2.7 GB/h，默认不落，只按 API 记收到的字节）。
set -uo pipefail
# 从拷贝跑：跑的过程中有人改了这个脚本（git pull / 合并 / 编辑），正在跑的 bash 会按旧偏移读到错位的行（本会话 perf 连跑时就撞上了）。
# 先把自己拷到临时目录再 exec 拷贝，仓库里的脚本随便改，这一趟不受影响。
if [ -z "${SWITCHER_SCRIPT_COPY:-}" ]; then
  root="$(cd "$(dirname "$0")/../.." && pwd)"
  copy="$(mktemp "${TMPDIR:-/tmp}/soak.sh.XXXXXX")" && cp "$0" "$copy" && SWITCHER_SCRIPT_COPY="$copy" SWITCHER_REPO_ROOT="$root" exec bash "$copy" "$@"
fi
cd "$SWITCHER_REPO_ROOT"
export PATH="/opt/homebrew/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1

hours=""; minutes=""; label=""; out_dir=""; do_build=1; do_run=1; do_probe=1; camera=auto; use_file=1; use_ndi=1; streams=2
rtmp_port=19350; mtx_api_port=19997; mtx_srt_port=18890; mtx_record=0; pm_mode=auto; pm_interval=10; ambient=""; allow_battery=0
write_baseline=0; report=""; ndi_name="Switcher soak"
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) hours="$2"; shift 2 ;;
    --minutes) minutes="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --skip-run) do_run=0; shift ;;
    --no-probe) do_probe=0; shift ;;
    --camera) camera="$2"; shift 2 ;;
    --no-file) use_file=0; shift ;;
    --no-ndi) use_ndi=0; shift ;;
    --streams) streams="$2"; shift 2 ;;
    --rtmp-port) rtmp_port="$2"; shift 2 ;;
    --mtx-record) mtx_record=1; shift ;;
    --powermetrics) pm_mode="$2"; shift 2 ;;
    --pm-interval) pm_interval="$2"; shift 2 ;;
    --ambient) ambient="$2"; shift 2 ;;
    --allow-battery) allow_battery=1; shift ;;
    --write-baseline) write_baseline=1; shift ;;
    --report) report="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
if [ -n "$minutes" ]; then duration_s=$((minutes * 60)); [ -n "$label" ] || label="${minutes}min"
else hours=${hours:-8}; duration_s=$((hours * 3600)); [ -n "$label" ] || label="${hours}h"; fi
[ -n "$out_dir" ] || out_dir=".build/soak/$label"
mkdir -p "$out_dir"
nominal_hours=$(python3 -c "print(f'{$duration_s / 3600:g}')")

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }

show="$out_dir/soak-show.json"; scenario="$out_dir/soak.json"; stats="$out_dir/stats.jsonl"; movie="$out_dir/soak.mov"
run_log="$out_dir/headless.log"; env_file="$out_dir/environment.txt"; run_info="$out_dir/run.txt"
thermal_bin=.build/soak/thermal-state

if [ "$do_run" = 1 ]; then
  # ---- 0. 前置检查 ----
  for tool in mediamtx ffmpeg ffprobe curl; do command -v "$tool" >/dev/null || { red "没有 $tool（brew install $tool）"; exit 2; }; done
  need_gb=$(( (duration_s * 3 + 3599) / 3600 * (2 + 2 * mtx_record) + 20 ))      # 录制 6 Mb/s ≈ 2.7 GB/h，分段分析时再占一份（+ 两路落盘）+ 余量
  free_gb=$(df -g "$out_dir" | awk 'NR==2{print $4}')
  [ "$free_gb" -ge "$need_gb" ] || { red "磁盘只剩 ${free_gb} GB，这次要 ≥ ${need_gb} GB"; exit 2; }
  for p in "$rtmp_port" "$mtx_api_port"; do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then red "端口 $p 被占：$(lsof -nP -iTCP:"$p" -sTCP:LISTEN | tail -1)"; exit 2; fi
  done
  if lsof -nP -iUDP:"$mtx_srt_port" >/dev/null 2>&1; then red "UDP $mtx_srt_port 被占（MediaMTX 的 SRT 端口）"; exit 2; fi
  src=$(pmset -g batt | head -1)
  if ! printf '%s' "$src" | grep -q "AC Power"; then
    if [ "$allow_battery" = 1 ]; then yellow "没接电源（$src）：--allow-battery 照跑，报告里会注明"
    else red "没接电源（$src）。§2.8 要求接电源；非要跑加 --allow-battery"; exit 2; fi
  fi
  if [ "$use_ndi" = 1 ] && [ ! -f "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h" ]; then
    yellow "没装 NDI SDK：这次不开 NDI 发送（报告里算偏离标准负载）"; use_ndi=0
  fi
  if pgrep -x xctest >/dev/null 2>&1 || pgrep -f "xcodebuild.* test" >/dev/null 2>&1; then
    yellow "机器上有 xctest / xcodebuild test 在跑：soak 期间不要跑 App 测试（prompt 70 第 7 条），数字会受影响"
  fi

  # ---- 1. 环境 ----
  if [ ! -x "$thermal_bin" ] || [ scripts/soak/thermal-state.swift -nt "$thermal_bin" ]; then
    mkdir -p .build/soak && swiftc -O -o "$thermal_bin" scripts/soak/thermal-state.swift 2>/dev/null || thermal_bin=""
  fi
  scripts/soak/env-snapshot.sh ${thermal_bin:+--thermal-bin "$thermal_bin"} ${ambient:+--ambient "$ambient"} > "$env_file"
  step "环境：$(grep -E '^(chip|macos|power|powermode|thermal_state|load_before)=' "$env_file" | tr '\n' ' ')"
  # 摄像头授权（归属于负责进程 = 跑这个脚本的终端 App）：已授权照用；交互终端里还没问过就现在问（人在键盘前）；
  # 非交互（CI、会话里验证）且没问过：不接摄像头，免得无人时弹系统授权框——报告里写明负载少了这一路
  camera_note=""
  if [ "$camera" != none ]; then
    auth_bin=.build/soak/camera-auth
    if [ ! -x "$auth_bin" ] || [ scripts/soak/camera-auth.swift -nt "$auth_bin" ]; then
      swiftc -O -o "$auth_bin" scripts/soak/camera-auth.swift 2>/dev/null || auth_bin=""
    fi
    cam_auth=unknown; [ -n "$auth_bin" ] && cam_auth=$("$auth_bin" status | sed 's/^video=//')
    if [ "$cam_auth" = notDetermined ] && [ -t 0 ]; then
      yellow "摄像头还没授权给这个终端：马上会弹系统授权框，请点「允许」（8 小时里摄像头这一路靠它）"
      cam_auth=$("$auth_bin" request | sed 's/^video=//')
    fi
    case "$cam_auth" in
      authorized) ;;
      notDetermined)
        camera_note="非交互环境且摄像头授权未定（没人点授权框）：这次不接摄像头"
        yellow "$camera_note"; camera=none ;;
      *)
        camera_note="摄像头授权是 $cam_auth：CameraInput 会停在 error（画黑），负载少了摄像头这一路；系统设置 → 隐私与安全性 → 摄像头 给终端开权限"
        yellow "$camera_note" ;;
    esac
    echo "camera_auth=$cam_auth" >> "$env_file"
  fi
  busy=$(grep '^busy_processes=' "$env_file" | cut -d= -f2-)
  [ -n "$busy" ] && yellow "机器上还有编译 / 测试进程：$busy"
  # powermetrics 要不要采：开跑前问（和摄像头授权一起，人只需要在开头守一下），真正启动在 headless 起来之后
  pm_ok=0
  if [ "$pm_mode" != off ]; then
    if sudo -n true 2>/dev/null; then pm_ok=1
    elif [ -t 0 ] && [ "$pm_mode" = on ]; then echo "powermetrics 要 root：输入本机密码（只这一次）"; sudo -v && pm_ok=1
    elif [ -t 0 ]; then
      # auto + 终端：问一句，60 s 没人答就跳过（人走开了也不会卡在密码提示上、整晚没开跑）
      ans=""; read -r -t 60 -p "要采 powermetrics（GPU 频率 / thermal pressure，要 sudo 密码）吗？[y/N]（60 s 不答 = 不采）" ans || true; echo
      if [ "$ans" = y ] || [ "$ans" = Y ]; then sudo -v && pm_ok=1; fi
    fi
  fi
  trap '[ -n "${sudo_keepalive_pid:-}" ] && kill "$sudo_keepalive_pid" 2>/dev/null' EXIT
  # 票据默认 5 分钟过期，而开跑前还有编译 / 生成片段 / 起 MediaMTX：保活到 powermetrics 启动为止
  sudo_keepalive_pid=""
  if [ "$pm_ok" = 1 ]; then ( while true; do sudo -n -v 2>/dev/null; sleep 60; done ) & sudo_keepalive_pid=$!; fi

  # ---- 2. 编译 ----
  if [ "$do_build" = 1 ]; then
    step "编译 release：switcher-headless、frameprobe"
    swift build -c release --package-path Tools/switcher-headless 2>&1 | grep -E 'error|Build complete' | tail -3 || true
    swift build -c release --package-path Tools/frameprobe 2>&1 | grep -E 'error|Build complete' | tail -2 || true
  fi
fi
headless="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
frameprobe="$(swift build -c release --package-path Tools/frameprobe --show-bin-path)/frameprobe"
[ -x "$headless" ] || { red "没编出 $headless"; exit 2; }

if [ "$do_run" = 1 ]; then
  # ---- 3. 节目 / 场景 / 片段 ----
  file_args=()
  if [ "$use_file" = 1 ]; then
    scripts/perf/make-e4-clip.sh --out .build/perf/e4 || { red "测试片段生成失败"; exit 2; }
    file_args=(--file .build/perf/e4/e4-source.mov)
  fi
  "$headless" make-show --preset soak --camera "$camera" ${file_args[@]+"${file_args[@]}"} --out "$show" || { red "make-show 失败（--camera none 可以不要摄像头）"; exit 2; }
  "$headless" make-scenario --preset soak --minutes $(( (duration_s + 59) / 60 )) --out "$scenario" >/dev/null || exit 2
  step "节目：$(python3 -c "import json;s=json.load(open('$show'));print('、'.join(f\"{i['number']} {i['name']}\" for i in s['inputs']))")"

  # ---- 4. MediaMTX（专用端口，避开 W2-D 测试的 1935–1937 / 8890–8892 / 9997–9999）----
  mtx_pid=""
  if [ "$streams" -gt 0 ]; then
    mtx_rec=no; [ "$mtx_record" = 1 ] && mtx_rec=yes
    mkdir -p "$out_dir/mediamtx"
    # 只绑回环：不对外开端口（也就不触发应用防火墙的"是否允许接入"提示）
    MTX_RTMPADDRESS="127.0.0.1:$rtmp_port" MTX_APIADDRESS="127.0.0.1:$mtx_api_port" MTX_SRTADDRESS="127.0.0.1:$mtx_srt_port" \
      MTX_PATHDEFAULTS_RECORD="$mtx_rec" MTX_PATHDEFAULTS_RECORDPATH="$out_dir/mediamtx/%path/%Y-%m-%d_%H-%M-%S-%f" \
      mediamtx scripts/mediamtx.yml > "$out_dir/mediamtx.log" 2>&1 &
    mtx_pid=$!
    for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$mtx_api_port/v3/paths/list" >/dev/null 2>&1 && break; sleep 0.2; done
    curl -sf "http://127.0.0.1:$mtx_api_port/v3/paths/list" >/dev/null 2>&1 || { red "MediaMTX 没起来（$out_dir/mediamtx.log）"; kill "$mtx_pid" 2>/dev/null; exit 2; }
  fi
  stream_args=()
  i=1; while [ "$i" -le "$streams" ]; do stream_args+=(--stream "rtmp://127.0.0.1:$rtmp_port/s$i"); i=$((i + 1)); done   # 不用 seq：BSD 的 seq 1 0 会倒着数出 1 0
  ndi_args=(); [ "$use_ndi" = 1 ] && ndi_args=(--ndi-send "$ndi_name")

  # ---- 5. 跑 ----
  rm -f "$stats" "$movie" "$out_dir"/powermetrics.plist "$out_dir"/{rss,env,mtx,load}.log
  rm -rf "$out_dir/anomalies"
  start_epoch=$(date +%s)
  touch "$out_dir/.start-marker"
  {
    echo "start_epoch=$start_epoch"; echo "duration_s=$duration_s"; echo "label=$label"; echo "streams=$streams"; echo "ndi=$use_ndi"
    echo "camera=$camera"; echo "camera_note=$camera_note"; echo "file=$use_file"; echo "mtx_record=$mtx_record"; echo "rtmp_port=$rtmp_port"
    echo "command=$headless run --show $show --script $scenario --duration $duration_s --stats $stats --record $movie --audio-device null ${ndi_args[*]} ${stream_args[*]}"
  } > "$run_info"
  step "跑 $label（$duration_s s）：$(sed -n 's/^command=//p' "$run_info" | sed "s|$PWD/||g")"
  # stdout / stderr 每行加墙钟时间戳（异常截取按时间找行）；$! 仍是 headless 自己
  "$headless" run --show "$show" --script "$scenario" --duration "$duration_s" --stats "$stats" --record "$movie" --audio-device null \
      ${ndi_args[@]+"${ndi_args[@]}"} ${stream_args[@]+"${stream_args[@]}"} \
      > >(perl -MPOSIX -MTime::HiRes=time -ne 'BEGIN{$|=1} my $t=time; printf "%.3f %s %s", $t, strftime("%H:%M:%S", localtime($t)), $_' > "$run_log") 2>&1 &
  headless_pid=$!
  echo "headless_pid=$headless_pid" >> "$run_info"
  caffeinate -u -i -d -s -w "$headless_pid" >/dev/null 2>&1 &
  caffeinate_pid=$!

  # 每分钟：进程 RSS / CPU、环境、MediaMTX；每 5 s：负载（与 gate 脚本同格式）
  ( while kill -0 "$headless_pid" 2>/dev/null; do
      echo "$(date +%s) $(ps -o rss=,vsz=,%cpu= -p "$headless_pid" 2>/dev/null | awk '{printf "rss_kb=%s vsz_kb=%s cpu=%s", $1, $2, $3}')" >> "$out_dir/rss.log"
      th=""; [ -n "$thermal_bin" ] && th=$("$thermal_bin" 2>/dev/null)
      b="$(pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/") $(pmset -g batt | grep -o '[0-9]*%' | head -1)"
      spi=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -o '"SystemPowerIn"=[0-9]*' | head -1 | cut -d= -f2)
      tw=$(pmset -g therm 2>/dev/null | grep -iE 'level|limit' | grep -v 'has been recorded' | tr '\n' ' ' | sed 's/  */ /g')
      echo -e "$(date +%s)\t$th\tpower=$b\tsystem_power_in_mw=$spi\tload=$(uptime | sed 's/.*averages: //')\tbusy=$(scripts/soak/env-snapshot.sh --busy-only)\tpmset_therm=${tw:-无告警}" >> "$out_dir/env.log"
      [ -n "$mtx_pid" ] && echo "{\"ts\":$(date +%s),\"paths\":$(curl -s --max-time 5 "http://127.0.0.1:$mtx_api_port/v3/paths/list" || echo null)}" >> "$out_dir/mtx.log"
      sleep 60
    done ) &
  minute_pid=$!
  ( while kill -0 "$headless_pid" 2>/dev/null; do
      t=$(ps -Ao pcpu,comm -r | sed -n '2,5p' | awk '{n=split($2,a,"/"); printf "%s%%%s; ", $1, a[n]}')
      echo "$(date +%s) $(date +%T) load $(uptime | sed 's/.*averages: //' | cut -d' ' -f1) top: $t" >> "$out_dir/load.log"; sleep 5
    done ) &
  load_pid=$!

  # powermetrics：本用户的 cat 在管道另一头；headless 提前退出时杀掉 cat，powermetrics 下一次写就 SIGPIPE 退出（sudo 票据 8 小时后早过期了，不能指望 sudo kill）
  pm_pid=""
  if [ -n "${sudo_keepalive_pid:-}" ]; then kill "$sudo_keepalive_pid" 2>/dev/null; fi
  if [ "$pm_ok" = 1 ] && ! sudo -n true 2>/dev/null; then
    yellow "开跑前拿到的 sudo 票据已经过期，powermetrics 这次不采"; pm_ok=0
  fi
  if [ "$pm_ok" = 1 ]; then
    ( sudo -n /usr/bin/powermetrics -f plist -i $((pm_interval * 1000)) -n $((duration_s / pm_interval + 6)) --samplers cpu_power,gpu_power,thermal \
        2>"$out_dir/powermetrics.err" | cat > "$out_dir/powermetrics.plist" ) &
    pm_pid=$!
    sleep 2
    echo "powermetrics_start_epoch=$(date +%s)" >> "$run_info"
  else
    yellow "powermetrics 不采（sudo 要密码；自己的终端里 make soak SOAK_ARGS='--powermetrics on'，或 sudoers 给 /usr/bin/powermetrics NOPASSWD）"
  fi
  cleanup() {
    kill "$headless_pid" 2>/dev/null
    kill "$minute_pid" "$load_pid" "$caffeinate_pid" 2>/dev/null
    [ -n "$pm_pid" ] && pkill -P "$pm_pid" cat 2>/dev/null
    [ -n "$mtx_pid" ] && kill "$mtx_pid" 2>/dev/null
  }
  trap cleanup EXIT
  trap 'echo; yellow "收到中断：让 headless 干净收尾（录制封口）……再按一次立即退出"; kill -INT $headless_pid 2>/dev/null; trap - INT' INT

  # 前台每 5 分钟报一次进度（最后一行 stats）
  next=$(( $(date +%s) + 300 ))
  while kill -0 "$headless_pid" 2>/dev/null; do
    sleep 5
    if [ "$(date +%s)" -ge "$next" ]; then
      next=$(( next + 300 ))
      tail -n 1 "$stats" 2>/dev/null | python3 -c "
import json, sys, time
try:
    l = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
enc = l.get('encoder', [])
print(time.strftime('%H:%M:%S'), f\"拍 {l['tick']}  V2 {l['missed_render']}  A1 {l['audio']['dropouts']}+{l['audio']['underruns']}  E1 {sum(e['skipped'] for e in enc)}  \"
      f\"RSS {l['rss_mb']:.0f} MB  CPU {l['cpu_pct']:.0f}%  GPU {l['gpu_pct']:.0f}%  输出 \" + ' '.join(f\"{e['output']}:{e['state']}\" for e in enc))
" || true
    fi
  done
  wait "$headless_pid"; rc=$?
  trap - INT
  echo "exit_code=$rc" >> "$run_info"
  echo "end_epoch=$(date +%s)" >> "$run_info"
  sleep 1
  kill "$minute_pid" "$load_pid" "$caffeinate_pid" 2>/dev/null
  [ -n "$pm_pid" ] && { pkill -P "$pm_pid" cat 2>/dev/null; wait "$pm_pid" 2>/dev/null; }
  [ -n "$mtx_pid" ] && { kill "$mtx_pid" 2>/dev/null; wait "$mtx_pid" 2>/dev/null; }
  trap - EXIT
  {
    echo "load_after=$(uptime | sed 's/.*load averages: //')"
    echo "busy_processes_after=$(scripts/soak/env-snapshot.sh --busy-only)"
    [ -n "$thermal_bin" ] && echo "thermal_state_after=$("$thermal_bin" | sed 's/^thermal=//; s/ low_power=.*//')"
  } >> "$env_file"
  # 崩溃报告（本次开跑之后生成的）
  mkdir -p "$out_dir/crash"
  find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -newer "$out_dir/.start-marker" \( -iname 'switcher-headless*' -o -iname 'mediamtx*' \) -exec cp {} "$out_dir/crash/" \; 2>/dev/null
  tail -n 25 "$run_log" | cut -c 25-
  [ "$rc" = 0 ] || red "headless 退出码 $rc（$run_log）"
fi

[ -s "$stats" ] || { red "没有 $stats"; exit 1; }
# ---- 6. 录像：ffprobe（V5 / E5 信息项）+ frameprobe av（A2 / A3、A1 离线不连续）----
if [ -s "$movie" ]; then
  if [ "$do_run" = 1 ] || [ ! -s "$out_dir/ffprobe.json" ]; then
    step "ffprobe（帧数 / 时长 / 解析错误）"
    ffprobe -v error -count_packets -show_entries format=duration:stream=index,codec_type,codec_name,nb_read_packets,duration,start_time -of json "$movie" > "$out_dir/ffprobe.json" 2>/dev/null || true
    ffprobe -v error "$movie" > "$out_dir/ffprobe-errors.txt" 2>&1 || true
  fi
  if [ "$do_probe" = 1 ] && { [ "$do_run" = 1 ] || [ ! -s "$out_dir/probe-seg/segments.csv" ]; }; then
    # frameprobe 对整条录像的内存随帧数线性涨（本会话实测：10 分钟 7.6 GB、1 小时 41 GB，8 小时估 330 GB，reports/issues/W4A-w1-testkit-frameprobe-memory-grows-with-length.md），
    # 所以按 5 分钟切段（与 S1 窗口一致；stream copy、-avoid_negative_ts disabled 让第一段保住 AAC priming 的编辑列表），逐段跑、跑完删段文件，
    # 每段给自己的 --start-tick（整秒配对仍由 frameprobe 判），soak_report.py 把各段合到整条时间轴上做 A2 / A3 与离线不连续。
    seg_dir="$out_dir/probe-seg"; rm -rf "$seg_dir"; mkdir -p "$seg_dir"
    step "frameprobe av --discontinuities，按 5 分钟分段（A2 / A3、A1 离线口径；8 小时约 45 分钟）"
    if ffmpeg -hide_banner -loglevel error -i "$movie" -map 0 -c copy -avoid_negative_ts disabled -f segment -segment_time 300 -segment_format mov \
         -segment_list "$seg_dir/segments.csv" -segment_list_type csv -reset_timestamps 1 "$seg_dir/seg%04d.mov"; then
      total=$(wc -l < "$seg_dir/segments.csv" | tr -d ' '); n=0
      while IFS=, read -r name start _end; do
        n=$((n + 1))
        tick=$(python3 -c "print(round(float('$start') * 60))")
        "$frameprobe" av "$seg_dir/$name" --fps 60 --start-tick "$tick" --discontinuities --out "$seg_dir/${name%.mov}.json" \
            < /dev/null > /dev/null 2>> "$seg_dir/probe.err" || echo "$name" >> "$seg_dir/failed.txt"
        rm -f "$seg_dir/$name"
        if [ $((n % 12)) = 0 ]; then echo "   frameprobe $n / $total 段"; fi
      done < "$seg_dir/segments.csv"
      [ -s "$seg_dir/failed.txt" ] && red "frameprobe 有段失败：$(tr '\n' ' ' < "$seg_dir/failed.txt")（$seg_dir/probe.err）"
    else
      red "切段失败（ffmpeg segment）：A2 / A3 与离线不连续这次判不了"
    fi
  fi
fi

# ---- 7. 判定 + 报告 ----
args=(--out-dir "$out_dir" --label "$label" --hours "$nominal_hours" --baseline-dir baselines)
[ -n "$report" ] && args+=(--report "$report")
[ "$write_baseline" = 1 ] && args+=(--write-baseline)
python3 scripts/soak/soak_report.py "${args[@]}"
rc=$?
if [ "$rc" = 0 ]; then green "长稳 $label 通过：$out_dir"; else red "长稳 $label 未通过（看报告的判定表与异常段）：$out_dir"; fi
exit $rc
