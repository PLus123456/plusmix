#!/usr/bin/env python3
"""G2 检查点报告生成（scripts/gate2.sh 第 5 步）。

一次运行的产物（out-dir：environment.txt、stats.jsonl、summary.md / summary.json、probe-*.json / .md、ffprobe.json、headless.log）
→ reports/G2-run-<label>.md（测试标准 §7 模板的"每个指标：数值 · 阈值 · 通过否 · 与上一版本的差"+ 文件路径）
→ reports/G2.md = reports/G2-notes.md（人工写：版本、机器、合并记录、人工检查、已知问题与放行说明）+ 所有 reports/G2-run-*.md。

指标口径：
  V1 / V2 / V3 / A1 / E1 / S2 / S3 来自 stats.jsonl（StatsSummary，铁律 4：只有这一份统计）；
  V4 两个口径都给：stats.jsonl 的帧槽计数（全程、所有输入）和 frameprobe 读录制文件（只有在播的那路）；
      "设计外"按精确速率核算：设计内 = ceil(K × |1 − r/P|) + 1 帧相位余量（K 为该路的拍数 / 帧数，r 输入真实帧率含漂移，P 节目帧率），
      超出的才算设计外；StatsSummary 自己按平均帧率算的比例也列出（阈值 0.05%）。
  V5 = 录制文件总帧数 − 运行时长 × 节目帧率（拍数），用的是运行参数而不是文件自身时长，尾部缺帧也能看出来。
  V6 / A2 / A3 在 M0 只记录不判定（G3 才判）。
"""
import argparse, datetime, glob, json, math, os, re, sys


def read_kv(path):
    d = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                d[k] = v
    return d


def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def read_text(path, default=""):
    try:
        return open(path, encoding="utf-8").read()
    except Exception:
        return default


def fmt(v, digits=3):
    return "—" if v is None else f"{v:.{digits}f}"


def mark(ok):
    return "—" if ok is None else ("✅" if ok else "❌")


