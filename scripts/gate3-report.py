#!/usr/bin/env python3
"""G3 / G4 检查点报告生成（scripts/gate3.sh / gate4.sh 的最后一步；--checkpoint 选口径文字，判定逻辑同一份）。

一次运行的产物（out-dir：environment.txt、stats.jsonl、summary.json / .md、probe-*.json / .md、frames.json、ffprobe.json、
packets-v.csv、ffprobe-errors.txt、summary-c.json / report-c.md、headless.log、load.log）
→ reports/G3-run-<label>.md（测试标准 §7 模板：每个指标 数值 · 阈值 · 通过否 · 与上一版本的差 + 文件路径）
→ reports/G3.md = reports/G3-notes.md（人工写：版本、机器、合并记录、人工检查、已知问题与放行说明）+ 所有 reports/G3-run-*.md。

指标口径（测试标准 §1 / §3 / §4；G3 prompt 第 2 条 b）：
  V1 / V2 / V3 / E1 / S2 / S3 来自 stats.jsonl（StatsSummary，铁律 4）；V4 两个口径同 G2（stats.jsonl 全程 + frameprobe 在播段）；V5 同 G2。
  V6：frameprobe switches 里第 1000 拍必须有一次 cut（1 号 → 2 号，图案 ID 0 → 1），且 cleanCut（前 / 中 / 后帧灰度都不混合）；所有 Cut 干净（硬性）。
  V7：frameprobe fade --fade-at 3000 --duration 30 的最大曲线偏差 ≤ 1 帧；T-bar 25 / 50 / 75%：frames.json 里各停留窗中段的中心灰度
      折成 PVW 比例（PGM 1 号 64、PVW 2 号 192 → (gray − 64) / 128），与设定值之差 ≤ 2%（目标 1%）。
  A1：stats.jsonl 的 dropouts + underruns（硬性 0）；第三项"不连续"取 headless 收尾摘要里 AudioEngine 泵线程的流式检测计数（信息项，
      正式的离线口径要 frameprobe 学会按已知 click 位置排除——W1-A 的单子）。
  A2：frameprobe av，只取闪光落在整秒拍上的配对（59.94 的路在播时闪光周期 1.001 s 是已知假象，G2 报告第 5 条）：整秒配对的最大绝对值 ≤ 16.7 ms（目标 5），均值 / 标准差同时报（测试标准 §4，2026-09-19 定）。
  A3：同一序列的最小二乘斜率 × 8 h ≤ 16 ms（10 分钟外推，信息为主）。
  A4：frameprobe av 多文件（PGM + ISO 音轨）同一事件 click 时刻极差最大值 ≤ 16.7 ms（目标 1 ms）。
  E2：ffprobe 视频包表：10 s 滑窗平均码率与设定值之差 ≤ 10%（目标 5%）；1 s 窗峰值 ≤ 1.5×（目标 1.2×）。
  E3：关键帧间隔与设定值之差 ≤ ±1 帧（目标精确）。E5：ffprobe 无错；视频时长与运行拍数差 ≤ 1 帧；音视频轨道差 ≤ 20 ms（G4 起判定项：W1-E2 的录制器自己截两轨）。
  C1–C4：scripts/apitest evaluate 的 summary-c.json（C3 / C4 硬性）。
硬性项（V6、A1、C3、C4）不能 --waive。
"""
import argparse, datetime, glob, json, math, os, sys


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
    if ok == "info":
        return "—（参考）"
    return "—" if ok is None else ("✅" if ok else "❌")


def delta(cur, prev, unit, digits=3):
    if cur is None or prev is None:
        return "—"
    d = cur - prev
    return f"{'−' if d < 0 else '+'}{abs(d):.{digits}f} {unit}"


