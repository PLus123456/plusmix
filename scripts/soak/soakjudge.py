#!/usr/bin/env python3
"""W4-A 长稳判定库（make soak / soak-1h；测试标准 §1 S1 / S2 / A3、§3 S1 / S2 / A1 / A3、§4、§7）。

- S1：从第一行起每 5 分钟一个窗口（窗口 k = 第 k 个边界之前的最后一行 → 第 k + 1 个边界之前的最后一行，累计值相减；最后一段不足 5 分钟按它自己的拍数判），
  窗口内 V2（missed_render 增量 / 拍数 ≤ 0.02%）、A1（dropouts + underruns 增量 = 0，另加 frameprobe 离线不连续落在该窗口的次数，硬性）、
  E1（所有编码器 skipped 增量之和 = 0，"标准负载下 0"）都不超，且进程正常退出、跑满时长、没有崩溃报告，才算通过。
- 异常：逐行看累计值的增量（missed_render、音频超时 / 欠载、各编码器 skipped / dropped / 重连、状态切换）、stats 断档、V1 / V3 尖峰、输入停帧，
  每个事件取前后 5 分钟，重叠的并成一段（soak_report.py 按段截日志）。
- S2：每分钟取一个 rss_mb（phys_footprint）样本，丢掉前 30 分钟预热后线性拟合（MB/h）；拟合段不足 min_fit_s 只作参考（每晚 1 小时的那种）。
- A3：frameprobe av 的整秒配对（onSecond）斜率 × 时长；跑满 8 小时直接用 driftOverSpanMs，短跑按斜率外推到 8 小时（G3 / G4 的口径）。阈值 ≤ 16 ms（§4，按绝对值）。
"""
import math
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf"))
import perfjudge as pj  # noqa: E402  —— 百分位 / 线性拟合与 L5 同一份

V2_MUST_RATIO = 0.0002          # §4 V2 必须档
V3_MUST_MS = 4.0                # §4 V3 必须档（p99；单秒超过只报事件）
V1_MUST_P99_MS = 12.0           # §4 V1 必须档 p99（单秒超过只报事件）
S2_MUST_MB_H, S2_TARGET_MB_H = 10.0, 2.0
A3_MUST_MS, A3_TARGET_MS = 16.0, 5.0


def _enc(line):
    return line.get("encoder") or []


def _skipped(line):
    return sum(int(e.get("skipped", 0)) for e in _enc(line))


def _last_at_or_before(lines, ts, start_index=0):
    """lines 按 ts 升序：返回 ts ≤ 给定时刻的最后一行的下标（从 start_index 往后找）。"""
    i = start_index
    while i + 1 < len(lines) and float(lines[i + 1]["ts"]) <= ts:
        i += 1
    return i


def run_segment(lines):
    """运行段 = 从第一行到拍号第一次到达最终值的那一行（含）；之后的行是停机段（引擎已停、各路收尾），不进 S1 窗口。"""
    if not lines:
        return [], []
    final = max(int(l["tick"]) for l in lines)
    end = next(i for i, l in enumerate(lines) if int(l["tick"]) == final)
    return lines[:end + 1], lines[end + 1:]