def delta(cur, prev, unit, digits=3):
    if cur is None or prev is None:
        return "—"
    d = cur - prev
    return f"{'−' if d < 0 else '+'}{abs(d):.{digits}f} {unit}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--minutes", type=float, required=True)
    ap.add_argument("--show", required=True)
    ap.add_argument("--script", required=True)
    ap.add_argument("--baseline", default="")
    ap.add_argument("--run-report", required=True)
    ap.add_argument("--notes", required=True)
    ap.add_argument("--report", required=True)
    a = ap.parse_args()
    out = a.out_dir

    env = read_kv(os.path.join(out, "environment.txt"))
    summary = load_json(os.path.join(out, "summary.json"), {}) or {}
    key = summary.get("key", {})
    per_input_stats = summary.get("perInput", {})
    summary_md = read_text(os.path.join(out, "summary.md"))
    probe = load_json(os.path.join(out, "probe-stats.json"), {}) or {}
    switches = load_json(os.path.join(out, "probe-switches.json"), {}) or {}
    av = load_json(os.path.join(out, "probe-av.json"), {}) or {}
    ffp = load_json(os.path.join(out, "ffprobe.json"), {}) or {}
    show = load_json(a.show, {}) or {}
    scenario = load_json(a.script, {}) or {}
    headless_log = read_text(os.path.join(out, "headless.log"))
    baseline = load_json(a.baseline, None) if a.baseline else None
    bsum = (baseline or {}).get("summary", {}) if baseline else {}

    fr = show.get("mixer", {}).get("format", {}).get("frameRate", {"numerator": 60, "denominator": 1})
    program_fps = fr["numerator"] / fr["denominator"]
    # 每路真实帧率（含漂移），键 = 图案 ID = 编号 − 1
    rates = {}
    input_lines = []
    for inp in show.get("inputs", []):
        s = inp["source"]["synthetic"]["settings"]
        r = s["frameRate"]["numerator"] / s["frameRate"]["denominator"] * (1 + s.get("clockDriftPpm", 0) / 1e6)
        pid = s.get("patternID")
        if pid is None:
            pid = (inp["number"] - 1) % 16
        rates[pid] = r
        rates[("number", inp["number"])] = r
        input_lines.append(f"{inp['number']}. {inp['name']}（ID {pid}，{r:.4f} fps）")

    # ---- V1 V2 V3 ----
    v1_avg, v1_p99 = key.get("v1_avg_ms"), key.get("v1_p99_ms")
    v2 = key.get("v2_missed")
    v3_p99, v3_max = key.get("v3_p99_ms"), key.get("v3_max_ms")
    ticks = key.get("ticks")
    b_v1_avg = (bsum.get("renderMs") or {}).get("avg")
    b_v1_p99 = (bsum.get("renderMs") or {}).get("p99")
    b_v3_p99 = (bsum.get("jitterMs") or {}).get("p99")
    b_cpu = (bsum.get("cpuPct") or {}).get("avg")
    b_gpu = (bsum.get("gpuPct") or {}).get("avg")
    b_rss = (bsum.get("rssMb") or {}).get("max")

    # ---- V4：stats.jsonl 口径（全程、所有输入）+ 精确核算 ----
    v4_rows = []
    v4_worst_excess = 0.0
    v4_design_out_total = 0
    T = ticks or 0
    for pid_s, p in sorted(per_input_stats.items(), key=lambda kv: int(kv[0])):
        number = int(pid_s)
        r = rates.get(("number", number))
        dup, drop = p.get("dup", 0), p.get("drop", 0)
        exp_dup = T * max(0.0, 1 - r / program_fps) if r else None
        exp_drop = T * max(0.0, r / program_fps - 1) if r else None
        out_dup = max(0, dup - math.ceil(exp_dup) - 1) if exp_dup is not None else None
        out_drop = max(0, drop - math.ceil(exp_drop) - 1) if exp_drop is not None else None
        if out_dup is not None:
            v4_design_out_total += out_dup + out_drop
        v4_worst_excess = max(v4_worst_excess, p.get("excessDupRatio", 0), p.get("excessDropRatio", 0))
        v4_rows.append(f"| {number} | {fmt(r, 4)} | {fmt(p.get('fps', {}).get('avg'), 3)} | {dup} | {fmt(exp_dup, 1)} | {drop} | {fmt(exp_drop, 1)} | "
                       f"{'—' if out_dup is None else out_dup + out_drop} | {p.get('excessDupRatio', 0) * 100:.4f}% / {p.get('excessDropRatio', 0) * 100:.4f}% |")

    # ---- V4：frameprobe 口径（只有在播那路）----
    probe_rows = []
    probe_design_out_total = 0
    probe_backward = 0
    for s in probe.get("inputs", []):
        pid = s.get("inputID")
        K = s.get("frames", 0)
        r = s.get("inputFps") or rates.get(pid)
        dup, drop = s.get("duplicateFrames", 0), s.get("droppedFrames", 0)
        exp_dup = K * max(0.0, 1 - r / program_fps) if r else None
        exp_drop = K * max(0.0, r / program_fps - 1) if r else None
        out_dup = max(0, dup - math.ceil(exp_dup) - 1) if exp_dup is not None else 0
        out_drop = max(0, drop - math.ceil(exp_drop) - 1) if exp_drop is not None else 0
        probe_design_out_total += out_dup + out_drop
        probe_backward += s.get("backwardJumps", 0)
        probe_rows.append(f"| {pid} | {K} | {fmt(r, 4)} | {dup}（{s.get('duplicateRatio', 0) * 100:.2f}%） | {fmt(exp_dup, 1)} | {drop} | {fmt(exp_drop, 1)} | "
                          f"{out_dup + out_drop} | {s.get('backwardJumps', 0)} | {mark(s.get('passV4'))} |")

    # ---- V5 ----
    total_frames = probe.get("totalFrames")
    expected_run = round(a.minutes * 60 * program_fps)
    v5_delta = (total_frames - expected_run) if total_frames is not None else None
    undecodable = probe.get("undecodableFrames", 0)
    unidentified = probe.get("unidentifiedFrames", 0)

    # ---- G2 通过标准 ----
    checks = [
        ("V1 渲染耗时（本机参考线）", f"avg {fmt(v1_avg)} ms / p99 {fmt(v1_p99)} ms", "avg ≤ 2 ms（M5 Max，G2 prompt）", v1_avg is not None and v1_avg <= 2.0,
         delta(v1_avg, b_v1_avg, "ms")),
        ("V1 渲染耗时（必须档）", f"avg {fmt(v1_avg)} / p99 {fmt(v1_p99)} ms", "avg ≤ 6，p99 ≤ 12（目标 ≤ 4 / ≤ 8）",
         v1_avg is not None and v1_avg <= 6 and v1_p99 <= 12, delta(v1_p99, b_v1_p99, "ms（p99）")),
        ("V2 渲染滞后丢帧", f"{int(v2) if v2 is not None else '—'} 帧 / {int(T)} 拍", f"{a.minutes:g} 分钟内 0", v2 is not None and v2 == 0, "—"),
        ("V3 输出抖动", f"p99 {fmt(v3_p99)} ms / max {fmt(v3_max)} ms（jitter_ms 是每秒窗口最大值，p99 取各秒最大值）", "p99 ≤ 4 ms（目标 ≤ 2）",
         v3_p99 is not None and v3_p99 <= 4.0, delta(v3_p99, b_v3_p99, "ms")),
        ("V4 设计外重复 / 丢弃", f"精确核算设计外 {v4_design_out_total} 帧（stats.jsonl 全程）/ {probe_design_out_total} 帧（frameprobe 在播段）；"
         f"StatsSummary 平均帧率口径最大设计外 {v4_worst_excess * 100:.4f}%；帧号倒退 {probe_backward}",
         "设计外 0（精确核算）；≤ 0.05%（§4 必须档）", v4_design_out_total == 0 and probe_design_out_total == 0 and probe_backward == 0 and v4_worst_excess <= 0.0005, "—"),
        ("V5 帧计数一致性", f"文件 {total_frames} 帧 − 运行 {expected_run} 拍 = {v5_delta:+d} 帧" if v5_delta is not None else "—",
         "|Δ| ≤ 2 帧（60 分钟）；10 分钟同样要求", v5_delta is not None and abs(v5_delta) <= 2, "—"),
    ]
    all_pass = all(c[3] for c in checks)

    # ---- 信息项 ----
    e1 = key.get("e1_skipped")
    a1 = (key.get("audio_dropouts") or 0) + (key.get("audio_underruns") or 0)
    cpu, gpu = key.get("cpu_avg_pct"), key.get("gpu_avg_pct")
    rss_min, rss_max, rss_slope = key.get("rss_min_mb"), key.get("rss_max_mb"), key.get("rss_slope_mb_per_h")
    n_switch = len(switches.get("switches", []))
    clean = switches.get("allCutsClean")
    kinds = {}
    for sw in switches.get("switches", []):
        kinds[sw.get("kind", "?")] = kinds.get(sw.get("kind", "?"), 0) + 1

    streams = {s.get("codec_name"): s for s in ffp.get("streams", [])}
    vstream = next((s for s in ffp.get("streams", []) if s.get("width")), {})
    ff_dur = (ffp.get("format") or {}).get("duration")

    tail = "\n".join(headless_log.strip().splitlines()[-16:])

    lines = []
    lines.append(f"## 运行 {a.label}：{a.minutes:g} 分钟标准负载")
    lines.append("")
    lines.append(f"- 日期：{env.get('date', '?')}；提交：`{env.get('commit', '?')}`（{env.get('branch', '?')}，未提交改动 {env.get('dirty', '?')} 个文件）")
    lines.append(f"- 机器：{env.get('cpu', '?')}，{env.get('cores', '?')} 核，{env.get('memory_gb', '?')} GB；macOS {env.get('macos', '?')}；{env.get('xcode', '?')}")
    lines.append(f"- 电源：{env.get('power', '?')}；温度 / 降频：{env.get('thermal', '无记录')}")
    lines.append(f"- 负载：跑前 {env.get('load_before', '?')} → 跑后 {env.get('load_after', '?')}；跑前占 CPU 的进程：{env.get('top_processes_before', '?')}")
    lines.append(f"- 场景：`{a.script}`（{scenario.get('durationTicks', '?')} 拍，{len(scenario.get('events', []))} 个事件：每 30 s Cut、每 5 min Fade 30 拍）；节目：`{a.show}`（{show.get('mixer', {}).get('format', {}).get('width', '?')}×{show.get('mixer', {}).get('format', {}).get('height', '?')}@{program_fps:g}）")
    lines.append("  - 输入：" + "；".join(input_lines))
    lines.append(f"- 命令：`switcher-headless run --show {a.show} --script {a.script} --duration {int(a.minutes * 60)} --stats {out}/stats.jsonl --record {out}/out.mov --audio-device null`")
    lines.append("")
    lines.append("### G2 通过标准（落地方案 §4 G2 + G2 prompt）")
    lines.append("")
    lines.append("| 指标 | 数值 | 阈值 | 通过 | 与上一版本的差 |")
    lines.append("|---|---|---|---|---|")
    for name, value, thr, ok, d in checks:
        lines.append(f"| {name} | {value} | {thr} | {mark(ok)} | {d} |")
    lines.append(f"| **总判定** | | | **{'✅ 通过' if all_pass else '❌ 未通过'}** | 基线：{a.baseline or '无（本次即基线）'} |")
    lines.append("")
    lines.append("### 其它指标（M0 只记录；阈值按测试标准 §4）")
    lines.append("")
    lines.append("| 指标 | 数值 | 阈值 | 通过 | 与上一版本的差 |")
    lines.append("|---|---|---|---|---|")
    lines.append(f"| E1 编码滞后跳帧 | {int(e1) if e1 is not None else '—'} | 标准负载下 0 | {mark(None if e1 is None else e1 == 0)} | — |")
    lines.append(f"| A1 音频断裂（空设备 + 合成音频） | 超时 + 欠载 = {int(a1)} | 0（硬性，G3 判） | {mark(a1 == 0)} | — |")
    lines.append(f"| S2 内存增长 | {fmt(rss_slope, 2)} MB/h（RSS {fmt(rss_min, 0)} → {fmt(rss_max, 0)} MB；{'已丢前 30 min' if a.minutes >= 60 else '不足 1 h，整段拟合仅供参考'}） | ≤ 10 MB/h | {mark(None if rss_slope is None else rss_slope <= 10)} | {delta(rss_max, b_rss, 'MB（RSS max）', 1)} |")
    lines.append(f"| S3 占用 | CPU avg {fmt(cpu, 1)}%（100 = 一核）/ GPU avg {fmt(gpu, 1)}%（IOKit Device Utilization） | CPU ≤ 60%，GPU ≤ 50% | {mark(None if cpu is None else cpu <= 60 and (gpu or 0) <= 50)} | CPU {delta(cpu, b_cpu, '%', 1)}；GPU {delta(gpu, b_gpu, '%', 1)} |")
    lines.append(f"| V6 切换（信息） | {n_switch} 次切换（{', '.join(f'{k} {v}' for k, v in sorted(kinds.items())) or '无'}），Cut 全部干净：{mark(clean)} | G3 判 | — | — |")
    if av:
        lines.append(f"| A2 / A3 音画偏移（信息） | 闪光 {av.get('flashCount')} / click {av.get('clickCount')} / 配对 {av.get('matchedCount')}；均值 {fmt(av.get('meanMs'), 3)} ms，最大 {fmt(av.get('maxAbsMs'), 3)} ms，斜率 {fmt(av.get('slopeMsPerSecond'), 4)} ms/s | ≤ 16.7 ms（G3 判） | {mark(av.get('passA2'))} | — |")
    lines.append(f"| 文件 | {total_frames} 帧（读不出帧号 {undecodable}，读不出 ID {unidentified}），ffprobe 时长 {ff_dur or '?'} s，{vstream.get('codec_name', '?')} {vstream.get('width', '?')}×{vstream.get('height', '?')} {vstream.get('avg_frame_rate', '?')}，音轨 {'有（' + ', '.join(k for k in streams if k and k != vstream.get('codec_name')) + '）' if len(streams) > 1 else '无'} | — | — | — |")
    lines.append("")
    lines.append("### V4 明细一：stats.jsonl 帧槽计数（全程、每路都在，铁律 4 的那份统计）")
    lines.append("")
    lines.append("| 输入 | 真实帧率 | 实测 fps avg | dup 累计 | 设计内 dup 期望 | drop 累计 | 设计内 drop 期望 | 设计外（精确核算） | StatsSummary 设计外 dup / drop |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    lines.extend(v4_rows)
    lines.append("")
    lines.append(f"设计内期望 = T × |1 − r/P|，T = {int(T)} 拍；设计外 = max(0, 实测 − ceil(期望) − 1)（1 帧相位余量）。")
    lines.append("")
    lines.append("### V4 明细二：frameprobe 读录制文件（只有在播的那路，切走再切回不算缺口）")
    lines.append("")
    lines.append("| ID | 在播帧数 K | 输入帧率 | 重复帧（比例） | 设计内 dup 期望 | 丢弃帧 | 设计内 drop 期望 | 设计外（精确核算） | 帧号倒退 | frameprobe V4（≤ 0.05%） |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|")
    lines.extend(probe_rows)
    lines.append("")
    lines.append("### StatsSummary 原表（§7 格式，含与基线的差）")
    lines.append("")
    lines.append(summary_md.strip())
    lines.append("")
    lines.append("### 文件（本机路径，不入库）")
    lines.append("")
    for name in ["stats.jsonl", "out.mov", "headless.log", "environment.txt", "summary.md", "summary.json", "probe-stats.json", "probe-stats.md", "probe-switches.json", "probe-switches.md", "probe-av.json", "probe-av.md", "ffprobe.json"]:
        p = os.path.join(out, name)
        if os.path.exists(p):
            lines.append(f"- `{os.path.abspath(p)}`（{os.path.getsize(p) / 1024:.0f} KB）")
    lines.append("")
    lines.append("### headless 收尾摘要（stdout 末尾）")
    lines.append("")
    lines.append("```")
    lines.append(tail)
    lines.append("```")
    lines.append("")
    lines.append("<details><summary>frameprobe switches（V6 信息）</summary>\n")
    lines.append(read_text(os.path.join(out, "probe-switches.md")).strip())
    lines.append("\n</details>\n")
    lines.append("<details><summary>frameprobe av（A2 / A3 信息）</summary>\n")
    lines.append(read_text(os.path.join(out, "probe-av.md")).strip())
    lines.append("\n</details>\n")
    lines.append("<details><summary>frameprobe stats 原表</summary>\n")
    lines.append(read_text(os.path.join(out, "probe-stats.md")).strip())
    lines.append("\n</details>\n")

    os.makedirs(os.path.dirname(a.run_report) or ".", exist_ok=True)
    with open(a.run_report, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    # ---- 拼 reports/G2.md ----
    notes = read_text(a.notes, "# G2 检查点报告\n\n（reports/G2-notes.md 还没写：版本 / 提交号、机器、合并记录、人工检查、已知问题与放行说明）\n")
    runs = sorted(glob.glob(os.path.join(os.path.dirname(a.run_report) or ".", "G2-run-*.md")),
                  key=lambda p: (0 if p.endswith("G2-run-10min.md") else 1, p))
    parts = [notes.rstrip() + "\n", "\n---\n\n# 自动结果（scripts/gate2.sh 生成，每次运行一节）\n",
             f"\n生成时间：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"]
    for r in runs:
        parts.append("\n" + read_text(r).rstrip() + "\n")
    with open(a.report, "w", encoding="utf-8") as f:
        f.write("".join(parts))
    print(f"{'通过' if all_pass else '未通过'}：{a.run_report} → {a.report}")
    return 0 if all_pass else 3


if __name__ == "__main__":
    sys.exit(main())
