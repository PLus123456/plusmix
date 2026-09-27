#!/usr/bin/env python3
"""W4-A 的 L5 判定库（make perf-baseline；scripts/soak/ 也用这里的百分位 / 拟合 / powermetrics 解析）。

口径（测试标准 §1 / §3 / §4 / §5 L5 / §7；StatsSummary 的同名量逐字同口径，不另起算法）：
- 百分位用最近秩法：升序第 ceil(p × N) 个（1 起），不插值——与 SwitcherTestKit.StatsSummary.percentile 相同。
- V1 = render_ms 各秒平均值的 avg / p99；V2 = missed_render 末行 − 首行，比例按拍数（末行 tick − 首行 tick）；
  V3 = jitter_ms（每秒窗口最大值）的 p99 / max；S3 = cpu_pct（100 = 一个核）/ gpu_pct（IOKit Device Utilization）的 avg / p95。
- powermetrics（sudo，§3 S3 的对照）：-f plist 输出是一串以 NUL 分隔的 plist；GPU 占用 = 1 − gpu.idle_ratio。
- L5 退步（prompt 70 第 3 条"退步 > 10% 非零退出"；§4 E4"相对上一版本 VMAF 不降超过 1 分"）：只和**同一台机器、同一 macOS 大版本**的上一版基线比
  （prompt 70 第 7 条：26.6.2 的 g4 基线不与 27 上的结果判退步）。规则表 DEFAULT_RULES，可由 scripts/perf/regression.json 覆盖（阈值是用户的，默认值照 prompt 抄）。
"""
import json
import math
import os
import plistlib
import re

# 测试标准 §4（与 StatsSummary.Thresholds 同值；改阈值是用户的事，铁律 9）
MUST = {"v1_avg_ms": 6.0, "v1_p99_ms": 12.0, "v2_ratio": 0.0002, "v3_p99_ms": 4.0, "cpu_avg_pct": 60.0, "gpu_avg_pct": 50.0}
TARGET = {"v1_avg_ms": 4.0, "v1_p99_ms": 8.0, "v2_ratio": 0.0, "v3_p99_ms": 2.0, "cpu_avg_pct": 40.0, "gpu_avg_pct": 35.0}

# L5 退步规则：better = 哪边好；pct = 相对上一版变坏超过这么多百分比算退步；abs = 绝对变坏超过这么多算退步（两者任一触发）；
# floor = 绝对变坏不到这么多时不算（默认没有，由用户在 regression.json 里给）；zero_baseline = "must" 表示基线为 0 时比例算不出、改按必须档判。
DEFAULT_RULES = {
    "v1_avg_ms": {"better": "lower", "pct": 10.0},
    "v1_p99_ms": {"better": "lower", "pct": 10.0},
    "v2_ratio": {"better": "lower", "pct": 10.0, "zero_baseline": "must"},
    "v3_p99_ms": {"better": "lower", "pct": 10.0},
    "cpu_avg_pct": {"better": "lower", "pct": 10.0},
    "cpu_p95_pct": {"better": "lower", "pct": 10.0},
    "gpu_avg_pct": {"better": "lower", "pct": 10.0},
    "gpu_p95_pct": {"better": "lower", "pct": 10.0},
    "pm_gpu_active_avg_pct": {"better": "lower", "pct": 10.0},
    "pm_gpu_active_p95_pct": {"better": "lower", "pct": 10.0},
    "e4_vmaf_mean": {"better": "higher", "pct": 10.0, "abs": 1.0},
    "e4_psnr_y_db": {"better": "higher", "pct": 10.0},
}

METRIC_NAMES = {
    "v1_avg_ms": "V1 渲染耗时 avg", "v1_p99_ms": "V1 渲染耗时 p99", "v2_ratio": "V2 渲染滞后丢帧比例", "v3_p99_ms": "V3 抖动 p99",
    "cpu_avg_pct": "S3 CPU avg", "cpu_p95_pct": "S3 CPU p95", "gpu_avg_pct": "S3 GPU avg（IOKit）", "gpu_p95_pct": "S3 GPU p95（IOKit）",
    "pm_gpu_active_avg_pct": "S3 GPU avg（powermetrics）", "pm_gpu_active_p95_pct": "S3 GPU p95（powermetrics）",
    "e4_vmaf_mean": "E4 VMAF 均值", "e4_psnr_y_db": "E4 PSNR-Y",
}


