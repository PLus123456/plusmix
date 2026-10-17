#!/bin/bash
# G3 检查点的 E7–E9（多路推流独立性 / 重连 / 网络丢帧计数；G3 prompt 第 2 条 c）：需要真的网络损伤（dummynet + pf），也就是 sudo。
# 分两步：
#   1. 用户在另一个终端起 netem 代理（只这一条要 sudo；Ctrl-C 退出时自动清规则）：
#        sudo scripts/netem.sh serve
#   2. 本脚本（不需要 sudo）：确认代理活着 → 起三个 MediaMTX 由测试自己管 → 以 SWITCHER_NETEM=broker 跑 W2-D 的
#      MediaMTXTests.testE7_* / testE8_* / testE9_*（各 1.3 / 2.9 / 5.7 分钟）→ 从 xctest 输出里摘数字 → reports/G3-net.md
#      （scripts/gate3-report.py 拼 reports/G3.md 时会把它带上）。
#
# 用法：scripts/gate3-net.sh [--dir /tmp/switcher-netem] [--out .build/gate3/net] [--filter 'E7|E8|E9'] [--no-build]
# 需要：brew 的 mediamtx、ffmpeg；release 的 frameprobe（本脚本会编）。测试输出文件在 $TMPDIR/switcher-streaming-tests/。
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

dir=/tmp/switcher-netem; out=.build/gate3/net; filter='E7|E8|E9'; do_build=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --filter) filter="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }
mkdir -p "$out"

# ---- 0. 代理有且只有一个吗（G3 第一次跑 E8 时下午起的代理没关、晚上又起了一个，两个代理各读半个请求、pfctl 撞锁，E8 第 4 次封没封上）----
serve_pids=$(pgrep -f "bash.*netem.sh serve" 2>/dev/null | tr '\n' ' ')
serve_count=$(echo "$serve_pids" | wc -w | tr -d ' ')
if [ "$serve_count" -gt 1 ]; then
  red "有 $serve_count 个 netem 代理在跑，必须只留一个（它们会抢同一个请求文件）："
  ps -o pid,lstart,tty,command -p "$(echo "$serve_pids" | tr ' ' ',' | sed 's/,$//')" 2>/dev/null
  echo "    在多余的那个终端 Ctrl-C，或 sudo kill <pid>；然后重跑本脚本"; exit 2
fi
if [ "$serve_count" = 0 ]; then
  red "没有 netem 代理在跑。请先在另一个终端跑："; echo "    sudo scripts/netem.sh serve"; exit 2
fi
green "netem 代理进程：$(ps -o pid=,lstart=,tty= -p "$(echo "$serve_pids" | tr -d ' ')" 2>/dev/null | sed 's/^ *//')"
# ---- 0b. 代理活着吗：写一条 status 请求，3 s 内要有 reply ----
if [ ! -d "$dir" ]; then
  red "netem 代理目录 $dir 不存在。请先在另一个终端跑："; echo "    sudo scripts/netem.sh serve"; exit 2
fi
rm -f "$dir/netem.reply"
echo "status" > "$dir/netem.request"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -f "$dir/netem.reply" ] && break
  sleep 0.2
done
if [ ! -f "$dir/netem.reply" ]; then
  red "netem 代理没有响应（$dir/netem.request 没人读）。请先在另一个终端跑："; echo "    sudo scripts/netem.sh serve"; exit 2
fi
green "netem 代理在线：$(head -3 "$dir/netem.reply" | tr '\n' ' ')"
command -v mediamtx >/dev/null || { red "没有 mediamtx（brew install mediamtx）"; exit 2; }
command -v ffmpeg >/dev/null || { red "没有 ffmpeg（brew install ffmpeg）"; exit 2; }

# ---- 1. 编译 release frameprobe（MediaMTXTests 用它解落盘文件）----
if [ "$do_build" = 1 ]; then
  step "编译 release frameprobe"
  swift build -c release --package-path Tools/frameprobe 2>&1 | grep -E 'error|Build complete' | tail -2 || true
fi