def windows(lines, window_s=300):
    if len(lines) < 2:
        return []
    t0, tlast = float(lines[0]["ts"]), float(lines[-1]["ts"])
    k_count = max(1, int(math.ceil((tlast - t0) / window_s - 1e-9)))
    out = []
    a = 0
    for k in range(k_count):
        boundary = tlast if k == k_count - 1 else t0 + (k + 1) * window_s
        b = _last_at_or_before(lines, boundary, a)
        la, lb = lines[a], lines[b]
        inner = lines[a + 1:b + 1]
        enc_a, enc_b = _enc(la), _enc(lb)
        n_enc = max(len(enc_a), len(enc_b))
        def d(key, i):
            va = int(enc_a[i].get(key, 0)) if i < len(enc_a) else 0
            vb = int(enc_b[i].get(key, 0)) if i < len(enc_b) else 0
            return vb - va
        states = [sorted({(l.get("encoder") or [{}] * n_enc)[i].get("state", "?") for l in [la] + inner if i < len(l.get("encoder") or [])})
                  for i in range(n_enc)]
        w = {
            "index": k, "start_ts": float(la["ts"]), "end_ts": float(lb["ts"]),
            "start_tick": int(la["tick"]), "end_tick": int(lb["tick"]), "ticks": int(lb["tick"]) - int(la["tick"]), "lines": len(inner),
            "missed": int(lb["missed_render"]) - int(la["missed_render"]),
            "dropouts": int(lb["audio"]["dropouts"]) - int(la["audio"]["dropouts"]),
            "underruns": int(lb["audio"]["underruns"]) - int(la["audio"]["underruns"]),
            "discontinuities_stream": int(lb["audio"].get("discontinuities", 0)) - int(la["audio"].get("discontinuities", 0)),
            "skipped": _skipped(lb) - _skipped(la),
            "skipped_by_encoder": [d("skipped", i) for i in range(n_enc)],
            "dropped_by_encoder": [d("dropped", i) for i in range(n_enc)],
            "reconnects_by_encoder": [d("reconnects", i) for i in range(n_enc)],
            "frames_by_encoder": [d("frames", i) for i in range(n_enc)],
            "states_by_encoder": states,
            "outputs": [int(e.get("output", 0)) for e in enc_b],
            "jitter_max_ms": max((float(l["jitter_ms"]) for l in inner), default=0.0),
            "render_max_ms": max((float(l["render_ms"]) for l in inner), default=0.0),
            "rss_start_mb": float(la["rss_mb"]), "rss_end_mb": float(lb["rss_mb"]),
            "cpu_avg_pct": (sum(float(l["cpu_pct"]) for l in inner) / len(inner)) if inner else 0.0,
            "gpu_avg_pct": (sum(float(l["gpu_pct"]) for l in inner) / len(inner)) if inner else 0.0,
        }
        out.append(w)
        a = b
    return out


def attach_offline_discontinuities(ws, events, fps, start_tick=0):
    """frameprobe av --discontinuities 的事件（录像时间轴，秒）按拍号落到窗口：窗口 k 管 (start_tick, end_tick]。"""
    for w in ws:
        w["offline_discontinuities"] = 0
    for e in events or []:
        tick = start_tick + int(round(float(e["timeSeconds"]) * fps))
        for w in ws:
            if w["start_tick"] < tick <= w["end_tick"] or (w["index"] == 0 and tick == w["start_tick"]):
                w["offline_discontinuities"] += 1
                break


def judge_window(w):
    r = dict(w)
    ticks = max(1, int(w.get("ticks", 0)))
    r["v2_ratio"] = int(w.get("missed", 0)) / ticks
    r["v2_ok"] = r["v2_ratio"] <= V2_MUST_RATIO
    r["a1"] = int(w.get("dropouts", 0)) + int(w.get("underruns", 0)) + int(w.get("offline_discontinuities", 0))
    r["a1_ok"] = r["a1"] == 0
    r["e1_ok"] = int(w.get("skipped", 0)) == 0
    r["ok"] = r["v2_ok"] and r["a1_ok"] and r["e1_ok"]
    return r


def s1_verdict(judged, exit_code, expected_s, covered_s, crash_reports, tolerance_s=5.0):
    reasons = []
    bad = [w for w in judged if not w["ok"]]
    if bad:
        reasons.append(f"{len(bad)} 个窗口超阈值")
    if exit_code != 0:
        reasons.append(f"headless 退出码 {exit_code}")
    if covered_s + tolerance_s < expected_s:
        reasons.append(f"只覆盖了 {covered_s:.0f} / {expected_s:.0f} s")
    if crash_reports:
        reasons.append(f"崩溃报告 {len(crash_reports)} 份")
    return {"pass": not reasons, "reasons": reasons, "bad_windows": [w["index"] for w in bad]}


# ---------------------------------------------------------------- 异常事件

