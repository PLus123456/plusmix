#!/usr/bin/env python3
"""make perf-baseline 的判定与报告（W4-A；测试标准 §5 L5、§7 模板）。scripts/perf/perf-baseline.sh 跑完调它；--skip-run 时可单独重出报告。

退出码：0 = 无退步且都在必须档内；1 = 有退步（同机同大版本的上一版基线）或掉出必须档；2 = 产物缺失。
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perfjudge as pj  # noqa: E402


def read_kv(path):
    out = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    return out


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def show_path(p):
    """仓库里的路径写相对路径，仓库外（临时目录）写绝对路径。"""
    rel = os.path.relpath(p)
    return os.path.abspath(p) if rel.startswith("..") else rel


def f(v, d=3):
    return "—" if v is None else f"{v:.{d}f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--label", default="perf")
    ap.add_argument("--minutes", type=float, default=5)
    ap.add_argument("--show", required=True)
    ap.add_argument("--script", required=True)
    ap.add_argument("--rules", default="scripts/perf/regression.json")
    ap.add_argument("--baseline-dir", default="baselines")
    ap.add_argument("--reference", default="", help="不同系统 / 不同场景的参考基线（只列、不判），如 baselines/g4-m5max.json")
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--report", default="")
    ap.add_argument("--e4-dir", default="")
    ap.add_argument("--e4-meta", default="")
    a = ap.parse_args()

    env = read_kv(os.path.join(a.out_dir, "environment.txt"))
    lines, bad = pj.load_stats(os.path.join(a.out_dir, "stats.jsonl")) if os.path.exists(os.path.join(a.out_dir, "stats.jsonl")) else ([], 0)
    if not lines:
        print(f"没有 {a.out_dir}/stats.jsonl", file=sys.stderr)
        return 2
    cur = pj.perf_metrics(lines)
    machine = pj.machine_tag(env.get("chip", ""), env.get("model", ""))
    macos = env.get("macos", "?")

    # powermetrics（sudo 才有）
    pm = {}
    pm_path = os.path.join(a.out_dir, "powermetrics.plist")
    if os.path.exists(pm_path) and os.path.getsize(pm_path) > 0:
        pm = pj.powermetrics_summary(pj.parse_powermetrics(open(pm_path, "rb").read()))
        for k in ("pm_gpu_active_avg_pct", "pm_gpu_active_p95_pct"):
            if k in pm:
                cur[k] = pm[k]
    pm_err = ""
    if os.path.exists(os.path.join(a.out_dir, "powermetrics.err")):
        pm_err = open(os.path.join(a.out_dir, "powermetrics.err"), encoding="utf-8", errors="replace").read().strip()[:300]

    # E4
    e4, e4_meta, e4_note = {}, None, ""
    if a.e4_dir:
        e4_meta = load_json(a.e4_meta) if a.e4_meta else None
        segs = [tuple(s) for s in (e4_meta or {}).get("segments", [])]
        vlog = load_json(os.path.join(a.e4_dir, "vmaf.json"))
        if vlog:
            e4 = pj.vmaf_summary(vlog, segs)
        elif os.path.exists(os.path.join(a.e4_dir, "psnr.log")):
            vals = [float(m.group(1)) for m in re.finditer(r"psnr_y:([0-9.]+|inf)", open(os.path.join(a.e4_dir, "psnr.log")).read()) if m.group(1) != "inf"]
            if vals:
                e4 = {"e4_psnr_y_db": sum(vals) / len(vals), "frames": len(vals), "segments": {}}
                e4_note = "没有 libvmaf，按 PSNR 判（§4 E4 的 VMAF 回归口径不适用）"
        align = read_kv(os.path.join(a.e4_dir, "alignment.txt"))
        e4["offset"] = align.get("offset")
        e4["align_cost"] = align.get("cost")
        for k in ("e4_vmaf_mean", "e4_psnr_y_db"):
            if k in e4:
                cur[k] = e4[k]
        e4_lines, _ = pj.load_stats(os.path.join(a.e4_dir, "e4-stats.jsonl")) if os.path.exists(os.path.join(a.e4_dir, "e4-stats.jsonl")) else ([], 0)
        if e4_lines:
            e4["encoder_skipped"] = sum(int(e.get("skipped", 0)) for e in e4_lines[-1].get("encoder", []))
            e4["missed_render"] = int(e4_lines[-1]["missed_render"]) - int(e4_lines[0]["missed_render"])

    # 同机同大版本的上一版基线
    rules = pj.load_rules(a.rules)
    bpath = pj.baseline_path(a.baseline_dir, machine, macos)
    base = load_json(bpath)
    base_perf = (base or {}).get("perf", {})
    comparable_note = ""
    if base:
        bnotes = base.get("notes", {})
        if bnotes.get("show") and bnotes.get("show") != a.show:
            comparable_note += f"基线场景 {bnotes.get('show')} ≠ 本次 {a.show}；"
        bsha = (base.get("e4") or {}).get("source_sha256")
        if bsha and e4_meta and bsha != e4_meta.get("sha256"):
            comparable_note += "E4 源片段变了（sha256 不同，多半换了 ffmpeg），E4 不判退步；"
            base_perf = {k: v for k, v in base_perf.items() if not k.startswith("e4_")}
    rows = pj.compare(cur, base_perf, rules) if base else []
    regressions = [r for r in rows if r["regression"]]

    # §4 必须档（能从这 5 分钟判的：V1 / V2 / V3 / S3）
    must_rows = [
        ("V1 渲染耗时", f"avg {f(cur['v1_avg_ms'])} ms / p99 {f(cur['v1_p99_ms'])} ms", "avg ≤ 6, p99 ≤ 12", "avg ≤ 4, p99 ≤ 8",
         cur["v1_avg_ms"] <= pj.MUST["v1_avg_ms"] and cur["v1_p99_ms"] <= pj.MUST["v1_p99_ms"],
         cur["v1_avg_ms"] <= pj.TARGET["v1_avg_ms"] and cur["v1_p99_ms"] <= pj.TARGET["v1_p99_ms"]),
        ("V2 渲染滞后丢帧", f"{cur['v2_missed']} 帧 / {cur['ticks']} 拍（{cur['v2_ratio'] * 100:.4f}%）", "≤ 0.0200%", "0",
         cur["v2_ratio"] <= pj.MUST["v2_ratio"], cur["v2_missed"] == 0),
        ("V3 抖动", f"p99 {f(cur['v3_p99_ms'])} ms / max {f(cur['v3_max_ms'])} ms", "p99 ≤ 4", "p99 ≤ 2",
         cur["v3_p99_ms"] <= pj.MUST["v3_p99_ms"], cur["v3_p99_ms"] <= pj.TARGET["v3_p99_ms"]),
        ("S3 CPU（进程，100 = 一个核）", f"avg {f(cur['cpu_avg_pct'], 1)}% / p95 {f(cur['cpu_p95_pct'], 1)}%", "avg ≤ 60%", "avg ≤ 40%",
         cur["cpu_avg_pct"] <= pj.MUST["cpu_avg_pct"], cur["cpu_avg_pct"] <= pj.TARGET["cpu_avg_pct"]),
        ("S3 GPU（IOKit Device Utilization）", f"avg {f(cur['gpu_avg_pct'], 1)}% / p95 {f(cur['gpu_p95_pct'], 1)}%", "avg ≤ 50%", "avg ≤ 35%",
         cur["gpu_avg_pct"] <= pj.MUST["gpu_avg_pct"], cur["gpu_avg_pct"] <= pj.TARGET["gpu_avg_pct"]),
    ]
    must_fail = [r for r in must_rows if not r[4]]

    # ---- 报告 ----
    report = a.report or f"reports/W4-perf-{machine}-macos{pj.os_major(macos)}.md"
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    out = []
    w = out.append
    w(f"# W4-A L5 性能基线：{machine} / macOS {macos}（make perf-baseline，{a.label}）\n")
    verdict = "✅ 无退步" if not regressions and not must_fail else "❌ " + "；".join(
        [f"退步：{r['name']}" for r in regressions] + [f"掉出必须档：{r[0]}" for r in must_fail])
    first = not base
    w(f"**判定：{verdict}**" + ("（同系统还没有基线：这次是第一版，写入 " + show_path(bpath) + "，不判退步）" if first else "") + "\n")
    w(f"生成：{now}。数据：`{a.out_dir}/`（stats.jsonl、headless.log、load.log、powermetrics.plist、e4/）。脚本：scripts/perf/perf-baseline.sh → scripts/perf/perf_report.py。\n")
    w("## 1. 版本 / 机器 / 环境（§7 报告头、§2.8）\n")
    w("| 项 | 值 |\n|---|---|")
    w(f"| 提交 | `{env.get('commit', '?')}`（{env.get('branch', '?')}，未提交改动 {env.get('dirty', '?')} 个） |")
    w(f"| 机器 | {env.get('chip', '?')} · {env.get('model', '?')}（{env.get('model_id', '?')}）· {env.get('cores', '?')} 核 · {env.get('memory_gb', '?')} GB |")
    w(f"| macOS | {macos}（{env.get('macos_build', '?')}）；{env.get('xcode', '')}；{env.get('swift', '')} |")
    w(f"| 电源 | {env.get('power', '?')}（电量 {env.get('battery_pct', '?')}%，适配器 {env.get('adapter_watts', '?')} W）；powermode {env.get('powermode', '?')}（0 自动 / 1 低电量 / 2 高性能） |")
    pm_therm = pm.get("pm_thermal_pressure") if pm else None
    w(f"| 温度环境 | thermalState 开跑前 {env.get('thermal_state', '未采')} / 跑完 {env.get('thermal_state_after', '未采')}；{env.get('pmset_therm', '')}；powermetrics thermal pressure {pm_therm if pm_therm else '未采（无 sudo）'}；室温 {env.get('ambient', '未记录')} |")
    w(f"| 负载 | 开跑前 {env.get('load_before', '?')} → 跑完 {env.get('load_after', '?')}；占 CPU 前几名：{env.get('top_processes_before', '')} |")
    busy = (env.get("busy_processes", "") + " " + env.get("busy_processes_after", "")).strip()
    w(f"| 在跑的编译 / 测试进程 | {busy if busy else '无'} |")
    w(f"| 工具 | {env.get('ffmpeg', '')}；MediaMTX {env.get('mediamtx', '')}；NDI SDK {env.get('ndi_sdk', '')} |\n")
    w("## 2. 场景\n")
    w(f"- V1–V3 / S3：`{a.show}` + `{a.script}` 的前 {a.minutes:g} 分钟（{cur['lines']} 行 stats，{cur['ticks']} 拍），`--record --iso-audio 4 --audio-device null`，不起 API；"
      "caffeinate -u -i -d -s 包住 headless。")
    if e4_meta:
        segs = "、".join(f"{s[0]} {s[1]}–{s[2] - 1}" for s in e4_meta.get("segments", []))
        w(f"- E4：`scripts/perf/make-e4-clip.sh` 的片段（{e4_meta.get('frames')} 帧 1080p60 ProRes 422 HQ，sha256 `{e4_meta.get('sha256', '')[:16]}`，{e4_meta.get('ffmpeg', '')}；段：{segs}）"
          f" → headless 文件输入（`--preset perf-e4`）→ H.264 6 Mb/s 录制 → 录像第 {e4.get('offset')} 帧对源第 0 帧 → libvmaf vmaf_v0.6.1（另出 PSNR-Y / SSIM）。{e4_note}")
    w("")
    w("## 3. 判定（§4 必须档 / 目标档）\n")
    w("| 指标 | 数值 | 必须 | 目标 | 通过 |\n|---|---|---|---|---|")
    for name, val, must, target, ok, tgt in must_rows:
        w(f"| {name} | {val} | {must} | {target} | {'✅ 达目标' if ok and tgt else ('✅' if ok else '❌')} |")
    if pm:
        freq = pm.get("pm_gpu_freq_avg_mhz")
        w(f"| S3 GPU（powermetrics，对照） | avg {f(pm.get('pm_gpu_active_avg_pct'), 1)}% / p95 {f(pm.get('pm_gpu_active_p95_pct'), 1)}%（{pm['pm_samples']} 样，GPU 频率均值 {f(freq, 0)} MHz，GPU 功耗均值 {f(pm.get('pm_gpu_power_avg_mw'), 0)} mW 原始口径） | avg ≤ 50% | avg ≤ 35% | "
          f"{'✅' if pm.get('pm_gpu_active_avg_pct', 0) <= 50 else '❌'} |")
    else:
        w(f"| S3 GPU（powermetrics，对照） | 未采：没有 sudo{('（' + pm_err + '）') if pm_err else ''} | — | — | — |")
    if e4:
        seg_txt = "；".join(f"{k} {f(v.get('vmaf_mean'), 2)}（最低 {f(v.get('vmaf_min'), 2)}，PSNR-Y {f(v.get('psnr_y_db'), 2)} dB）" for k, v in e4.get("segments", {}).items())
        w(f"| E4 编码画质 | VMAF 均值 {f(e4.get('e4_vmaf_mean'), 2)}（调和 {f(e4.get('e4_vmaf_harmonic'), 2)}，5% 分位 {f(e4.get('e4_vmaf_p5'), 2)}，最低 {f(e4.get('e4_vmaf_min'), 2)}）；"
          f"PSNR-Y {f(e4.get('e4_psnr_y_db'), 2)} dB；SSIM {f(e4.get('e4_ssim'), 4)}；分段：{seg_txt}；编码 skipped {e4.get('encoder_skipped', '—')}、missed_render {e4.get('missed_render', '—')} | "
          "相对上一版本 VMAF 不降 > 1 分；绝对值按片源标定写入基线 | 不降 | " + ("—（第一版）" if first else ("❌" if any(r['metric'].startswith('e4_') for r in regressions) else "✅")) + " |")
    w("")
    w(f"## 4. 与同系统上一版基线比（L5：退步 > 10% 非零退出；E4 另按 VMAF 降 > 1 分）\n")
    if first:
        w(f"`{show_path(bpath)}` 之前不存在：本次写成第一版（prompt 70 第 7 条：27 上的第一版基线单独存，同系统才比退步）。\n")
    else:
        w(f"上一版：`{show_path(bpath)}`（提交 {base.get('commit', '?')}，{base.get('date', '?')}，macOS {base.get('notes', {}).get('macos', '?')}）。{comparable_note}\n")
        w("| 指标 | 本次 | 上一版 | 差 | 退步 | 说明 |\n|---|---|---|---|---|---|")
        for r in rows:
            dp = "—" if r["delta_pct"] is None else f"{r['delta_pct']:+.1f}%"
            w(f"| {r['name']} | {pj.fmt_metric(r['metric'], r['cur'])} | {pj.fmt_metric(r['metric'], r['base'])} | {dp} | {'❌' if r['regression'] else '✅'} | {r['note']} |")
        w("")
    ref = load_json(a.reference) if a.reference else None
    if ref:
        rs = ref.get("summary", {})
        def ser(key, field):
            return (rs.get(key) or {}).get(field)
        w(f"## 5. 参考：`{a.reference}`（{ref.get('checkpoint', '')}，macOS {ref.get('notes', {}).get('macos', '?')}，{ref.get('scenario', '')} {ref.get('durationSeconds', 0) / 60:.0f} 分钟、带 API 客户端；不同系统 / 不同时长，只列不判）\n")
        w("| 量 | 本次 | 参考 |\n|---|---|---|")
        w(f"| V1 avg / p99 | {f(cur['v1_avg_ms'])} / {f(cur['v1_p99_ms'])} ms | {f(ser('renderMs', 'avg'))} / {f(ser('renderMs', 'p99'))} ms |")
        w(f"| V3 p99 / max | {f(cur['v3_p99_ms'])} / {f(cur['v3_max_ms'])} ms | {f(ser('jitterMs', 'p99'))} / {f(ser('jitterMs', 'max'))} ms |")
        w(f"| CPU avg | {f(cur['cpu_avg_pct'], 1)}% | {f(ser('cpuPct', 'avg'), 1)}% |")
        w(f"| GPU avg | {f(cur['gpu_avg_pct'], 1)}% | {f(ser('gpuPct', 'avg'), 1)}% |")
        w(f"| V2 | {cur['v2_missed']} | {rs.get('missedRender', '—')} |\n")
    w("## 6. 数据存放\n")
    w(f"- stats：`{a.out_dir}/stats.jsonl`（{cur['lines']} 行{'，坏行 ' + str(bad) if bad else ''}）；headless：`{a.out_dir}/headless.log`；负载：`{a.out_dir}/load.log`；录制：`{a.out_dir}/perf.mov`")
    w(f"- powermetrics：`{pm_path}`" + ("" if pm else "（没有）"))
    if a.e4_dir:
        w(f"- E4：`{a.e4_dir}/`（e4.mov、vmaf.json、rec-yavg.txt / src-yavg.txt、alignment.txt）；源片段 `.build/perf/e4/e4-source.mov`")
    w("")
    w("## 7. 已知问题与放行说明\n")
    notes = []
    if busy:
        notes.append(f"跑的时候机器上有别的编译 / 测试进程（{busy}）：V1 / V3 / S3 会偏高，这次的数不宜当基线（prompt 70 第 7 条）。")
    if not pm:
        notes.append("GPU 的 powermetrics 对照没采（没有 sudo）；GPU 按 §3 S3 的正式口径（IOKit）判。")
    if env.get("power") not in (None, "AC"):
        notes.append(f"没接电源（{env.get('power')}），§2.8 要求接电源。")
    for n in notes:
        w(f"- {n}")
    w("")
    os.makedirs(os.path.dirname(report) or ".", exist_ok=True)
    open(report, "w", encoding="utf-8").write("\n".join(out) + "\n")

    summary = {"machine": machine, "macos": macos, "commit": env.get("commit"), "perf": cur, "powermetrics": pm, "e4": e4,
               "must_fail": [r[0] for r in must_fail], "regressions": regressions, "baseline": show_path(bpath), "first": first}
    json.dump(summary, open(os.path.join(a.out_dir, "perf-summary.json"), "w"), ensure_ascii=False, indent=1)

    # 基线：同系统第一版自动写；已有时只有 --write-baseline 才覆盖
    if first or a.write_baseline:
        sb = load_json(os.path.join(a.out_dir, "summary-baseline.json")) or {}
        sb["checkpoint"] = "W4-A-L5"
        sb["machine"] = machine
        sb.setdefault("notes", {})
        sb["notes"].update({"macos": macos, "show": a.show, "scenario": a.script, "minutes": f"{a.minutes:g}", "power": env.get("power", ""),
                            "powermode": env.get("powermode", ""), "busy_processes": busy, "load_before": env.get("load_before", ""),
                            "powermetrics": "yes" if pm else "no"})
        sb["perf"] = {k: v for k, v in cur.items() if isinstance(v, (int, float))}
        if e4:
            sb["e4"] = {"source_sha256": (e4_meta or {}).get("sha256"), "ffmpeg": (e4_meta or {}).get("ffmpeg"),
                        **{k: v for k, v in e4.items() if k != "segments"}, "segments": e4.get("segments", {})}
        if pm:
            sb["powermetrics"] = pm
        os.makedirs(a.baseline_dir, exist_ok=True)
        json.dump(sb, open(bpath, "w", encoding="utf-8"), ensure_ascii=False, indent=1, sort_keys=True)
        print(f"基线写入 {bpath}")
    print(f"报告：{report}")
    return 1 if (regressions or must_fail) else 0


if __name__ == "__main__":
    sys.exit(main())