# ---- 2. 跑 ----
log="$out/xctest.log"
step "SWITCHER_NETEM=broker swift test --package-path Packages/SwitcherOutputs --filter 'MediaMTXTests/test($filter)'（约 10 分钟）"
{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"; echo "commit=$(git rev-parse --short HEAD)"; echo "load_before=$(uptime | sed 's/.*load averages: //')"
} > "$out/environment.txt"
SWITCHER_NETEM=broker SWITCHER_NETEM_DIR="$dir" swift test --package-path Packages/SwitcherOutputs --filter "MediaMTXTests/test($filter)" > "$log" 2>&1
rc=$?
echo "load_after=$(uptime | sed 's/.*load averages: //')" >> "$out/environment.txt"
grep -E "Test Case .* (passed|failed|skipped)|error:|XCTSkip|E7|E8|E9|重连|丢帧|networkDropped|缺" "$log" | tail -60

# ---- 3. 报告 ----
python3 - "$log" "$out" "$rc" <<'PY' > reports/G3-net.md
import re, sys, datetime
log, out, rc = open(sys.argv[1], encoding="utf-8", errors="replace").read(), sys.argv[2], int(sys.argv[3])
env = dict(l.split("=", 1) for l in open(f"{out}/environment.txt", encoding="utf-8") if "=" in l)
cases = re.findall(r"Test Case '-\[\w+\.MediaMTXTests (test\w+)\]' (passed|failed|skipped)(?: \((\d+\.\d+) seconds\))?", log)
skips = re.findall(r"(test\w+).*?XCTSkip[^\n]*|BLOCKED-[^\n]*", log)
lines = ["## 运行 net：E7–E9（dummynet + pf，netem 代理模式）", "",
         f"- 日期：{env.get('date', '?').strip()}；提交：`{env.get('commit', '?').strip()}`；负载 跑前 {env.get('load_before', '?').strip()} → 跑后 {env.get('load_after', '?').strip()}",
         f"- 命令：`SWITCHER_NETEM=broker swift test --package-path Packages/SwitcherOutputs --filter 'MediaMTXTests/test(E7|E8|E9)'`（xctest 退出码 {rc}；日志 `{out}/xctest.log`）", "",
         "| 测试 ID | 用例 | 结果 | 耗时 | 阈值（测试标准 §4） |", "|---|---|---|---|---|"]
thr = {"E7": "其他路丢帧 0（硬性）", "E8": "10 次全部成功、≤ 15 s（目标 ≤ 5 s）；重连后 A2 达标", "E9": "误差 ≤ 5%（目标 ≤ 1%）"}
seen = set()
for name, result, secs in cases:
    tid = next((k for k in ("E7", "E8", "E9") if name.startswith("test" + k)), "?")
    seen.add(tid)
    lines.append(f"| {tid} | `{name}` | {'✅ 通过' if result == 'passed' else ('⏭ 跳过' if result == 'skipped' else '❌ 失败')} | {secs or '—'} s | {thr.get(tid, '—')} |")
for tid in ("E7", "E8", "E9"):
    if tid not in seen:
        lines.append(f"| {tid} | — | ❓ 没有跑到（看日志） | — | {thr[tid]} |")
lines.append("")
lines.append("测试自己打印的数字（送出 / 落盘 / 网络丢帧 / 重连耗时）：")
lines.append("")
lines.append("```")
keep = [l for l in log.splitlines() if re.search(r"E7|E8|E9|重连|丢帧|networkDropped|落盘|缺口|A/V|断线", l) and "Test Case" not in l]
lines.extend(keep[-80:])
lines.append("```")
if skips:
    lines.append("")
    lines.append("跳过 / BLOCKED：" + "; ".join(s if isinstance(s, str) else s[0] for s in skips[:10]))
lines.append("")
lines.append(f"生成时间：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("\n".join(lines))
PY
if [ "$rc" = 0 ]; then green "E7–E9 通过：reports/G3-net.md"; else red "E7–E9 有失败 / 跳过（xctest 退出码 ${rc}）：看 $log 与 reports/G3-net.md"; fi
exit $rc