def events(lines, gap_s=2.5, settle_s=20.0, stall_s=5.0):
    out = []
    if not lines:
        return out
    t0, tlast = float(lines[0]["ts"]), float(lines[-1]["ts"])
    def add(ts, kind, detail):
        out.append({"ts": float(ts), "kind": kind, "detail": detail})
    stall_start = {}
    seen_active = set()
    tick_stall_from = None
    for prev, cur in zip(lines, lines[1:]):
        ts = float(cur["ts"])
        if ts - float(prev["ts"]) > gap_s:
            add(ts, "stats_gap", f"stats 断了 {ts - float(prev['ts']):.1f} s（{float(prev['ts']) - t0:.0f} s → {ts - t0:.0f} s）")
        if int(cur["tick"]) == int(prev["tick"]):
            if tick_stall_from is None:
                tick_stall_from = float(prev["ts"])
        elif tick_stall_from is not None:
            if float(prev["ts"]) - tick_stall_from >= gap_s:
                add(tick_stall_from, "tick_stall", f"拍号 {prev['tick']} 停了 {float(prev['ts']) - tick_stall_from:.0f} s（{tick_stall_from - t0:.0f} s 起）")
            tick_stall_from = None
        dm = int(cur["missed_render"]) - int(prev["missed_render"])
        if dm > 0:
            add(ts, "missed_render", f"V2 +{dm}（累计 {cur['missed_render']}）")
        for key, kind in (("dropouts", "audio_dropouts"), ("underruns", "audio_underruns")):
            dv = int(cur["audio"][key]) - int(prev["audio"][key])
            if dv > 0:
                add(ts, kind, f"A1 {key} +{dv}（累计 {cur['audio'][key]}）")
        pe, ce = _enc(prev), _enc(cur)
        for i, e in enumerate(ce):
            p = pe[i] if i < len(pe) else {}
            tag = f"encoder[{i}]（输出 {e.get('output', 0)}）"
            for key, kind in (("skipped", "encoder_skipped"), ("dropped", "encoder_dropped"), ("reconnects", "encoder_reconnects")):
                dv = int(e.get(key, 0)) - int(p.get(key, 0))
                if dv > 0:
                    add(ts, kind, f"{tag} {key} +{dv}（累计 {e.get(key)}）")
            if p and e.get("state") != p.get("state") and ts - t0 >= settle_s and tlast - ts >= settle_s:
                add(ts, "encoder_state", f"{tag} {p.get('state')} → {e.get('state')}")
        if float(cur["jitter_ms"]) > V3_MUST_MS:
            add(ts, "v3_spike", f"jitter_ms {float(cur['jitter_ms']):.2f} > {V3_MUST_MS:g}")
        if float(cur["render_ms"]) > V1_MUST_P99_MS:
            add(ts, "v1_spike", f"render_ms {float(cur['render_ms']):.2f} > {V1_MUST_P99_MS:g}")
        for n, pin in (cur.get("per_input") or {}).items():
            fps = float(pin.get("fps", 0))
            if fps > 0:
                seen_active.add(n)
                if n in stall_start:
                    st = stall_start.pop(n)
                    if ts - st >= stall_s:
                        add(st, "input_stalled", f"输入 {n} 停帧 {ts - st:.0f} s（{st - t0:.0f} s 起）")
            elif n in seen_active and n not in stall_start:
                stall_start[n] = ts
    for n, st in stall_start.items():
        if tlast - st >= stall_s:
            add(st, "input_stalled", f"输入 {n} 从 {st - t0:.0f} s 起停帧直到结束（{tlast - st:.0f} s）")
    out.sort(key=lambda e: e["ts"])
    return out


def merge_ranges(evs, before=300.0, after=300.0):
    ranges = []
    for e in sorted(evs, key=lambda x: x["ts"]):
        s, t = e["ts"] - before, e["ts"] + after
        if ranges and s <= ranges[-1]["end"]:
            ranges[-1]["end"] = max(ranges[-1]["end"], t)
            ranges[-1]["events"].append(e)
        else:
            ranges.append({"start": s, "end": t, "events": [e]})
    return ranges


# ---------------------------------------------------------------- S2 / A3