# ---------------------------------------------------------------- 基本统计

def percentile(values, p):
    """最近秩法（StatsSummary.percentile 同口径）：升序第 ceil(p × N) 个（1 起）；空序列返回 0。"""
    if not values:
        return 0
    s = sorted(values)
    rank = int(math.ceil(p * len(s)))
    return s[max(0, min(len(s), rank) - 1)]


def series(values):
    if not values:
        return {"count": 0, "min": 0, "avg": 0, "p95": 0, "p99": 0, "max": 0}
    return {"count": len(values), "min": min(values), "avg": sum(values) / len(values),
            "p95": percentile(values, 0.95), "p99": percentile(values, 0.99), "max": max(values)}


def linear_fit(xs, ys):
    """最小二乘：返回 (斜率, 截距, R²)。点数 < 2 或 x 全相同返回 (None, None, None)。"""
    n = len(xs)
    if n < 2:
        return None, None, None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None, None, None
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    slope = sxy / sxx
    intercept = my - slope * mx
    syy = sum((y - my) ** 2 for y in ys)
    r2 = 1.0 if syy == 0 else (sxy * sxy) / (sxx * syy)
    return slope, intercept, r2


def load_stats(path):
    """stats.jsonl → 行列表（坏行跳过并计数：写一半被杀的末行不该让整份报告出不来）。"""
    lines, bad = [], 0
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                lines.append(json.loads(raw))
            except json.JSONDecodeError:
                bad += 1
    return lines, bad


def perf_metrics(lines):
    """V1–V3、S3 的数（与 StatsSummary 同口径，另加 p95）。"""
    if not lines:
        return {}
    first, last = lines[0], lines[-1]
    ticks = int(last["tick"]) - int(first["tick"])
    missed = int(last["missed_render"]) - int(first["missed_render"])
    render = [float(l["render_ms"]) for l in lines]
    jitter = [float(l["jitter_ms"]) for l in lines]
    cpu = [float(l["cpu_pct"]) for l in lines]
    gpu = [float(l["gpu_pct"]) for l in lines]
    rss = [float(l["rss_mb"]) for l in lines]
    return {
        "lines": len(lines), "duration_s": float(last["ts"]) - float(first["ts"]), "ticks": ticks,
        "v1_avg_ms": sum(render) / len(render), "v1_p99_ms": percentile(render, 0.99), "v1_max_ms": max(render),
        "v2_missed": missed, "v2_ratio": (missed / ticks) if ticks > 0 else 0.0,
        "v3_p99_ms": percentile(jitter, 0.99), "v3_max_ms": max(jitter),
        "cpu_avg_pct": sum(cpu) / len(cpu), "cpu_p95_pct": percentile(cpu, 0.95), "cpu_max_pct": max(cpu),
        "gpu_avg_pct": sum(gpu) / len(gpu), "gpu_p95_pct": percentile(gpu, 0.95), "gpu_max_pct": max(gpu),
        "rss_min_mb": min(rss), "rss_max_mb": max(rss),
    }


# ---------------------------------------------------------------- powermetrics

