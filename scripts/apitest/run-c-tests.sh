#!/bin/bash
# C 系列（C1–C4）一键跑：headless --api + 合成源 + 录制，apitest.py 当客户端，frameprobe 解录制文件，apitest.py evaluate 出报告。
#
#   scripts/apitest/run-c-tests.sh [--minutes 10] [--out-dir .build/apitest/<label>] [--label 10min] [--port 8765] [--debug]
#                                  [--c1-count 50] [--c4-seconds 60] [--c4-rate 100] [--c4-clients 2] [--skip-build]
#
# 场景：8 路合成源（make-show 的 M0 节目）、每 5 s 切一次（每 60 s 一次 Fade 30 拍）；C1 的 50 次 cut 由客户端在避开场景切换的相位发；
# C4 在 C1 之后跑 60 s；C2 / C3 用整段运行里的全部快照。产物（不入库）：show.json、scenario.json、headless.log、out.mov、stats.jsonl、
# session.json、frames.json、report.md、summary.json。
set -uo pipefail
cd "$(dirname "$0")/../.."

minutes=10; label=""; out_dir=""; port=8765; config=release; c1_count=50; c4_seconds=60; c4_rate=100; c4_clients=2; skip_build=0
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --debug) config=debug; shift ;;
    --c1-count) c1_count="$2"; shift 2 ;;
    --c4-seconds) c4_seconds="$2"; shift 2 ;;
    --c4-rate) c4_rate="$2"; shift 2 ;;
    --c4-clients) c4_clients="$2"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
[ -n "$label" ] || label="${minutes}min"
[ -n "$out_dir" ] || out_dir=".build/apitest/$label"
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

if [ "$skip_build" = 0 ]; then
  step "编译 ${config}：switcher-headless、frameprobe"
  swift build -c "$config" --package-path Tools/switcher-headless 2>&1 | grep -E 'error|Build complete' | tail -2 || true
  swift build -c "$config" --package-path Tools/frameprobe 2>&1 | grep -E 'error|Build complete' | tail -2 || true
fi
headless="$(swift build -c "$config" --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
frameprobe="$(swift build -c "$config" --package-path Tools/frameprobe --show-bin-path)/frameprobe"
[ -x "$headless" ] || { red "没编出 $headless"; exit 1; }
[ -x "$frameprobe" ] || { red "没编出 $frameprobe"; exit 1; }

seconds=$((minutes * 60))
step "节目与场景（$seconds s，每 5 s 切一次）"
"$headless" make-show --out "$out_dir/show.json"
python3 scripts/apitest/apitest.py scenario --out "$out_dir/scenario.json" --seconds "$seconds" --fps 60 --inputs 8 --cut-every 5 --fade-every 60 --fade-ticks 30

step "机器状态"
uptime
pgrep -x Cyberpunk2077 >/dev/null && red "游戏在跑！" || true
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then red "端口 $port 被占：$(lsof -nP -iTCP:"$port" -sTCP:LISTEN | tail -1)"; exit 1; fi

step "起 headless（--api 127.0.0.1:${port}，录制 + stats）"
rm -f "$out_dir/out.mov" "$out_dir/stats.jsonl"
"$headless" run --show "$out_dir/show.json" --script "$out_dir/scenario.json" --duration "$seconds" --stats "$out_dir/stats.jsonl" \
  --record "$out_dir/out.mov" --audio-device null --api --api-listen "127.0.0.1:$port" > "$out_dir/headless.log" 2>&1 &
headless_pid=$!
trap 'kill $headless_pid 2>/dev/null' EXIT

step "客户端：C1 $c1_count 次 cut，C4 $c4_clients × $c4_rate/s × $c4_seconds s，C2 / C3 全程记录"
python3 scripts/apitest/apitest.py run --url "http://127.0.0.1:$port" --out "$out_dir/session.json" \
  --c1-count "$c1_count" --scenario-period 5 --c4-seconds "$c4_seconds" --c4-rate "$c4_rate" --c4-clients "$c4_clients" \
  --max-seconds $((seconds + 90))
client_status=$?

step "等 headless 收尾"
wait $headless_pid
headless_status=$?
trap - EXIT
tail -n 25 "$out_dir/headless.log"
[ "$headless_status" = 0 ] || red "headless 退出码 $headless_status"
[ "$client_status" = 0 ] || red "客户端退出码 $client_status"

step "frameprobe frames（逐帧输入 ID）"
"$frameprobe" frames "$out_dir/out.mov" --fps 60 --out "$out_dir/frames.json" >/dev/null
"$frameprobe" switches "$out_dir/out.mov" --fps 60 --out "$out_dir/switches.json" --markdown > "$out_dir/switches.md" || true

step "评估"
python3 scripts/apitest/apitest.py evaluate --session "$out_dir/session.json" --frames "$out_dir/frames.json" --show "$out_dir/show.json" --fps 60 \
  --out "$out_dir/report.md" --json "$out_dir/summary.json"
eval_status=$?
echo
echo "产物：$out_dir"
if [ "$eval_status" = 0 ] && [ "$headless_status" = 0 ] && [ "$client_status" = 0 ]; then green "C 系列通过"; else red "C 系列未通过（evaluate $eval_status / headless $headless_status / client ${client_status}）"; fi
exit $eval_status