def per_minute(lines, key="rss_mb"):
    if not lines:
        return []
    t0 = float(lines[0]["ts"])
    out, seen = [], set()
    for l in lines:
        bucket = int((float(l["ts"]) - t0) // 60)
        if bucket not in seen:
            seen.add(bucket)
            out.append((float(l["ts"]), float(l[key])))
    return out


def s2_fit(samples, warmup_s=1800.0, min_fit_s=3600.0):
    if len(samples) < 2:
        return {"verdict": "reference", "slope_mb_per_h": None, "after_warmup": False, "samples": len(samples)}
    t0 = samples[0][0]
    after = [(t, v) for t, v in samples if t >= t0 + warmup_s]
    after_warmup = len(after) >= 2
    fit = after if after_warmup else samples
    slope, intercept, r2 = pj.linear_fit([t for t, _ in fit], [v for _, v in fit])
    span = fit[-1][0] - fit[0][0]
    res = {"after_warmup": after_warmup, "samples": len(fit), "fit_span_s": span, "r2": r2,
           "slope_mb_per_h": None if slope is None else slope * 3600.0,
           "rss_first_mb": samples[0][1], "rss_last_mb": samples[-1][1],
           "rss_fit_first_mb": fit[0][1], "rss_fit_last_mb": fit[-1][1],
           "rss_max_mb": max(v for _, v in samples)}
    if slope is None or not after_warmup or span < min_fit_s:
        res["verdict"] = "reference"
    else:
        res["verdict"] = "pass" if res["slope_mb_per_h"] <= S2_MUST_MB_H else "fail"
    res["meets_target"] = res["slope_mb_per_h"] is not None and res["slope_mb_per_h"] <= S2_TARGET_MB_H
    return res


def a3_from_probe(probe, hours):
    if not probe:
        return {"pass": None, "drift_ms": None, "extrapolated": False, "note": "没有 frameprobe av 结果"}
    av = probe.get("av", probe)
    on = av.get("onSecond") or {}
    if not on or int(on.get("count", 0)) < 2:
        return {"pass": None, "drift_ms": None, "extrapolated": False, "note": "整秒配对不足两对"}
    span = float(on.get("spanSeconds", 0))
    slope = float(on.get("slopeMsPerSecond", 0))
    full = hours >= 8 and span >= 8 * 3600 - 600
    drift = float(on.get("driftOverSpanMs", slope * span)) if full else slope * 8 * 3600
    return {"pass": abs(drift) <= A3_MUST_MS, "meets_target": abs(drift) <= A3_TARGET_MS, "drift_ms": drift, "extrapolated": not full,
            "slope_ms_per_s": slope, "span_s": span, "pairs": int(on.get("count", 0)),
            "a2_max_abs_ms": on.get("maxAbsMs"), "a2_mean_ms": on.get("meanMs"), "a2_std_ms": on.get("stdMs"),
            "pass_a2": av.get("passA2"), "note": "" if full else f"只跑了 {span / 3600:.2f} h：斜率 × 8 h 外推"}


def combine_segment_probes(segments, a2_threshold_ms=1000.0 / 60):
    """按段跑的 frameprobe av 结果合并成整条录像的 AVOutput 形状（soak_report / a3_from_probe 照常读）。
    segments = [(段起点在整条录像里的秒数, 该段的 probe JSON)]。整秒配对的判定用 frameprobe 自己的（每段给了对应的 --start-tick），
    这里只把段内时刻加上段起点，再对全部整秒配对做与 FrameAnalysis.AVStats 相同的统计（均值 / 标准差 / 最大绝对值 / 最小二乘斜率 / 斜率 × 首尾间隔）。"""
    times, offsets = [], []
    flash = click = matched = off_second = 0
    events = []
    for start, probe in segments:
        av = (probe or {}).get("av") or {}
        flash += int(av.get("flashCount", 0))
        click += int(av.get("clickCount", 0))
        matched += int(av.get("matchedCount", 0))
        off_second += int(av.get("offSecondCount", 0))
        for p in av.get("pairs") or []:
            if p.get("offsetMs") is None or not p.get("onSecondTick"):
                continue
            times.append(float(start) + float(p["flashTimeSeconds"]))
            offsets.append(float(p["offsetMs"]))
        for e in ((probe or {}).get("discontinuities") or {}).get("events") or []:
            events.append(dict(e, timeSeconds=float(start) + float(e["timeSeconds"])))
    order = sorted(range(len(times)), key=lambda i: times[i])
    times = [times[i] for i in order]
    offsets = [offsets[i] for i in order]
    n = len(offsets)
    mean = sum(offsets) / n if n else 0.0
    std = (sum((o - mean) ** 2 for o in offsets) / n) ** 0.5 if n else 0.0
    slope = pj.linear_fit(times, offsets)[0] if n >= 2 else None
    span = (times[-1] - times[0]) if n else 0.0
    on = {"count": n, "meanMs": mean, "stdMs": std, "maxAbsMs": max((abs(o) for o in offsets), default=0.0),
          "slopeMsPerSecond": slope or 0.0, "driftOverSpanMs": (slope or 0.0) * span, "spanSeconds": span}
    disc_count = sum(int((((p or {}).get("discontinuities") or {}).get("count")) or 0) for _, p in segments)
    return {"av": {"onSecond": on, "flashCount": flash, "clickCount": click, "matchedCount": matched, "offSecondCount": off_second,
                   "passA2": (on["maxAbsMs"] <= a2_threshold_ms) if n else None},
            "discontinuities": {"count": disc_count, "events": sorted(events, key=lambda e: e["timeSeconds"])},
            "segments": len(segments)}
