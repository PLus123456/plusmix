#!/usr/bin/env python3
"""S4 热降频的判定与报告（scripts/perf/s4-thermal.sh 调；W4-A）。--blocked 时只写 BLOCKED 报告头。"""
import argparse
import datetime
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perfjudge as pj  # noqa: E402


def read_kv(path):
    out = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--machine", default="unknown")
    ap.add_argument("--report", required=True)
    ap.add_argument("--blocked", default="")
    ap.add_argument("--not-fanless", action="store_true", help="--force 在有风扇的机器上跑：只验证流程，不作 S4 判定")
    a = ap.parse_args()
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    out = [f"# W4-A S4 热降频：{a.machine}\n", f"生成：{now}。脚本：scripts/perf/s4-thermal.sh → scripts/perf/s4_report.py。\n"]
    if a.blocked:
        out.append(f"**{a.blocked}**\n")
        out.append("S4（测试标准 §3）要在无风扇机型（M1 Air 8 GB）上跑标准负载 1 小时、powermetrics 记频率、对照 V2。解锁条件：借到 M1 Air，在它的终端里跑 "
                   "`scripts/perf/s4-thermal.sh`（会问一次 sudo 密码），接电源、室温正常、别开别的程序。\n")
        os.makedirs(os.path.dirname(a.report) or ".", exist_ok=True)
        open(a.report, "w", encoding="utf-8").write("\n".join(out) + "\n")
        print(f"报告：{a.report}")
        return 0
    env = read_kv(os.path.join(a.out_dir, "environment.txt"))
    run = read_kv(os.path.join(a.out_dir, "run.txt"))
    lines, _ = pj.load_stats(os.path.join(a.out_dir, "stats.jsonl"))
    if not lines:
        print("没有 stats.jsonl", file=sys.stderr)
        return 2
    blob = open(os.path.join(a.out_dir, "powermetrics.plist"), "rb").read() if os.path.exists(os.path.join(a.out_dir, "powermetrics.plist")) else b""
    samples = pj.parse_powermetrics(blob)
    t = float(run.get("powermetrics_start_epoch") or lines[0]["ts"])
    for s in samples:
        stamp = s.get("timestamp")
        if isinstance(stamp, datetime.datetime):
            s["_ts"] = stamp.replace(tzinfo=datetime.timezone.utc).timestamp() if stamp.tzinfo is None else stamp.timestamp()
        else:
            t += float(s.get("elapsed_ns") or 0) / 1e9
            s["_ts"] = t
    rows = pj.s4_timeline(samples, lines)
    v = pj.s4_verdict(rows)
    perf = pj.perf_metrics(lines)
    judged = not a.not_fanless
    mark = ("✅" if v["pass"] else "❌") if judged else "—（有风扇的机器上 --force 走流程，不判）"
    out.append(f"**S4：{mark}**（{'出现降频：第 ' + str(v['onset_minute']) + ' 分钟起，' + v['why'] if v['throttled'] else v['note']}；"
               f"降频之后 V2 {v['v2_after']} 帧 / {v['ticks_after']} 拍 = {v['v2_ratio_after'] * 100:.4f}%，必须档 ≤ 0.02%）\n")
    out.append("## 环境\n")
    out.append(f"- {env.get('chip', '?')} · {env.get('model', '?')}（{env.get('model_id', '?')}）· macOS {env.get('macos', '?')}；电源 {env.get('power', '?')}，powermode {env.get('powermode', '?')}；"
               f"开跑前 thermalState {env.get('thermal_state', '?')}；室温 {env.get('ambient', '未记录')}；负载 {env.get('load_before', '?')}")
    out.append(f"- 全程：V1 avg {perf['v1_avg_ms']:.3f} ms / p99 {perf['v1_p99_ms']:.3f} ms；V2 {perf['v2_missed']} / {perf['ticks']}；V3 p99 {perf['v3_p99_ms']:.3f} ms；"
               f"CPU avg {perf['cpu_avg_pct']:.1f}%；GPU avg {perf['gpu_avg_pct']:.1f}%；powermetrics {len(samples)} 样\n")
    out.append("## 每分钟\n")
    names = sorted({k for r in rows for k in r["cluster_mhz"]})
    out.append("| " + " | ".join(["分钟", "thermal pressure"] + [f"{n} MHz" for n in names] + ["GPU MHz", "V2", "拍"]) + " |")
    out.append("|" + "---|" * (len(names) + 5))
    for r in rows:
        cells = [str(r["minute"]), r["pressure"] or "—"] + [f"{r['cluster_mhz'].get(n, 0):.0f}" for n in names]
        cells += [f"{r['gpu_mhz']:.0f}" if r["gpu_mhz"] is not None else "—", str(r["missed"]), str(r["ticks"])]
        out.append("| " + " | ".join(cells) + " |")
    out.append("")
    os.makedirs(os.path.dirname(a.report) or ".", exist_ok=True)
    open(a.report, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"报告：{a.report}")
    return 0 if (v["pass"] or not judged) else 1


if __name__ == "__main__":
    sys.exit(main())
