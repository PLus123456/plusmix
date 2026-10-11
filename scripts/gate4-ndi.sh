#!/bin/bash
# G4：NDI 回环 L1（prompt 60 第 2 条 "NDI 回环 L1"；测试标准 §1 L1、§4 L1 ≤ 3 帧 / 目标 ≤ 2 帧）。
#   headless 起 W2-D 的 NDISender 发 PGM（--ndi-send），节目 scenarios/g4-ndi-show.json 的 2 号输入是 W3-A 的 NDIInput 收它（本机回环），
#   跑 N 秒，读 stats.jsonl 的 per_input["2"].latency_ms / latency_max_ms（提案 005 的 L1：帧交给第一个消费者的时刻 − 入口时刻，铁律 4 只此一份）。
#   W3-A 的口径（reports/w3-inputs2.md §1.2）：NDI 帧的 pts = 到达 − 抖动 + J × 帧间隔，J = 抖动缓冲深度，所以 L1 含 J 帧的有意缓冲；
#   判定 L1 ≤ 3 + J 帧（W3-A 用例同一口径），同时报扣掉 J × T 之后对 3 帧的余量。
# 用法：scripts/gate4-ndi.sh [--seconds 60] [--jitter-frames 1] [--name "Switcher G4 loop"] [--out-dir .build/gate4/ndi] [--no-build] [--report reports/G4-ndi.md]
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
seconds=60; jitter=1; name="Switcher G4 loop"; out_dir=".build/gate4/ndi"; do_build=1; report="reports/G4-ndi.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) seconds="$2"; shift 2 ;;
    --jitter-frames) jitter="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --report) report="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\033[36m== %s\033[0m\n' "$*"; }
mkdir -p "$out_dir"
if [ "$do_build" = 1 ]; then
  step "编译 release：switcher-headless"
  swift build -c release --package-path Tools/switcher-headless 2>&1 | grep -E 'error|Build complete' | tail -3 || true
fi
headless="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
[ -x "$headless" ] || { red "没编出 $headless"; exit 1; }
show="$out_dir/g4-ndi-show.json"
"$headless" make-show --preset g4-ndi --ndi-name "$name" --out "$show" > /dev/null
if [ ! -d "/Library/NDI SDK for Apple" ] && [ -z "${NDI_SDK_DIR:-}" ]; then
  red "没有 NDI SDK（/Library/NDI SDK for Apple）：BLOCKED-SDK"; exit 3
fi
stats="$out_dir/stats.jsonl"; log="$out_dir/headless.log"
step "跑 $seconds s：--ndi-send \"$name\" → NDI 输入 2 号（抖动缓冲 $jitter 帧），PVW = 2 号"
"$headless" run --show "$show" --duration "$seconds" --stats "$stats" --record "$out_dir/out.mov" --audio-device null \
  --ndi-send "$name" --ndi-jitter-frames "$jitter" > "$log" 2>&1
rc=$?
tail -n 12 "$log"
[ "$rc" = 0 ] || { red "headless 退出码 $rc（看 $log）"; exit 1; }
python3 - "$stats" "$jitter" "$seconds" "$report" "$log" "$name" <<'PY'
# -*- coding: utf-8 -*-
import json, sys, datetime
stats, J, seconds, report, log, name = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
rows = [json.loads(l) for l in open(stats, encoding="utf-8") if l.strip()]
T = 1000 / 60
warm = 5   # 头 5 s 不算（发现 / 连接 / 到达余量收敛）
sel = [r for r in rows[warm:] if "2" in r.get("per_input", {})]
# 测试标准 §3（用户 2026-10-11 定，G8b）：L1 判定扣掉同一行的 video_delay_ms（videoDelay 补偿下编码器入口在视频延后之后），阈值不动；022 之前的文件缺键按 0
lat = [r["per_input"]["2"]["latency_ms"] - float(r.get("video_delay_ms", 0) or 0) for r in sel if r["per_input"]["2"].get("fps", 0) > 0]
lmax = [r["per_input"]["2"]["latency_max_ms"] - float(r.get("video_delay_ms", 0) or 0) for r in sel if r["per_input"]["2"].get("fps", 0) > 0]
vd = [float(r.get("video_delay_ms", 0) or 0) for r in sel]
fps = [r["per_input"]["2"]["fps"] for r in sel]
dup = sel[-1]["per_input"]["2"]["dup"] if sel else None
drop = sel[-1]["per_input"]["2"]["drop"] if sel else None
dup0 = sel[0]["per_input"]["2"]["dup"] if sel else None
drop0 = sel[0]["per_input"]["2"]["drop"] if sel else None
avg = sum(lat) / len(lat) if lat else float("nan")
mx = max(lmax) if lmax else float("nan")
p99 = sorted(lmax)[max(0, int(len(lmax) * 0.99) - 1)] if lmax else float("nan")
limit_frames = 3 + J
ok = bool(lat) and avg / T <= limit_frames and mx / T <= limit_frames
target_ok = bool(lat) and avg / T <= 2 + J and mx / T <= 2 + J
missed = rows[-1].get("missed_render", 0) if rows else None
enc = rows[-1].get("encoder", []) if rows else []
ndi_entry = enc[-1] if len(enc) >= 2 else None
md = []
md.append(f"## NDI 回环 L1（scripts/gate4-ndi.sh，{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}）")
md.append("")
md.append(f"- 做法：headless `--ndi-send \"{name}\"`（W2-D NDISender 发 PGM + Master 音频）→ 同一进程里 W3-A 的 NDIInput 收「机器名 ({name})」，抖动缓冲 J = {J} 帧，"
          f"PGM = 1 号合成源（60 fps 噪声底纹 + 音频），PVW = 2 号 NDI 输入；跑 {seconds} s，去掉头 {warm} s；数字来自 stats.jsonl per_input[\"2\"]（提案 005 的 L1，铁律 4）。")
md.append(f"- 口径：W3-A 报告 §1.2——NDI 帧 pts = 到达 − 抖动 + J × 帧间隔，L1 含 J 帧的有意缓冲；判 L1 ≤ 3 + J 帧（W3-A 用例同口径），扣掉 J × T 后对 3 帧的余量另报。")
md.append(f"- 已扣同一行 stats 的 video_delay_ms（测试标准 §3，用户 2026-10-11 定；这次平均 {sum(vd) / len(vd) if vd else 0:.2f} ms、最大 {max(vd) if vd else 0:.2f} ms），阈值数字不动。")
md.append("")
md.append("| 指标 | 数值 | 阈值 | 通过 |")
md.append("|---|---|---|---|")
md.append(f"| L1 NDI（每秒均值的平均） | {avg:.2f} ms（{avg / T:.2f} 帧；扣 J×T 后 {avg / T - J:.2f} 帧） | ≤ {limit_frames} 帧（3 + J；目标 ≤ {2 + J}） | {'✅' if ok else '❌'}{'（目标档也过）' if target_ok else ''} |")
md.append(f"| L1 NDI（每秒最大值的 p99 / max） | {p99:.2f} / {mx:.2f} ms（{mx / T:.2f} 帧） | max ≤ {limit_frames} 帧 | {'✅' if mx / T <= limit_frames else '❌'} |")
md.append(f"| NDI 输入 fps（每秒） | min {min(fps):.2f} / avg {sum(fps) / len(fps):.2f} / max {max(fps):.2f} | ≈ 60 | {'✅' if fps and min(fps) > 55 else '❌'} |")
md.append(f"| NDI 输入 dup / drop（{warm} s 后增量） | dup +{(dup or 0) - (dup0 or 0)}，drop +{(drop or 0) - (drop0 or 0)} | 设计外 0（V4 口径，60 → 60） | {'✅' if (dup or 0) - (dup0 or 0) <= 2 and (drop or 0) - (drop0 or 0) <= 2 else '❌'} |")
md.append(f"| missed_render（全程） | {missed} | 0 | {'✅' if missed == 0 else '❌'} |")
if ndi_entry:
    md.append(f"| NDI 发送（Stats.encoder 末项） | frames {ndi_entry.get('frames')}，dropped {ndi_entry.get('dropped')}，state {ndi_entry.get('state')} | dropped 0 | {'✅' if ndi_entry.get('dropped', 1) == 0 else '❌'} |")
md.append("")
md.append(f"- 产物：`{stats}`、`{log}`（末尾有 NDI 输入 / 发送端的计数：收 / 推 / SDK 丢 / 抖动均值与最大）。")
md.append(f"- 结论：**{'通过' if ok else '未通过'}**（L1 ≤ 3 + J 帧）。")
open(report, "w", encoding="utf-8").write("\n".join(md) + "\n")
print("\n".join(md))
sys.exit(0 if ok else 3)
PY
rc=$?
[ "$rc" = 0 ] && green "NDI 回环 L1 通过 → $report" || red "NDI 回环 L1 未通过（$report）"
exit $rc