def percentile(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    i = min(len(s) - 1, max(0, int(round(p * len(s) + 0.5)) - 1))
    return s[i]


HARD = {"V6 切换准确性", "A1 音频断裂", "C3 状态一致性", "C4 并发正确性"}


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
    ap.add_argument("--waive", action="append", default=[], help="个案放行：'<判定表里的指标名>=<理由>'，可多次；硬性项不接受")
    ap.add_argument("--checkpoint", default="G3", help="G3 / G4：标题与说明文字；判定逻辑相同")
    ap.add_argument("--blank-ticks", default="", help="gate4：frameprobe --blank-ticks 用的拍段（只为写进报告）")
    ap.add_argument("--extra-note", action="append", default=[], help="附在运行说明后的一行（可多次）")
    a = ap.parse_args()
    cp = a.checkpoint
    waivers = {}
    for w in a.waive:
        if "=" not in w:
            sys.exit(f"--waive 形如 '指标名=理由'，收到 {w}")
        k, v = w.split("=", 1)
        if k.strip() in HARD:
            sys.exit(f"{k.strip()} 是硬性项（测试标准 §4），不能放行")
        waivers[k.strip()] = v.strip()
    out = a.out_dir

    env = read_kv(os.path.join(out, "environment.txt"))
    summary = load_json(os.path.join(out, "summary.json"), {}) or {}
    key = summary.get("key", {})
    per_input_stats = summary.get("perInput", {})
    summary_md = read_text(os.path.join(out, "summary.md"))
    probe = load_json(os.path.join(out, "probe-stats.json"), {}) or {}
    probe = probe.get("stats", probe)
    switches = load_json(os.path.join(out, "probe-switches.json"), {}) or {}
    switches = switches.get("switches", switches) if isinstance(switches.get("switches"), dict) else switches
    fade = load_json(os.path.join(out, "probe-fade.json"), {}) or {}
    fade = fade.get("fade", fade)
    def curve_of(name):
        # W1-A3 的 frameprobe wipe / zoom：找到带 passV7 / maxDeviationFrames 的那一层（不依赖外壳键名）
        def walk(x):
            if isinstance(x, dict):
                if "passV7" in x and "maxDeviationFrames" in x:
                    return x
                for v in x.values():
                    r = walk(v)
                    if r is not None:
                        return r
            elif isinstance(x, list):
                for v in x:
                    r = walk(v)
                    if r is not None:
                        return r
            return None
        return walk(load_json(os.path.join(out, name), {}) or {})
    wipe_curve = curve_of("probe-wipe.json")
    zoom_curve = curve_of("probe-zoom.json")
    av = load_json(os.path.join(out, "probe-av.json"), {}) or {}
    av = av.get("av", av)
    av_multi = load_json(os.path.join(out, "probe-av-multi.json"), {}) or {}
    frames_doc = load_json(os.path.join(out, "frames.json"), {}) or {}
    frames = frames_doc.get("frames", [])
    ffp = load_json(os.path.join(out, "ffprobe.json"), {}) or {}
    ffprobe_errors = read_text(os.path.join(out, "ffprobe-errors.txt")).strip()
    csum = load_json(os.path.join(out, "summary-c.json"), {}) or {}
    show = load_json(a.show, {}) or {}
    scenario = load_json(a.script, {}) or {}
    headless_log = read_text(os.path.join(out, "headless.log"))
    baseline = load_json(a.baseline, None) if a.baseline else None
    bsum = (baseline or {}).get("summary", {}) if baseline else {}

    fr = show.get("mixer", {}).get("format", {}).get("frameRate", {"numerator": 60, "denominator": 1})
    program_fps = fr["numerator"] / fr["denominator"]
    frame_ms = 1000 / program_fps
    rates = {}
    grays = {}
    input_lines = []
    for inp in show.get("inputs", []):
        syn = inp["source"].get("synthetic")
        if not syn:   # G4 起节目里有图片（Stinger PNG）/ NDI 输入：没有帧率 / 灰度，不参与 V4 的设计内核算
            kind = next(iter(inp["source"].keys()))
            input_lines.append(f"{inp['number']}. {inp['name']}（{kind}）")
            continue
        s = syn["settings"]
        r = s["frameRate"]["numerator"] / s["frameRate"]["denominator"] * (1 + s.get("clockDriftPpm", 0) / 1e6)
        pid = s.get("patternID")
        if pid is None:
            pid = (inp["number"] - 1) % 16
        rates[pid] = r
        rates[("number", inp["number"])] = r
        bg = s.get("background") or {}
        g = (bg.get("gray") or {}).get("level")
        noise = bg.get("noise") or {}
        if g is None and noise:
            g = noise.get("level")
        grays[inp["number"]] = g
        input_lines.append(f"{inp['number']}. {inp['name']}（ID {pid}，{r:.4f} fps，灰 {g}" + (f" ± 噪声 {noise.get('amplitude')}" if noise else "") + "）")
    gray_a = grays.get(1, 64)
    gray_b = grays.get(2, 192)

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

    # ---- V4（同 G2）----
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
    # 每路在播段数：同一路每次回到 PGM，它与节目拍点的相位都重新起算，+1 帧相位余量按段各给一次（G4 起；G3 的场景每路只在播几段、余量 1 帧够用没暴露）
    segments = {}
    last_id = None
    for fobj in frames:
        fid = fobj.get("inputID")
        if fid is None:
            continue
        if fid != last_id:
            segments[fid] = segments.get(fid, 0) + 1
        last_id = fid
    probe_rows = []
    probe_design_out_total = 0
    probe_backward = 0
    for s in probe.get("inputs", []):
        pid = s.get("inputID")
        K = s.get("frames", 0)
        r = s.get("inputFps") or rates.get(pid)
        dup, drop = s.get("duplicateFrames", 0), s.get("droppedFrames", 0)
        seg = max(1, segments.get(pid, 1))
        exp_dup = K * max(0.0, 1 - r / program_fps) if r else None
        exp_drop = K * max(0.0, r / program_fps - 1) if r else None
        out_dup = max(0, dup - math.ceil(exp_dup) - seg) if exp_dup is not None else 0
        out_drop = max(0, drop - math.ceil(exp_drop) - seg) if exp_drop is not None else 0
        probe_design_out_total += out_dup + out_drop
        probe_backward += s.get("backwardJumps", 0)
        probe_rows.append(f"| {pid} | {K}（{seg} 段） | {fmt(r, 4)} | {dup}（{s.get('duplicateRatio', 0) * 100:.2f}%） | {fmt(exp_dup, 1)} | {drop} | {fmt(exp_drop, 1)} | "
                          f"{out_dup + out_drop} | {s.get('backwardJumps', 0)} | {mark(s.get('passV4'))} |")

    # ---- V5 ----
    total_frames = probe.get("totalFrames")
    expected_run = round(a.minutes * 60 * program_fps)
    v5_delta = (total_frames - expected_run) if total_frames is not None else None
    undecodable = probe.get("undecodableFrames", 0)
    unidentified = probe.get("unidentifiedFrames", 0)

    # ---- V6：第 1000 拍的 Cut ----
    sw_list = switches.get("switches", [])
    cut_1000 = None
    for sw in sw_list:
        pts_tick = int(round(sw.get("ptsSeconds", -1) * program_fps)) if sw.get("ptsSeconds") is not None else None
        if sw.get("kind") == "cut" and (sw.get("tick") == 1000 or pts_tick == 1000):
            cut_1000 = sw
            break
    near_1000 = [sw for sw in sw_list if sw.get("kind") in ("cut", "transition") and 990 <= sw.get("tick", -1) <= 1010]
    cuts = [sw for sw in sw_list if sw.get("kind") == "cut"]
    unclean = [sw for sw in cuts if not sw.get("cleanCut")]
    v6_ok = cut_1000 is not None and cut_1000.get("cleanCut") is True and cut_1000.get("tick") == 1000 \
        and int(round(cut_1000.get("ptsSeconds", 0) * program_fps)) == 1000 and not unclean
    if cut_1000:
        v6_value = (f"第 1000 拍 Cut：新 ID {cut_1000.get('to')}（从 {cut_1000.get('from')}）首次出现在文件第 {cut_1000.get('index')} 帧 / pts {cut_1000.get('ptsSeconds'):.4f} s"
                    f"（= 第 {int(round(cut_1000.get('ptsSeconds', 0) * program_fps))} 拍），前 / 中 / 后帧混合 {cut_1000.get('mixedBefore')} / {cut_1000.get('mixedAt')} / {cut_1000.get('mixedAfter')}；"
                    f"全程 {len(cuts)} 次 Cut，不干净 {len(unclean)} 次")
    else:
        v6_value = f"第 1000 拍附近没有找到 Cut（990–1010 拍内的切换：{[(s.get('tick'), s.get('kind')) for s in near_1000]}）；全程 {len(cuts)} 次 Cut，不干净 {len(unclean)} 次"
    if unclean:
        v6_value += "；不干净的：" + "; ".join(f"拍 {s.get('tick')} {s.get('from')}→{s.get('to')}" for s in unclean[:8])

    # ---- V7：Fade 曲线 + T-bar 映射 ----
    fades = fade.get("fades", [])
    f0 = fades[0] if fades else None
    v7_curve_ok = bool(f0) and f0.get("passV7") is True and f0.get("monotonic") is True and f0.get("startTick") == 3001
    v7_curve_value = (f"Fade 30 拍 @ 3000：混合帧 {f0.get('mixedFrames')}（第 {f0.get('startTick')}–{f0.get('startTick', 0) + f0.get('mixedFrames', 0) - 1} 拍，{f0.get('direction')}），"
                      f"最大偏差 {f0.get('maxDeviationFrames', 0):.3f} 帧（进度误差 {f0.get('maxProgressError', 0) * 100:.2f}%），单调 {f0.get('monotonic')}") if f0 else "frameprobe fade 没有结果"
    tbar_windows = [(3600, 0.25), (3660, 0.5), (3720, 0.75)]
    tbar_rows = []
    tbar_worst = None
    frames_by_index = {f.get("index"): f for f in frames}
    span = gray_b - gray_a
    for start, p in tbar_windows:
        vals = []
        for i in range(start + 10, start + 56):
            f = frames_by_index.get(i)
            if f is not None and f.get("gray") is not None:
                vals.append((f["gray"] - gray_a) / span)
        if vals:
            mean = sum(vals) / len(vals)
            err = abs(mean - p)
            spread = max(vals) - min(vals)
            tbar_worst = err if tbar_worst is None else max(tbar_worst, err)
            tbar_rows.append(f"{p:.2f} → {mean:.4f}（{len(vals)} 帧，窗内极差 {spread:.4f}，误差 {err * 100:.2f}%）")
        else:
            tbar_rows.append(f"{p:.2f} → 没有帧")
    v7_tbar_ok = tbar_worst is not None and len(tbar_rows) == 3 and tbar_worst <= 0.02
    # G4 起：Wipe / Zoom 的进度曲线（W1-A3 的 frameprobe wipe / zoom），与 Fade 同口径 ≤ 1 帧；G4 场景里两种各取第一次
    wz_rows = []
    wz_ok = True
    for wz_label, c in (("Wipe", wipe_curve), ("Zoom", zoom_curve)):
        if c:
            ok = c.get("passV7") is True and c.get("monotonic") is True
            wz_ok = wz_ok and ok
            wz_rows.append(f"{wz_label} @ {c.get('startTick')}（{c.get('durationTicks')} 拍{'，' + str(c.get('direction')) if c.get('direction') else ''}）："
                           f"最大偏差 {c.get('maxDeviationFrames', 0):.3f} 帧（{len(c.get('samples', []))} 个样本），单调 {c.get('monotonic')}")
        elif cp == "G4":
            wz_ok = False
            wz_rows.append(f"{wz_label}：没有 probe-{wz_label.lower()}.json（frameprobe {wz_label.lower()} 没跑）")
    if wz_rows:
        v7_curve_value += "；" + "；".join(wz_rows)
    v7_ok = v7_curve_ok and v7_tbar_ok and wz_ok

    # ---- A1 / A2 / A3 / A4 ----
    a1 = (key.get("audio_dropouts") or 0) + (key.get("audio_underruns") or 0)
    disc = None
    for line in headless_log.splitlines():
        if "不连续" in line and "音频：" in line:
            try:
                disc = int(line.split("不连续")[1].split("，")[0].strip())
            except Exception:
                pass
    exact = [q["offsetMs"] for q in av.get("pairs", []) if q.get("offsetMs") is not None and abs(q.get("flashTimeSeconds", 0.5) - round(q.get("flashTimeSeconds", 0.5))) < 1e-6]
    exact_t = [q["flashTimeSeconds"] for q in av.get("pairs", []) if q.get("offsetMs") is not None and abs(q.get("flashTimeSeconds", 0.5) - round(q.get("flashTimeSeconds", 0.5))) < 1e-6]
    if exact:
        a2_mean = sum(exact) / len(exact)
        a2_max = max(abs(v) for v in exact)
        a2_std = (sum((v - a2_mean) ** 2 for v in exact) / len(exact)) ** 0.5
        n = len(exact)
        mx = sum(exact_t) / n
        my = a2_mean
        sxx = sum((x - mx) ** 2 for x in exact_t)
        a3_slope = sum((x - mx) * (y - my) for x, y in zip(exact_t, exact)) / sxx if sxx > 0 else 0.0
    else:
        a2_mean = a2_max = a2_std = a3_slope = None
    a2_ok = a2_max is not None and a2_max <= frame_ms
    a3_8h = a3_slope * 8 * 3600 if a3_slope is not None else None
    a3_ok = a3_8h is not None and abs(a3_8h) <= 16
    multi = av_multi.get("multi", {}) if av_multi else {}
    a4_max = multi.get("maxClickSpreadMs")
    a4_ok = a4_max is not None and a4_max <= frame_ms
    a4_value = (f"{len(av_multi.get('sources', []))} 个文件（PGM + ISO 音轨），{len(multi.get('events', []))} 个事件：click 时刻极差最大 {fmt(a4_max)} ms，"
                f"闪光极差最大 {fmt(multi.get('maxFlashSpreadMs'))} ms") if av_multi else "没有 ISO 文件（--iso-audio 0）"

    # ---- E1 / E2 / E3 / E5 ----
    e1 = key.get("e1_skipped")
    rec_settings = next((o.get("settings", {}) for o in show.get("outputs", []) if o.get("kind") == "record"), {})
    target_bps = (rec_settings.get("video") or {}).get("bitrateBps", 6_000_000)
    target_gop = (rec_settings.get("video") or {}).get("keyframeIntervalFrames", 120)
    packets = []
    for line in read_text(os.path.join(out, "packets-v.csv")).splitlines():
        parts = line.split(",")
        if len(parts) >= 3:
            try:
                packets.append((float(parts[0]), int(parts[1]), parts[2]))
            except ValueError:
                continue
    packets.sort()
    e2_win_err = e2_peak = None
    e3_max_dev = None
    e3_intervals = []
    if packets:
        t_end = packets[-1][0]
        # 10 s 滑窗（步进 1 s）平均码率、1 s 窗峰值
        import bisect
        times = [p[0] for p in packets]
        sizes = [p[1] for p in packets]
        prefix = [0]
        for s_ in sizes:
            prefix.append(prefix[-1] + s_)
        def window_bits(t0_, t1_):
            i = bisect.bisect_left(times, t0_)
            j = bisect.bisect_left(times, t1_)
            return (prefix[j] - prefix[i]) * 8
        win_errs = []
        t = 0.0
        while t + 10 <= t_end:
            win_errs.append(abs(window_bits(t, t + 10) / 10 / target_bps - 1))
            t += 1
        peaks = []
        t = 0.0
        while t + 1 <= t_end:
            peaks.append(window_bits(t, t + 1) / target_bps)
            t += 1
        e2_win_err = max(win_errs) if win_errs else None
        e2_peak = max(peaks) if peaks else None
        key_idx = [i for i, p in enumerate(packets) if "K" in p[2]]
        e3_intervals = [b - a_ for a_, b in zip(key_idx, key_idx[1:])]
        e3_max_dev = max(abs(x - target_gop) for x in e3_intervals) if e3_intervals else None
    # E2 直接判（G4 起）：G3 场景的合成源底纹已换成灰底 + 噪声（提案 006 / W1-A2，prompt 60 末节第 2 条），编码器有东西可压。
    # G3 时灰底压不出设定码率（6 Mbps 设定、实际 0.1 Mbps），当时判"本场景不适用"；现在平均码率远低于设定就是真的不过。
    avg_bps = (prefix[-1] * 8 / t_end) if packets and t_end > 0 else None
    e2_ok = e2_win_err is not None and e2_win_err <= 0.10 and e2_peak is not None and e2_peak <= 1.5
    e3_ok = e3_max_dev is not None and e3_max_dev <= 1
    vstream = next((s for s in ffp.get("streams", []) if s.get("codec_type") == "video"), {})
    astream = next((s for s in ffp.get("streams", []) if s.get("codec_type") == "audio"), {})
    v_dur = float(vstream.get("duration") or 0) if vstream else None
    a_dur = float(astream.get("duration") or 0) if astream else None
    e5_dur_err_frames = (v_dur - expected_run / program_fps) * program_fps if v_dur else None
    e5_av_diff_ms = (a_dur - v_dur) * 1000 if (v_dur and a_dur) else None
    e5_ok = (not ffprobe_errors) and e5_dur_err_frames is not None and abs(e5_dur_err_frames) <= 1 and e5_av_diff_ms is not None and abs(e5_av_diff_ms) <= 20

    # ---- C1–C4 ----
    c1 = csum.get("c1") or {}
    c2 = csum.get("c2") or {}
    c3 = csum.get("c3") or {}
    c4 = csum.get("c4") or {}
    c1_ok = bool(c1) and c1.get("measured") == c1.get("count") and c1.get("pass") == c1.get("count")
    c2_ok = bool(c2) and c2.get("fromTick_p99_ms") is not None and c2["fromTick_p99_ms"] <= 50 and (c2.get("transport_p99_ms") or 0) <= 50
    c3_ok = bool(c3) and c3.get("strictMismatches") == 0
    c4_ok = bool(c4) and not c4.get("problems") and c4.get("receipts") == c4.get("expected")

    # ---- missed_render 时刻 + 负载（同 G2）----
    miss_events = []
    gpu_busy_seconds = 0
    gpu_max = 0.0
    try:
        prev = None
        for line in open(os.path.join(out, "stats.jsonl"), encoding="utf-8"):
            if not line.strip():
                continue
            row = json.loads(line)
            gpu_max = max(gpu_max, row.get("gpu_pct", 0))
            if row.get("gpu_pct", 0) > 50:
                gpu_busy_seconds += 1
            m = row.get("missed_render", 0)
            if prev is not None and m > prev:
                miss_events.append((row["ts"], row["tick"], m - prev, row.get("render_ms", 0), row.get("gpu_pct", 0), row.get("cpu_pct", 0)))
            prev = m
    except Exception:
        pass
    load_samples = [l for l in read_text(os.path.join(out, "load.log")).splitlines() if l.strip()]
    miss_note = "；".join(f"{datetime.datetime.fromtimestamp(ts).strftime('%H:%M:%S')} 拍 {tick} +{k}（render {r:.2f} ms，GPU {g:.0f}%，CPU {c:.0f}%）"
                         for ts, tick, k, r, g, c in miss_events[:12])
    if len(miss_events) > 12:
        miss_note += f"；…共 {len(miss_events)} 次增量"

    # ---- 判定表 ----
    checks = [
        ("V1 渲染耗时（本机参考线）", f"avg {fmt(v1_avg)} ms / p99 {fmt(v1_p99)} ms" + ("（G2 按 M0 灰底负载定的 2 ms 线；G4 负载多了 4 路抠像叠加 + 自定义多画面 + 噪声底纹，只作参考，新基线 g4-m5max.json 供 W4-A 判退步）" if cp == "G4" else ""),
         "avg ≤ 2 ms（M5 Max，G2 起的本机线）", ("info" if cp == "G4" else (v1_avg is not None and v1_avg <= 2.0)), delta(v1_avg, b_v1_avg, "ms")),
        ("V1 渲染耗时（必须档）", f"avg {fmt(v1_avg)} / p99 {fmt(v1_p99)} ms", "avg ≤ 6，p99 ≤ 12（目标 ≤ 4 / ≤ 8）", v1_avg is not None and v1_avg <= 6 and v1_p99 <= 12, delta(v1_p99, b_v1_p99, "ms（p99）")),
        ("V2 渲染滞后丢帧", f"{int(v2) if v2 is not None else '—'} 帧 / {int(T)} 拍（{(v2 or 0) / T * 100 if T else 0:.4f}%）" + (f"；增量时刻：{miss_note}" if miss_note else ""),
         "10 分钟内 0" if a.minutes <= 10 else "≤ 0.02%（§4 必须档）；目标 0",
         (v2 is not None and v2 == 0) if a.minutes <= 10 else (v2 is not None and T and v2 / T <= 0.0002), "—"),
        ("V3 输出抖动", f"p99 {fmt(v3_p99)} ms / max {fmt(v3_max)} ms（jitter_ms 是每秒窗口最大值，p99 取各秒最大值）", "p99 ≤ 4 ms（目标 ≤ 2）", v3_p99 is not None and v3_p99 <= 4.0, delta(v3_p99, b_v3_p99, "ms")),
        ("V4 设计外重复 / 丢弃", f"精确核算设计外 {v4_design_out_total} 帧（stats.jsonl 全程）/ {probe_design_out_total} 帧（frameprobe 在播段）；StatsSummary 平均帧率口径最大设计外 {v4_worst_excess * 100:.4f}%；帧号倒退 {probe_backward}",
         "设计外 0（精确核算）；≤ 0.05%（§4 必须档）", v4_design_out_total == 0 and probe_design_out_total == 0 and probe_backward == 0 and v4_worst_excess <= 0.0005, "—"),
        ("V5 帧计数一致性", f"文件 {total_frames} 帧 − 运行 {expected_run} 拍 = {v5_delta:+d} 帧" if v5_delta is not None else "—", "|Δ| ≤ 2 帧", v5_delta is not None and abs(v5_delta) <= 2, "—"),
        ("V6 切换准确性", v6_value, "Cut 恰在第 1000 拍、前后无混合帧；所有 Cut 干净（硬性）", v6_ok, "—"),
        ("V7 转场进度精度", v7_curve_value + "；T-bar " + "；".join(tbar_rows) + (f"；最大映射误差 {tbar_worst * 100:.2f}%" if tbar_worst is not None else ""),
         ("曲线误差 ≤ 1 帧（Fade / Wipe / Zoom）；T-bar 映射误差 ≤ 2%（目标 ≤ 1%）" if cp == "G4" else "曲线误差 ≤ 1 帧；T-bar 映射误差 ≤ 2%（目标 ≤ 1%）"), v7_ok, "—"),
        ("A1 音频断裂", f"超时 + 欠载 = {int(a1)}；泵线程流式不连续检测 {disc if disc is not None else '—'}（信息项，见口径说明）", "0（硬性）", a1 == 0, "—"),
        ("A2 A/V 偏移", (f"整秒闪光 {len(exact)} 对：均值 {a2_mean:+.3f} ms，标准差 {a2_std:.3f}，最大 {a2_max:.3f} ms；全部配对 {av.get('matchedCount')} 对均值 {fmt(av.get('meanMs'))} ms（含 59.94 在播段的假象）" if exact else "没有可配对的闪光 / click"),
         "整秒配对最大绝对值 ≤ 16.7 ms（目标 ≤ 5；音频超前为正）", a2_ok, "—"),
        ("A3 A/V 漂移", f"整秒闪光序列斜率 {fmt(a3_slope, 5)} ms/s × 8 h = {fmt(a3_8h, 2)} ms（{a.minutes:g} 分钟外推）" if a3_slope is not None else "—", "× 8 h ≤ 16 ms（目标 ≤ 5；8 小时实跑归 W4-A）", a3_ok, "—"),
        ("A4 多文件对齐", a4_value, "≤ 1 帧（目标 ≤ 1 ms）", a4_ok, "—"),
        ("E1 编码滞后跳帧", f"{int(e1) if e1 is not None else '—'}（stats.jsonl encoder[] 全部条目的 skipped 之和：PGM 录制器 + ISO 录制器）", "标准负载下 0", None if e1 is None else e1 == 0, "—"),
        ("E2 码率遵从", f"设定 {target_bps / 1e6:.1f} Mbps：整段平均 {fmt(avg_bps / 1e6 if avg_bps else None, 3)} Mbps，10 s 滑窗最大误差 {fmt(e2_win_err * 100 if e2_win_err is not None else None, 2)}%，1 s 峰值 {fmt(e2_peak, 3)}×（{len(packets)} 个视频包）",
         "误差 ≤ 10%，峰值 ≤ 1.5×（目标 5% / 1.2×）", e2_ok, "—"),
        ("E3 关键帧间隔", f"设定 {target_gop}：{len(e3_intervals)} 个间隔，最大偏差 {e3_max_dev if e3_max_dev is not None else '—'} 帧" + (f"（min {min(e3_intervals)} / max {max(e3_intervals)}）" if e3_intervals else ""), "≤ ±1 帧（目标精确）", e3_ok, "—"),
        ("E5 文件完整性", f"ffprobe 错误 {'无' if not ffprobe_errors else ffprobe_errors[:120]}；视频时长 {fmt(v_dur)} s（与 {expected_run} 拍差 {fmt(e5_dur_err_frames, 2)} 帧）；音轨 {fmt(a_dur)} s，音视频差 {fmt(e5_av_diff_ms, 1)} ms",
         "无错；时长差 ≤ 1 帧；音视频差 ≤ 20 ms（W1-E2 起录制器自己截两轨，G4 起判）", e5_ok, "—"),
        ("C1 命令延迟", f"{c1.get('count', 0)} 次：画面里找到 {c1.get('measured', 0)}，通过 {c1.get('pass', 0)}；min {fmt(c1.get('min_ms'), 2)} / mean {fmt(c1.get('mean_ms'), 2)} / max {fmt(c1.get('max_ms'), 2)} ms，RTT p50 {fmt(c1.get('rtt_p50_ms'))} ms" if c1 else "没跑 C 系列",
         "≤ 1 拍 + 该次 RTT", c1_ok if c1 else None, "—"),
        ("C2 状态推送延迟", f"{c2.get('count', 0)} 条快照：相对拍点 p99 {fmt(c2.get('fromTick_p99_ms'), 2)} ms（p50 {fmt(c2.get('fromTick_p50_ms'), 2)}）；发布→客户端 p99 {fmt(c2.get('fromPublish_p99_ms'))} ms；纯传输 p99 {fmt(c2.get('transport_p99_ms'))} ms" if c2 else "没跑 C 系列",
         "p99 ≤ 50 ms（目标 ≤ 20）", c2_ok if c2 else None, "—"),
        ("C3 状态一致性", f"比对 {c3.get('framesCompared', 0)} 帧（解不出 ID 的 {c3.get('undecodable', 0)} 帧跳过）：不一致 {c3.get('strictMismatches', 0)}，可用邻拍解释的 {c3.get('boundaryMismatches', 0)}" if c3 else "没跑 C 系列",
         "0 不一致（硬性）", c3_ok if c3 else None, "—"),
        ("C4 并发正确性", f"{c4.get('clients', 0)} 客户端回执 {c4.get('receipts', 0)}/{c4.get('expected', 0)}，空洞 {c4.get('holes', 0)}，WS 倒退 {c4.get('wsReorders', 0)}，RTT p99 {fmt(c4.get('rtt_p99_ms'))} ms" + (f"；问题：{'; '.join(c4.get('problems', []))}" if c4.get('problems') else "") if c4 else "没跑 C 系列",
         "0 丢失 0 乱序（硬性）", c4_ok if c4 else None, "—"),
    ]
    unknown = [k for k in waivers if k not in {c[0] for c in checks}]
    if unknown:
        sys.exit(f"--waive 里的指标名不在判定表里：{unknown}；可用：{[c[0] for c in checks]}")
    waived = [c[0] for c in checks if c[3] is False and c[0] in waivers]
    # "info" 行只作参考不进总判定（G4 的 V1 本机线）；None（没跑 / 没数据）仍算不过
    all_pass = all((c[3] is True) or (c[3] == "info") or (c[0] in waivers) for c in checks)

    # ---- 信息项 ----
    cpu, gpu = key.get("cpu_avg_pct"), key.get("gpu_avg_pct")
    rss_min, rss_max, rss_slope = key.get("rss_min_mb"), key.get("rss_max_mb"), key.get("rss_slope_mb_per_h")
    kinds = {}
    for sw in sw_list:
        kinds[sw.get("kind", "?")] = kinds.get(sw.get("kind", "?"), 0) + 1
    ff_dur = (ffp.get("format") or {}).get("duration")
    tail = "\n".join(headless_log.strip().splitlines()[-24:])

    lines = []
    lines.append(f"## 运行 {a.label}：{a.minutes:g} 分钟 {cp} 场景")
    lines.append("")
    lines.append(f"- 日期：{env.get('date', '?')}；提交：`{env.get('commit', '?')}`（{env.get('branch', '?')}，未提交改动 {env.get('dirty', '?')} 个文件）")
    lines.append(f"- 机器：{env.get('cpu', '?')}，{env.get('cores', '?')} 核，{env.get('memory_gb', '?')} GB；macOS {env.get('macos', '?')}；{env.get('xcode', '?')}")
    lines.append(f"- 电源：{env.get('power', '?')}；温度 / 降频：{env.get('thermal', '无记录')}")
    lines.append(f"- 负载：跑前 {env.get('load_before', '?')} → 跑后 {env.get('load_after', '?')}；跑前占 CPU 的进程：{env.get('top_processes_before', '?')}")
    lines.append(f"- 运行期间：GPU 占用 > 50% 的秒数 {gpu_busy_seconds}（最高 {gpu_max:.0f}%）；负载采样 {'有（' + str(len(load_samples)) + ' 条，5 s 一次，load.log）' if load_samples else '无'}")
    event_kinds = {}
    for e in scenario.get("events", []):
        k = next(iter(e.get("command", {"?": None}).keys()))
        if k == "setTransition":
            k = "setTransition:" + str(e["command"]["setTransition"].get("type"))
        event_kinds[k] = event_kinds.get(k, 0) + 1
    kinds_text = "、".join(f"{k} {v}" for k, v in sorted(event_kinds.items()))
    if cp == "G4":
        scenario_text = ("前 2 分钟同 G3（第 1000 拍 Cut、第 3000 拍 Fade 30、3600/3660/3720 拍 T-bar 25/50/75%），120 s 起每 5 s 按 Cut / Fade / Wipe / Zoom / Stinger 轮流"
                         "（非 Cut 24 拍），122.5 s 起每 15 s 翻一路叠加（1–4 循环）")
    else:
        scenario_text = "第 1000 拍 Cut、第 3000 拍 Fade 30、3600/3660/3720 拍 T-bar 25/50/75%、120 s 起每 5 s Cut、122.5 s 起每 30 s 开关 Overlay 1"
    lines.append(f"- 场景：`{a.script}`（{scenario.get('durationTicks', '?')} 拍，{len(scenario.get('events', []))} 个事件：{kinds_text}；{scenario_text}）；节目：`{a.show}`（{show.get('mixer', {}).get('format', {}).get('width', '?')}×{show.get('mixer', {}).get('format', {}).get('height', '?')}@{program_fps:g}）")
    lines.append("  - 输入：" + "；".join(input_lines))
    if cp == "G4":
        keyed = [i["number"] for i in show.get("inputs", []) if (i.get("settings") or {}).get("keyer", {}).get("enabled")]
        ovl = [(o.get("input"), (o.get("animation") or {}).get("kind"), (o.get("animation") or {}).get("durationTicks")) for o in show.get("mixer", {}).get("overlays", [])]
        mv = next((o for o in show.get("outputs", []) if o.get("kind") == "multiview"), None)
        lines.append(f"  - 新负载：抠像开在输入 {keyed}；Overlay 1–4 = {ovl}；多画面输出 {'自定义布局（cells ' + str(len(((mv or {}).get('settings') or {}).get('extra', {}).get('layout', {}).get('cells', []))) + '，safeArea / meters）' if mv else '无'}；"
                     f"Wipe {show.get('mixer', {}).get('transition', {}).get('wipe')}，Stinger {show.get('mixer', {}).get('transition', {}).get('stinger')}（{next((i['name'] for i in show.get('inputs', []) if 'image' in i['source']), '无图片输入')}）")
        blank_count = 0
        if not a.blank_ticks:
            lines.append("  - frameprobe 自证解码（W1-A3）默认开：转场合成帧由帧内五条证据（两行 CRC + ID 距离、码字块纯度、ID 块四象限、底色一致、节奏）判成解不出，"
                         "不再用 `--blank-ticks`（gate4.sh --legacy-blank-ticks 可回到 G4 第一版从场景文件标拍段的口径；两种口径下 V4 / V5 / V6 的结论一致，W1-A3 报告 §2.2）")
        if a.blank_ticks:
            for part in a.blank_ticks.split(","):
                lo, hi = part.split("-")
                blank_count += int(hi) - int(lo) + 1
        lines.append(f"  - frameprobe 的 `--blank-ticks`：非 Cut 转场的中间拍 [t + 1, t + d]，共 {a.blank_ticks.count('-')} 段 {blank_count} 拍当作解不出（转场合成帧没有单一输入身份；"
                     f"V4 的引擎侧 stats.jsonl 计数全程照算，V5 总帧数不受影响；第 t 拍 = 纯旧画面 + 整秒闪光帧保留）")
    for n in a.extra_note:
        lines.append(f"- {n}")
    api_extra = " --c1-phase 0.7" if cp == "G4" else ""
    lines.append(f"- 命令：`switcher-headless run --show {a.show} --script {a.script} --duration {int(a.minutes * 60)} --stats {out}/stats.jsonl --record {out}/out.mov --iso-audio 4 --audio-device null --api`；客户端 `scripts/apitest/apitest.py run --c1-start 150{api_extra} …`")
    lines.append("")
    lines.append(f"### {cp} 判定（落地方案 §4 {cp} + {cp} prompt 第 2 条；阈值按测试标准 §4）")
    lines.append("")
    lines.append("| 指标 | 数值 | 阈值 | 通过 | 与上一版本的差 |")
    lines.append("|---|---|---|---|---|")
    for name, value, thr, ok, d in checks:
        m = mark(ok)
        if ok is False and name in waivers:
            m = f"⚠️ 放行（{waivers[name]}）"
        lines.append(f"| {name} | {value} | {thr} | {m} | {d} |")
    verdict = "✅ 通过" + (f"（含放行 {len(waived)} 项）" if waived else "") if all_pass else "❌ 未通过"
    net_note = "E7–E9 见 reports/G3-net.md（scripts/gate3-net.sh，需要 sudo 起 netem 代理）" if cp == "G3" else "E7–E9 沿用 G3（reports/G3-net.md；W3 五路没动推流），NDI 回环 L1 见 reports/G4-ndi.md，编译矩阵见 reports/G4-matrix.md"
    lines.append(f"| **总判定（自动项）** | {net_note} | | **{verdict}** | 基线：{a.baseline or '无（本次即基线）'} |")
    lines.append("")
    lines.append("### 其它指标（信息；阈值按测试标准 §4）")
    lines.append("")
    lines.append("| 指标 | 数值 | 阈值 | 通过 | 与上一版本的差 |")
    lines.append("|---|---|---|---|---|")
    lines.append(f"| S2 内存增长 | {fmt(rss_slope, 2)} MB/h（RSS {fmt(rss_min, 0)} → {fmt(rss_max, 0)} MB；{'已丢前 30 min' if a.minutes >= 60 else '不足 1 h，整段拟合仅供参考'}） | ≤ 10 MB/h | {mark(None if rss_slope is None else rss_slope <= 10)} | {delta(rss_max, b_rss, 'MB（RSS max）', 1)} |")
    lines.append(f"| S3 占用 | CPU avg {fmt(cpu, 1)}%（100 = 一核）/ GPU avg {fmt(gpu, 1)}%（IOKit Device Utilization） | CPU ≤ 60%，GPU ≤ 50% | {mark(None if cpu is None else cpu <= 60 and (gpu or 0) <= 50)} | CPU {delta(cpu, b_cpu, '%', 1)}；GPU {delta(gpu, b_gpu, '%', 1)} |")
    lines.append(f"| 切换汇总 | {len(sw_list)} 次（{', '.join(f'{k} {v}' for k, v in sorted(kinds.items())) or '无'}），所有 Cut 干净：{mark(switches.get('allCutsClean'))} | — | — | — |")
    lines.append(f"| 文件 | {total_frames} 帧（读不出帧号 {undecodable}，读不出 ID {unidentified}），ffprobe 时长 {ff_dur or '?'} s，{vstream.get('codec_name', '?')} {vstream.get('width', '?')}×{vstream.get('height', '?')} {vstream.get('avg_frame_rate', '?')}，音轨 {astream.get('codec_name', '无')} | — | — | — |")
    lines.append("")
    lines.append("### V4 明细一：stats.jsonl 帧槽计数（全程、每路都在）")
    lines.append("")
    lines.append("| 输入 | 真实帧率 | 实测 fps avg | dup 累计 | 设计内 dup 期望 | drop 累计 | 设计内 drop 期望 | 设计外（精确核算） | StatsSummary 设计外 dup / drop |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    lines.extend(v4_rows)
    lines.append("")
    lines.append(f"设计内期望 = T × |1 − r/P|，T = {int(T)} 拍；设计外 = max(0, 实测 − ceil(期望) − 1)（1 帧相位余量）。")
    lines.append("")
    lines.append("### V4 明细二：frameprobe 读录制文件（只有在播的那路；设计外 = max(0, 实测 − ceil(期望) − 在播段数)，每个连续在播段 1 帧相位余量）")
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
    for name in ["stats.jsonl", "out.mov", "headless.log", "apitest.log", "environment.txt", "load.log", "summary.md", "summary.json", "probe-stats.json", "probe-stats.md",
                 "probe-switches.json", "probe-switches.md", "probe-fade.json", "probe-fade.md", "probe-wipe.json", "probe-wipe.md", "probe-zoom.json", "probe-zoom.md",
                 "frames.json", "probe-av.json", "probe-av.md",
                 "probe-av-multi.json", "probe-av-multi.md", "ffprobe.json", "packets-v.csv", "session.json", "report-c.md", "summary-c.json"]:
        p = os.path.join(out, name)
        if os.path.exists(p):
            lines.append(f"- `{os.path.abspath(p)}`（{os.path.getsize(p) / 1024:.0f} KB）")
    for p in sorted(glob.glob(os.path.join(out, "out.iso*.mov"))):
        lines.append(f"- `{os.path.abspath(p)}`（{os.path.getsize(p) / 1024:.0f} KB）")
    lines.append("")
    lines.append("### headless 收尾摘要（stdout 末尾）")
    lines.append("")
    lines.append("```")
    lines.append(tail)
    lines.append("```")
    lines.append("")
    for title, fname in [("frameprobe switches（V6）", "probe-switches.md"), ("frameprobe fade（V7）", "probe-fade.md"), ("frameprobe wipe（V7）", "probe-wipe.md"),
                         ("frameprobe zoom（V7）", "probe-zoom.md"), ("frameprobe av（A2 / A3）", "probe-av.md"),
                         ("frameprobe av 多文件（A4）", "probe-av-multi.md"), ("C 系列（scripts/apitest evaluate）", "report-c.md"), ("frameprobe stats 原表", "probe-stats.md")]:
        text = read_text(os.path.join(out, fname)).strip()
        if text:
            lines.append(f"<details><summary>{title}</summary>\n")
            lines.append(text)
            lines.append("\n</details>\n")

    os.makedirs(os.path.dirname(a.run_report) or ".", exist_ok=True)
    with open(a.run_report, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    rdir = os.path.dirname(a.run_report) or "."
    notes = read_text(a.notes, f"# {cp} 检查点报告\n\n（reports/{cp}-notes.md 还没写）\n")
    runs = sorted(glob.glob(os.path.join(rdir, f"{cp}-run-*.md")), key=lambda p: (0 if p.endswith(f"{cp}-run-10min.md") else 1, p))
    # G3：网络损伤那节；G4：NDI 回环 L1 + 编译矩阵两节（各自的脚本生成），E7–E9 沿用 G3
    extras = [read_text(os.path.join(rdir, f)).strip() for f in (["G3-net.md"] if cp == "G3" else ["G4-ndi.md", "G4-matrix.md"])]
    parts = [notes.rstrip() + "\n", f"\n---\n\n# 自动结果（scripts/gate{cp[1:]}.sh 生成，每次运行一节）\n",
             f"\n生成时间：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"]
    for r in runs:
        parts.append("\n" + read_text(r).rstrip() + "\n")
    for x in extras:
        if x:
            parts.append("\n" + x + "\n")
    with open(a.report, "w", encoding="utf-8") as f:
        f.write("".join(parts))
    print(f"{'通过' if all_pass else '未通过'}：{a.run_report} → {a.report}")
    return 0 if all_pass else 3


if __name__ == "__main__":
    sys.exit(main())