def parse_powermetrics(blob):
    """powermetrics -f plist 的输出：一串 plist，以 NUL 分隔；截断的尾巴（进程被停时写了一半）跳过。"""
    out = []
    for chunk in blob.split(b"\0"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            out.append(plistlib.loads(chunk))
        except Exception:  # noqa: BLE001 —— 半截 plist 各种异常都有可能
            continue
    return out


def _mhz(v):
    # GPU 的 freq_hz 在有的系统版本上其实是 MHz（asitop 就按 MHz 读）；> 1e5 当 Hz 换算，否则原样当 MHz
    v = float(v)
    return v / 1e6 if v > 1e5 else v


def powermetrics_summary(samples):
    gpu_active, gpu_freq, gpu_mw, cpu_mw, pressure, clusters = [], [], [], [], {}, {}
    for s in samples:
        g = s.get("gpu") or {}
        if "idle_ratio" in g:
            gpu_active.append((1.0 - float(g["idle_ratio"])) * 100.0)
        if "freq_hz" in g:
            gpu_freq.append(_mhz(g["freq_hz"]))
        elapsed = float(s.get("elapsed_ns") or 0) / 1e9
        proc = s.get("processor") or {}
        energy = proc.get("gpu_energy", g.get("gpu_energy"))
        if energy is not None and elapsed > 0:
            gpu_mw.append(float(energy) / elapsed)          # mJ / s = mW（powermetrics 的能量单位按 mJ 读，报告里标"原始口径"）
        if proc.get("cpu_energy") is not None and elapsed > 0:
            cpu_mw.append(float(proc["cpu_energy"]) / elapsed)
        tp = s.get("thermal_pressure")
        if tp is not None:
            pressure[str(tp)] = pressure.get(str(tp), 0) + 1
        for c in proc.get("clusters") or []:
            if "freq_hz" in c:
                clusters.setdefault(str(c.get("name", "?")), []).append(_mhz(c["freq_hz"]))
    out = {"pm_samples": len(samples), "pm_thermal_pressure": pressure,
           "pm_cluster_freq_avg_mhz": {k: sum(v) / len(v) for k, v in clusters.items()},
           "pm_cluster_freq_min_mhz": {k: min(v) for k, v in clusters.items()}}
    if gpu_active:
        out["pm_gpu_active_avg_pct"] = sum(gpu_active) / len(gpu_active)
        out["pm_gpu_active_p95_pct"] = percentile(gpu_active, 0.95)
    if gpu_freq:
        out["pm_gpu_freq_avg_mhz"] = sum(gpu_freq) / len(gpu_freq)
        out["pm_gpu_freq_min_mhz"] = min(gpu_freq)
    if gpu_mw:
        out["pm_gpu_power_avg_mw"] = sum(gpu_mw) / len(gpu_mw)
    if cpu_mw:
        out["pm_cpu_power_avg_mw"] = sum(cpu_mw) / len(cpu_mw)
    return out


# ---------------------------------------------------------------- E4

def align_offset(rec, src, max_offset=120):
    """录像里源片段第 0 帧在第几帧：逐帧亮度均值序列做滑动比对，取均方差最小的偏移（文件输入起播前是黑场，末尾停在末帧）。"""
    best = (None, float("inf"))
    n = len(src)
    for k in range(0, max_offset + 1):
        m = min(n, len(rec) - k)
        if m < max(30, n // 2):
            break
        cost = sum((rec[k + i] - src[i]) ** 2 for i in range(m)) / m
        if cost < best[1]:
            best = (k, cost)
    return best


def vmaf_summary(log, segments):
    """libvmaf 的 JSON 日志（log_fmt=json）→ 整段与各段的均值。segments = [(名字, 起帧, 止帧)]（源片段的帧号，止帧不含）。"""
    frames = sorted(log.get("frames", []), key=lambda f: f.get("frameNum", 0))
    def col(key, lo=0, hi=None):
        return [float(f["metrics"][key]) for f in frames[lo:hi] if key in f.get("metrics", {})]
    vm = col("vmaf")
    out = {"frames": len(frames), "segments": {}}
    if vm:
        out["e4_vmaf_mean"] = sum(vm) / len(vm)
        out["e4_vmaf_min"] = min(vm)
        out["e4_vmaf_p5"] = percentile(vm, 0.05)
        out["e4_vmaf_harmonic"] = len(vm) / sum(1.0 / (1.0 + v) for v in vm) - 1.0
    ps = col("psnr_y")
    if ps:
        out["e4_psnr_y_db"] = sum(ps) / len(ps)
    ss = col("float_ssim")
    if ss:
        out["e4_ssim"] = sum(ss) / len(ss)
    for name, lo, hi in segments:
        seg = {}
        v = col("vmaf", lo, hi)
        if v:
            seg["vmaf_mean"] = sum(v) / len(v)
            seg["vmaf_min"] = min(v)
        p = col("psnr_y", lo, hi)
        if p:
            seg["psnr_y_db"] = sum(p) / len(p)
        out["segments"][name] = seg
    return out


# ---------------------------------------------------------------- 与上一版比

def load_rules(path):
    rules = json.loads(json.dumps(DEFAULT_RULES))
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            user = json.load(f)
        for k, v in user.items():
            if k.startswith("_") or not isinstance(v, dict):
                continue
            rules.setdefault(k, {}).update(v)
    return rules


def compare(current, baseline, rules):
    """逐项比：两边都有的数才比。返回 [{metric, cur, base, delta, delta_pct, regression, note}]。"""
    rows = []
    for metric, rule in rules.items():
        if metric not in current or metric not in baseline:
            continue
        cur, base = current[metric], baseline[metric]
        if cur is None or base is None:
            continue
        cur, base = float(cur), float(base)
        worse = (cur - base) if rule.get("better", "lower") == "lower" else (base - cur)   # > 0 = 变坏
        delta = cur - base
        delta_pct = (delta / base * 100.0) if base != 0 else None
        worse_pct = (worse / abs(base) * 100.0) if base != 0 else None
        regression, note = False, ""
        if base == 0 and rule.get("zero_baseline") == "must" and metric in MUST:
            regression = cur > MUST[metric]
            note = f"基线为 0，比例算不出，按必须档（≤ {fmt_metric(metric, MUST[metric])}）判"
        else:
            if worse_pct is not None and "pct" in rule and worse_pct > rule["pct"]:
                regression = True
                note = f"变坏 {worse_pct:.1f}% > {rule['pct']:g}%"
            if "abs" in rule and worse > rule["abs"]:
                regression = True
                note = (note + "；" if note else "") + f"变坏 {worse:.3f} > {rule['abs']:g}"
            if base == 0 and worse > 0 and "abs" not in rule:
                note = "基线为 0，比例算不出（不判）"
        if regression and "floor" in rule and worse <= rule["floor"]:
            regression = False
            note += f"（绝对变坏 {worse:.4g} ≤ 下限 {rule['floor']:g}，不算退步：regression.json）"
        rows.append({"metric": metric, "name": METRIC_NAMES.get(metric, metric), "cur": cur, "base": base, "delta": delta,
                     "delta_pct": delta_pct, "regression": regression, "note": note})
    return rows


def fmt_metric(metric, v):
    if v is None:
        return "—"
    if metric == "v2_ratio":
        return f"{v * 100:.4f}%"
    if metric.endswith("_pct"):
        return f"{v:.1f}%"
    if metric.endswith("_ms"):
        return f"{v:.3f} ms"
    if metric.endswith("_db"):
        return f"{v:.2f} dB"
    return f"{v:.3f}"


# ---------------------------------------------------------------- 机器 / 系统 / 基线文件

def machine_tag(chip, model):
    """"Apple M5 Max" + "MacBook Pro" → m5max；"Apple M1" + "MacBook Air" → m1air（baselines/README 的 *-m1air.json）。"""
    tag = re.sub(r"[^a-z0-9]", "", chip.lower().replace("apple", ""))
    if "air" in (model or "").lower():
        tag += "air"
    return tag or "unknown"


def os_major(version):
    return str(version).split(".")[0]


def baseline_path(directory, machine, macos_version):
    return os.path.join(directory, f"perf-{machine}-macos{os_major(macos_version)}.json")


# ---------------------------------------------------------------- S4（无风扇机型热降频；测试标准 §1 S4、§3 S4、§4 S4）

PRESSURE_ORDER = ["Nominal", "Moderate", "Heavy", "Trapping", "Sleeping"]


def _pressure_rank(p):
    """None 最低；不认识的名字（系统版本换了叫法）当作比 Nominal 高一级。"""
    if p is None:
        return -1
    return PRESSURE_ORDER.index(p) if p in PRESSURE_ORDER else 1


def s4_timeline(samples, lines, minute_s=60):
    """按分钟对齐 powermetrics 样本（带 _ts 墙钟）与 stats.jsonl：最坏的 thermal pressure、各簇 / GPU 频率均值、该分钟的 V2 增量与拍数。"""
    if not lines:
        return []
    t0 = float(lines[0]["ts"])
    n = int((float(lines[-1]["ts"]) - t0) // minute_s) + 1
    rows = [{"minute": i, "pressure": None, "cluster_mhz": {}, "gpu_mhz": [], "missed": 0, "ticks": 0} for i in range(n)]
    for s in samples:
        i = int((float(s.get("_ts", 0)) - t0) // minute_s)
        if not 0 <= i < n:
            continue
        r = rows[i]
        p = s.get("thermal_pressure")
        if p is not None and _pressure_rank(str(p)) > _pressure_rank(r["pressure"]):
            r["pressure"] = str(p)
        for c in (s.get("processor") or {}).get("clusters") or []:
            if "freq_hz" in c:
                r["cluster_mhz"].setdefault(str(c.get("name", "?")), []).append(_mhz(c["freq_hz"]))
        g = s.get("gpu") or {}
        if "freq_hz" in g:
            r["gpu_mhz"].append(_mhz(g["freq_hz"]))
    prev = lines[0]
    j = 0
    for i in range(n):
        end_ts = t0 + (i + 1) * minute_s
        while j + 1 < len(lines) and float(lines[j + 1]["ts"]) <= end_ts:
            j += 1
        cur = lines[j]
        rows[i]["missed"] = int(cur["missed_render"]) - int(prev["missed_render"])
        rows[i]["ticks"] = int(cur["tick"]) - int(prev["tick"])
        prev = cur
    for r in rows:
        r["cluster_mhz"] = {k: sum(v) / len(v) for k, v in r["cluster_mhz"].items()}
        r["gpu_mhz"] = (sum(r["gpu_mhz"]) / len(r["gpu_mhz"])) if r["gpu_mhz"] else None
    return rows


def s4_verdict(rows, freq_drop=0.15, reference_minutes=5):
    """降频起点 = 第一个 thermal pressure 不是 Nominal 的分钟，或任一簇 / GPU 频率比前 5 分钟的中位数低 freq_drop 以上的分钟；
    起点之后的 V2（missed 增量之和 / 拍数之和）≤ 0.02% 算"V2 仍达标"（§4 S4 必须档；引擎目前没有降级策略，只能按这一条判）。"""
    def median(xs):
        xs = sorted(xs)
        return xs[len(xs) // 2] if xs else None
    ref = rows[:reference_minutes]
    ref_cluster = {}
    for r in ref:
        for k, v in r["cluster_mhz"].items():
            ref_cluster.setdefault(k, []).append(v)
    ref_cluster = {k: median(v) for k, v in ref_cluster.items()}
    ref_gpu = median([r["gpu_mhz"] for r in ref if r["gpu_mhz"]])
    onset, why = None, ""
    for r in rows[reference_minutes:] if len(rows) > reference_minutes else []:
        reasons = []
        if r["pressure"] not in (None, "Nominal"):
            reasons.append(f"thermal pressure {r['pressure']}")
        for k, v in r["cluster_mhz"].items():
            base = ref_cluster.get(k)
            if base and v < (1 - freq_drop) * base:
                reasons.append(f"{k} {v:.0f} MHz < {(1 - freq_drop) * 100:.0f}% × {base:.0f}")
        if ref_gpu and r["gpu_mhz"] and r["gpu_mhz"] < (1 - freq_drop) * ref_gpu:
            reasons.append(f"GPU {r['gpu_mhz']:.0f} MHz < {(1 - freq_drop) * 100:.0f}% × {ref_gpu:.0f}")
        if reasons:
            onset, why = r["minute"], "；".join(reasons)
            break
    total_missed = sum(r["missed"] for r in rows)
    total_ticks = sum(r["ticks"] for r in rows)
    if onset is None:
        ratio = total_missed / total_ticks if total_ticks else 0.0
        return {"throttled": False, "onset_minute": None, "why": "", "v2_after": total_missed, "ticks_after": total_ticks,
                "v2_ratio_after": ratio, "pass": ratio <= MUST["v2_ratio"],
                "note": "这段时间里没出现降频（thermal pressure 一直 Nominal、频率没掉）：S4 的条件没触发，按全程 V2 报"}
    after = [r for r in rows if r["minute"] >= onset]
    missed = sum(r["missed"] for r in after)
    ticks = sum(r["ticks"] for r in after)
    ratio = missed / ticks if ticks else 0.0
    return {"throttled": True, "onset_minute": onset, "why": why, "v2_after": missed, "ticks_after": ticks, "v2_ratio_after": ratio,
            "pass": ratio <= MUST["v2_ratio"], "note": ""}
