#!/usr/bin/env python3
"""make soak / soak-1h 的判定、异常截取与 §7 报告（W4-A）。scripts/soak/soak.sh 跑完调它；也可以对已有产物单独重跑（soak.sh --skip-run）。

退出码：0 = S1 通过且 S2 / S3 / A3（判得了的）通过（§5 L4 = S1、S2、S3、A3）；1 = 有不过的；2 = 产物缺失。
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf"))
import perfjudge as pj  # noqa: E402
import soakjudge as sj  # noqa: E402

MAX_EXCERPTS = 40          # 异常段最多截这么多份（前 39 段 + 最后一段）；事件表全列
MAX_LOG_SHOW = 10          # 系统日志（log show，每段十几秒）只取前 10 段，其余段照截 stats / 采样日志
LOG_SHOW_LINES = 4000


def read_kv(path):
    out = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
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


def f(v, d=3):
    return "—" if v is None else f"{v:.{d}f}"


def hms(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def show_path(p):
    rel = os.path.relpath(p)
    return os.path.abspath(p) if rel.startswith("..") else rel


def lines_in_range(path, start, end, ts_of):
    """文本日志里时间戳落在 [start, end] 的行。ts_of(line) → float 或 None（取不到时间的行跟着上一行走）。"""
    out = []
    if not os.path.exists(path):
        return out
    keep = False
    for raw in open(path, encoding="utf-8", errors="replace"):
        t = ts_of(raw)
        if t is not None:
            keep = start <= t <= end
        if keep:
            out.append(raw)
    return out


def first_float(raw):
    try:
        return float(raw.split(None, 1)[0])
    except (ValueError, IndexError):
        return None


def json_ts(raw):
    try:
        return float(json.loads(raw)["ts"])
    except (ValueError, KeyError, TypeError):
        return None


def powermetrics_samples(path, start_epoch):
    """powermetrics -f plist 的样本，带墙钟时刻：样本自带 timestamp 就用它，否则 = 开始时刻 + 累计 elapsed_ns。"""
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return []
    samples = pj.parse_powermetrics(open(path, "rb").read())
    t = float(start_epoch or 0)
    for s in samples:
        stamp = s.get("timestamp")
        if isinstance(stamp, datetime.datetime):
            s["_ts"] = stamp.replace(tzinfo=datetime.timezone.utc).timestamp() if stamp.tzinfo is None else stamp.timestamp()
        else:
            t += float(s.get("elapsed_ns") or 0) / 1e9
            s["_ts"] = t
    return samples


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--label", default="8h")
    ap.add_argument("--hours", type=float, default=8)
    ap.add_argument("--baseline-dir", default="baselines")
    ap.add_argument("--report", default="")
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--no-log-show", action="store_true", help="异常段不调 log show（测试 / 没有系统日志权限时）")
    a = ap.parse_args()
    od = a.out_dir

    run = read_kv(os.path.join(od, "run.txt"))
    env = read_kv(os.path.join(od, "environment.txt"))
    stats_path = os.path.join(od, "stats.jsonl")
    if not os.path.exists(stats_path):
        print(f"没有 {stats_path}", file=sys.stderr)
        return 2
    lines, bad_lines = pj.load_stats(stats_path)
    if len(lines) < 2:
        print(f"{stats_path} 不到两行", file=sys.stderr)
        return 2
    lines.sort(key=lambda l: float(l["ts"]))
    # 运行段 / 停机段：最后一拍之后（引擎已停，录制封口、推流排空、音频引擎最后才停）的行不进判定，单列
    all_lines = lines
    lines, tail = sj.run_segment(all_lines)
    if len(lines) < 2:
        print("运行段不到两行", file=sys.stderr)
        return 2
    t0, tlast = float(lines[0]["ts"]), float(lines[-1]["ts"])
    covered = tlast - t0
    expected = float(run.get("duration_s") or a.hours * 3600) - 1.0      # 第一行在第 1 s 末，末行在停机前：满跑覆盖 ≈ 时长 − 1 s
    exit_code = int(run.get("exit_code", "0") or 0)
    machine = pj.machine_tag(env.get("chip", ""), env.get("model", ""))
    macos = env.get("macos", "?")
    fps = 60.0

    # ---- frameprobe / ffprobe ----
    # soak.sh 按 5 分钟切段逐段跑 frameprobe（整条跑内存随帧数涨），这里合到整条时间轴；老的整条结果（probe-av.json）也认
    seg_csv = os.path.join(od, "probe-seg", "segments.csv")
    seg_missing = []
    seg_count = 0
    if os.path.exists(seg_csv):
        segs = []
        for raw in open(seg_csv, encoding="utf-8"):
            parts = raw.strip().split(",")
            if len(parts) < 2:
                continue
            got = load_json(os.path.join(od, "probe-seg", parts[0].rsplit(".", 1)[0] + ".json"))
            if got is None:
                seg_missing.append(parts[0])
            else:
                segs.append((float(parts[1]), got))
        seg_count = len(segs) + len(seg_missing)
        probe = sj.combine_segment_probes(segs) if segs else None
        if probe is not None:
            json.dump(probe, open(os.path.join(od, "probe-av-combined.json"), "w"), ensure_ascii=False)
    else:
        probe = load_json(os.path.join(od, "probe-av.json"))
    disc = (probe or {}).get("discontinuities") or {}
    ffp = load_json(os.path.join(od, "ffprobe.json")) or {}
    ff_err = open(os.path.join(od, "ffprobe-errors.txt"), encoding="utf-8", errors="replace").read().strip() if os.path.exists(os.path.join(od, "ffprobe-errors.txt")) else None

    # ---- S1 窗口 ----
    ws = sj.windows(lines, 300)
    if probe is not None:
        sj.attach_offline_discontinuities(ws, disc.get("events", []), fps=fps, start_tick=0)
    judged = [sj.judge_window(w) for w in ws]
    crash_dir = os.path.join(od, "crash")
    crashes = sorted(os.listdir(crash_dir)) if os.path.isdir(crash_dir) else []
    s1 = sj.s1_verdict(judged, exit_code=exit_code, expected_s=expected, covered_s=covered, crash_reports=crashes)

    # ---- 事件与异常段 ----
    evs = sj.events(lines)
    for w in judged:
        if not w["ok"]:
            why = []
            if not w["v2_ok"]:
                why.append(f"V2 {w['missed']} / {w['ticks']}")
            if not w["a1_ok"]:
                why.append(f"A1 {w['dropouts']}+{w['underruns']}+离线 {w.get('offline_discontinuities', 0)}")
            if not w["e1_ok"]:
                why.append(f"E1 {w['skipped']}")
            evs.append({"ts": w["end_ts"], "kind": "window_fail", "detail": f"窗口 {w['index']}（{hms(w['start_ts'])}–{hms(w['end_ts'])}）：" + "、".join(why)})
    for e in disc.get("events", []) or []:
        tick = int(round(float(e["timeSeconds"]) * fps))
        near = min(lines, key=lambda l: abs(int(l["tick"]) - tick))
        evs.append({"ts": float(near["ts"]), "kind": "offline_discontinuity", "detail": f"录像 {float(e['timeSeconds']):.3f} s 波形跳变 {float(e.get('jump', 0)):+.3f}"})
    if exit_code != 0 or covered + 5 < expected or crashes:
        evs.append({"ts": tlast, "kind": "crash_or_short", "detail": f"退出码 {exit_code}，覆盖 {covered:.0f} / {expected:.0f} s，崩溃报告 {len(crashes)} 份"})
    evs.sort(key=lambda e: e["ts"])
    ranges = sj.merge_ranges(evs, 300, 300)
    anomalies_dir = os.path.join(od, "anomalies")
    shutil.rmtree(anomalies_dir, ignore_errors=True)
    pm_start = run.get("powermetrics_start_epoch")
    pm_all = powermetrics_samples(os.path.join(od, "powermetrics.plist"), pm_start)
    excerpt_ranges = ranges if len(ranges) <= MAX_EXCERPTS else ranges[:MAX_EXCERPTS - 1] + ranges[-1:]
    for n, r in enumerate(excerpt_ranges, 1):
        d = os.path.join(anomalies_dir, f"{n:02d}-{datetime.datetime.fromtimestamp(r['events'][0]['ts']).strftime('%H%M%S')}")
        os.makedirs(d, exist_ok=True)
        r["dir"] = d
        with open(os.path.join(d, "events.txt"), "w", encoding="utf-8") as out:
            for e in r["events"]:
                out.write(f"{hms(e['ts'])} {e['kind']} {e['detail']}\n")
        with open(os.path.join(d, "stats.jsonl"), "w", encoding="utf-8") as out:
            for l in lines:
                if r["start"] <= float(l["ts"]) <= r["end"]:
                    out.write(json.dumps(l, ensure_ascii=False) + "\n")
        for name, ts_of in (("headless.log", first_float), ("rss.log", first_float), ("env.log", first_float),
                            ("load.log", first_float), ("mtx.log", json_ts)):
            got = lines_in_range(os.path.join(od, name), r["start"], r["end"], ts_of)
            if got:
                open(os.path.join(d, name), "w", encoding="utf-8").writelines(got)
        pm_part = [s for s in pm_all if r["start"] <= s.get("_ts", 0) <= r["end"]]
        if pm_part:
            json.dump(pj.powermetrics_summary(pm_part), open(os.path.join(d, "powermetrics-summary.json"), "w"), ensure_ascii=False, indent=1)
        if not a.no_log_show and n <= MAX_LOG_SHOW:
            fmt = "%Y-%m-%d %H:%M:%S"
            cmd = ["log", "show", "--style", "compact", "--start", datetime.datetime.fromtimestamp(r["start"]).strftime(fmt),
                   "--end", datetime.datetime.fromtimestamp(r["end"]).strftime(fmt),
                   "--predicate", 'process == "switcher-headless" OR process == "mediamtx" OR eventMessage CONTAINS[c] "switcher-headless"']
            try:
                res = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
                body = res.stdout.splitlines(keepends=True)
                if len(body) > LOG_SHOW_LINES:
                    body = body[:LOG_SHOW_LINES // 2] + [f"…（中间省略 {len(body) - LOG_SHOW_LINES} 行）…\n"] + body[-LOG_SHOW_LINES // 2:]
                open(os.path.join(d, "system.log"), "w", encoding="utf-8").writelines(body)
            except (OSError, subprocess.TimeoutExpired) as ex:
                open(os.path.join(d, "system.log"), "w", encoding="utf-8").write(f"log show 失败：{ex}\n")

    # ---- S2 / S3 / A3 / V1–V3 ----
    s2 = sj.s2_fit(sj.per_minute(lines, "rss_mb"), warmup_s=1800, min_fit_s=3600)
    ps_samples = []
    if os.path.exists(os.path.join(od, "rss.log")):
        for raw in open(os.path.join(od, "rss.log"), encoding="utf-8"):
            parts = raw.split()
            try:
                kv = dict(p.split("=", 1) for p in parts[1:])
                ps_samples.append((float(parts[0]), float(kv["rss_kb"]) / 1024.0))
            except (ValueError, KeyError, IndexError):
                continue
    s2_ps = sj.s2_fit(ps_samples, warmup_s=1800, min_fit_s=3600) if len(ps_samples) >= 2 else None
    perf = pj.perf_metrics(lines)
    pm = pj.powermetrics_summary(pm_all) if pm_all else {}
    a3 = sj.a3_from_probe(probe, a.hours)
    s3 = sj.s3_verdict(perf)
    # S3 按线程：soak.sh 每分钟一份 thread-cpu 快照；只取运行段内的首尾两份（停机段的线程已经在退）
    threads = None
    if os.path.exists(os.path.join(od, "threads.log")):
        threads = sj.thread_cpu_breakdown(sj.parse_thread_log(open(os.path.join(od, "threads.log"), encoding="utf-8", errors="replace").read()),
                                          t_start=t0, t_end=tlast)

    # 输出 / 输入
    enc_first, enc_last = lines[0].get("encoder") or [], lines[-1].get("encoder") or []
    outputs = []
    for i, e in enumerate(enc_last):
        p = enc_first[i] if i < len(enc_first) else {}
        states = {}
        for l in lines:
            ee = l.get("encoder") or []
            if i < len(ee):
                states[ee[i].get("state", "?")] = states.get(ee[i].get("state", "?"), 0) + 1
        bitrates = [float((l.get("encoder") or [])[i].get("bitrate", 0)) for l in lines if i < len(l.get("encoder") or [])]
        outputs.append({"index": i, "output": e.get("output", 0), "frames": int(e.get("frames", 0)) - int(p.get("frames", 0)),
                        "dropped": int(e.get("dropped", 0)) - int(p.get("dropped", 0)), "skipped": int(e.get("skipped", 0)) - int(p.get("skipped", 0)),
                        "reconnects": int(e.get("reconnects", 0)) - int(p.get("reconnects", 0)), "connections_last": e.get("connections", 0),
                        "states": states, "last_state": e.get("state"), "bitrate_avg": (sum(bitrates) / len(bitrates)) if bitrates else 0,
                        "disk_free_mb_last": e.get("disk_free_mb", 0)})
    show = load_json(os.path.join(od, "soak-show.json")) or {}
    out_names = {o.get("number"): f"{o.get('kind')}「{o.get('name')}」" for o in show.get("outputs", [])}
    in_names = {str(i.get("number")): i.get("name") for i in show.get("inputs", [])}
    inputs = {}
    for n in sorted({k for l in lines for k in (l.get("per_input") or {})}, key=lambda x: int(x)):
        fpsv = [float(l["per_input"][n]["fps"]) for l in lines if n in (l.get("per_input") or {})]
        first_p = next(l["per_input"][n] for l in lines if n in (l.get("per_input") or {}))
        last_p = next(l["per_input"][n] for l in reversed(lines) if n in (l.get("per_input") or {}))
        inputs[n] = {"fps_avg": sum(fpsv) / len(fpsv), "fps_min": min(fpsv), "zero_seconds": sum(1 for v in fpsv if v == 0),
                     "dup": int(last_p.get("dup", 0)) - int(first_p.get("dup", 0)), "drop": int(last_p.get("drop", 0)) - int(first_p.get("drop", 0)),
                     "latency_max_ms": max(float(l["per_input"][n].get("latency_max_ms", 0)) for l in lines if n in (l.get("per_input") or {}))}

    # MediaMTX：每路收到的字节 → 平均码率、有没有哪一分钟一个字节都没收到。只用"就绪"期间的样本：推流端断开后那一路的计数会归零
    # （停机时推流先断，最后一个样本比第一个小，平均就成了负的——1 小时那次的 s1 就是这样）
    mtx = {}
    if os.path.exists(os.path.join(od, "mtx.log")):
        prev = {}
        for raw in open(os.path.join(od, "mtx.log"), encoding="utf-8"):
            try:
                rec = json.loads(raw)
            except json.JSONDecodeError:
                continue
            in_run = t0 + 60 < rec["ts"] < tlast - 30
            for item in ((rec.get("paths") or {}).get("items") or []):
                name, b, ready = item.get("name"), float(item.get("bytesReceived", 0)), bool(item.get("ready", False))
                if name not in mtx and not ready:
                    continue      # 还没人推（或配置里有、这次没人推的路：scripts/mediamtx.yml 的 s3 / srt1）
                m = mtx.setdefault(name, {"samples": 0, "stalled_minutes": 0, "not_ready_in_run": 0, "first": None, "last": None})
                m["samples"] += 1
                if not ready:
                    if in_run:
                        m["not_ready_in_run"] += 1
                    continue
                if m["first"] is None:
                    m["first"] = (rec["ts"], b)
                if name in prev and b <= prev[name] and in_run:
                    m["stalled_minutes"] += 1
                prev[name] = b
                if m["last"] is None or b >= m["last"][1]:
                    m["last"] = (rec["ts"], b)
        for m in mtx.values():
            dt = (m["last"][0] - m["first"][0]) if m["first"] and m["last"] else 0
            m["mbps_avg"] = ((m["last"][1] - m["first"][1]) * 8 / dt / 1e6) if dt > 0 else 0

    # 电源 / 温度（每分钟的 env.log）
    power_states, thermal_states, sys_power, busy_minutes = {}, {}, [], 0
    if os.path.exists(os.path.join(od, "env.log")):
        for raw in open(os.path.join(od, "env.log"), encoding="utf-8", errors="replace"):
            fields = dict(p.split("=", 1) for p in raw.rstrip("\n").split("\t")[1:] if "=" in p)
            th = raw.split("\t")[1] if raw.count("\t") >= 1 else ""
            thv = th.replace("thermal=", "").split(" ")[0] if th.startswith("thermal=") else "?"
            thermal_states[thv] = thermal_states.get(thv, 0) + 1
            pw = fields.get("power", "?").split(" ")[0:2]
            power_states[" ".join(pw[:1])] = power_states.get(" ".join(pw[:1]), 0) + 1
            try:
                sys_power.append(float(fields.get("system_power_in_mw", "")))
            except ValueError:
                pass
            if fields.get("busy", "").strip():
                busy_minutes += 1

    # ---- 上一版（同标签、同机、同大版本）----
    bpath = os.path.join(a.baseline_dir, f"soak{a.label}-{machine}-macos{pj.os_major(macos)}.json")
    base = load_json(bpath)
    cur_key = {"v1_avg_ms": perf["v1_avg_ms"], "v1_p99_ms": perf["v1_p99_ms"], "v2_ratio": perf["v2_ratio"], "v3_p99_ms": perf["v3_p99_ms"],
               "cpu_avg_pct": perf["cpu_avg_pct"], "cpu_p95_pct": perf["cpu_p95_pct"], "gpu_avg_pct": perf["gpu_avg_pct"], "gpu_p95_pct": perf["gpu_p95_pct"],
               "s2_mb_per_h": s2.get("slope_mb_per_h"), "a3_drift_ms": a3.get("drift_ms")}
    prev_key = (base or {}).get("key", {})

    def delta(k, digits=3, unit=""):
        if k not in prev_key or prev_key.get(k) is None or cur_key.get(k) is None:
            return "—（没有上一版）" if not base else "—"
        d = cur_key[k] - prev_key[k]
        return f"{'+' if d >= 0 else '−'}{abs(d):.{digits}f}{unit}"

    # ---- 报告 ----
    s2_judged = s2["verdict"] in ("pass", "fail")
    a3_judged = a3.get("pass") is not None
    overall = sj.overall_verdict(s1, s2, s3, a3)
    report = a.report or f"reports/W4-soak-{a.label}.md"
    out = []
    w = out.append
    w(f"# W4-A 长稳 {a.label}（make {'soak' if a.hours >= 8 else 'soak-1h' if a.hours == 1 else 'soak'}）：{machine} / macOS {macos}\n")
    bits = [f"S1 {'✅' if s1['pass'] else '❌'}", f"S2 {'✅' if s2['verdict'] == 'pass' else ('❌' if s2['verdict'] == 'fail' else '参考')}",
            f"S3 {'✅' if s3.get('pass') else ('❌' if s3.get('pass') is False else '—')}"
            + ("" if s3.get("pass") is not False else "（" + " / ".join(x for x, ok in (("CPU", s3.get("cpu_pass")), ("GPU", s3.get("gpu_pass"))) if ok is False) + "）"),
            f"A3 {'✅' if a3.get('pass') else ('❌' if a3.get('pass') is False else '—')}{'（外推）' if a3.get('extrapolated') else ''}"]
    w(f"**判定：{'✅ 通过' if overall else '❌ 未通过'}**（{'；'.join(bits)}）" + ("" if s1["pass"] else f"——S1：{'；'.join(s1['reasons'])}") + "\n")
    w(f"生成：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}。数据：`{show_path(od)}/`。脚本：scripts/soak/soak.sh → scripts/soak/soak_report.py（判定库 soakjudge.py）。\n")

    w("## 1. 版本 / 机器 / 环境（§7 报告头、§2.8）\n")
    w("| 项 | 值 |\n|---|---|")
    w(f"| 提交 | `{env.get('commit', '?')}`（{env.get('branch', '?')}，未提交改动 {env.get('dirty', '?')} 个） |")
    w(f"| 机器 | {env.get('chip', '?')} · {env.get('model', '?')}（{env.get('model_id', '?')}）· {env.get('cores', '?')} 核 · {env.get('memory_gb', '?')} GB |")
    w(f"| macOS | {macos}（{env.get('macos_build', '?')}）；{env.get('xcode', '')} |")
    w(f"| 起止 | {datetime.datetime.fromtimestamp(t0).strftime('%Y-%m-%d %H:%M:%S')} → {datetime.datetime.fromtimestamp(tlast).strftime('%H:%M:%S')}（stats 覆盖 {covered / 3600:.2f} h；headless 退出码 {exit_code}） |")
    pw_txt = "、".join(f"{k} {v} 分钟" for k, v in power_states.items()) or env.get("power", "?")
    w(f"| 电源 | 开跑前 {env.get('power', '?')}（电量 {env.get('battery_pct', '?')}%，适配器 {env.get('adapter_watts', '?')} W，powermode {env.get('powermode', '?')}）；逐分钟：{pw_txt}"
      + (f"；整机输入功率 {min(sys_power) / 1000:.1f}–{max(sys_power) / 1000:.1f} W（均值 {sum(sys_power) / len(sys_power) / 1000:.1f} W）" if sys_power else "") + " |")
    th_txt = "、".join(f"{k} {v} 分钟" for k, v in thermal_states.items()) or "未采"
    w(f"| 温度环境 | thermalState 逐分钟：{th_txt}（开跑前 {env.get('thermal_state', '?')}，跑完 {env.get('thermal_state_after', '?')}）；"
      f"powermetrics thermal pressure：{pm.get('pm_thermal_pressure') if pm else '未采（无 sudo）'}；pmset：{env.get('pmset_therm', '')}；室温：{env.get('ambient', '未记录')} |")
    busy_now = (env.get("busy_processes", "") + " " + env.get("busy_processes_after", "")).strip()
    w(f"| 负载 | 开跑前 {env.get('load_before', '?')} → 跑完 {env.get('load_after', '?')}；有编译 / 测试进程在跑的分钟数 {busy_minutes}（开跑前 / 跑完：{busy_now or '无'}） |")
    w(f"| 工具 | {env.get('ffmpeg', '')}；MediaMTX {env.get('mediamtx', '')}；NDI SDK {env.get('ndi_sdk', '') or '无'} |\n")

    w("## 2. 场景（标准负载，§3 S1 + prompt 70 第 1 条）\n")
    w(f"- 节目 `{show_path(os.path.join(od, 'soak-show.json'))}`（headless `make-show --preset soak`）：")
    for i in show.get("inputs", []):
        w(f"  - 输入 {i.get('number')}：{i.get('name')}")
    w(f"- 场景 `{show_path(os.path.join(od, 'soak.json'))}`（`make-scenario --preset soak`）：每 30 s 一次转场（Cut / Fade / Wipe / Zoom / Stinger 轮流），每 5 min 翻一路叠加（1 摄像头 / 2 文件 / 3、4 抠像合成源），PGM 只轮 1–8 号。")
    w(f"- 命令：`{run.get('command', '?').replace(os.getcwd() + '/', '')}`")
    w(f"- 输出：" + "；".join(f"encoder[{o['index']}] = {out_names.get(o['output'], '输出 ' + str(o['output']))}" for o in outputs))
    if run.get("camera_note"):
        w(f"- ⚠️ {run['camera_note']}")
    if run.get("ndi") == "0":
        w("- ⚠️ 这次没开 NDI 发送（没装 NDI SDK 或 --no-ndi）")
    w(f"- caffeinate -u -i -d -s -w <headless>；stats.jsonl 每秒一行（{len(lines)} 行{'，坏行 ' + str(bad_lines) if bad_lines else ''}）；每分钟采 RSS / 环境 / MediaMTX；powermetrics {'每 ' + str(int(round(covered / max(1, len(pm_all))))) + ' s 一样，' + str(len(pm_all)) + ' 样' if pm_all else '未采'}。\n")

    w("## 3. 判定（§4；每个指标：数值 · 阈值（必须 / 目标）· 通过 · 与上一版本的差）\n")
    w("| 指标 | 数值 | 必须 | 目标 | 通过 | 与上一版本的差 |\n|---|---|---|---|---|---|")
    bad_w = [w_ for w_ in judged if not w_["ok"]]
    w(f"| S1 长稳 | {len(judged)} 个 5 分钟窗口，超阈值 {len(bad_w)} 个"
      f"（V2 {sum(1 for x in judged if not x['v2_ok'])}、A1 {sum(1 for x in judged if not x['a1_ok'])}、E1 {sum(1 for x in judged if not x['e1_ok'])}）；退出码 {exit_code}；崩溃报告 {len(crashes)} 份；覆盖 {covered:.0f} / {expected:.0f} s | "
      f"{a.hours:g} 小时每个窗口 V2 ≤ 0.02%、A1 = 0、E1 = 0，无崩溃（硬性） | 24 小时 | {'✅' if s1['pass'] else '❌'} | — |")
    w(f"| V2 全程 | {perf['v2_missed']} 帧 / {perf['ticks']} 拍（{perf['v2_ratio'] * 100:.4f}%） | ≤ 0.02% | 0 | {'✅' if perf['v2_ratio'] <= sj.V2_MUST_RATIO else '❌'} | {delta('v2_ratio', 6)} |")
    a1_stream = int(lines[-1]['audio']['dropouts']) - int(lines[0]['audio']['dropouts']) + int(lines[-1]['audio']['underruns']) - int(lines[0]['audio']['underruns'])
    a1_off = disc.get("count") if probe is not None else None
    w(f"| A1 全程 | 超时 {int(lines[-1]['audio']['dropouts']) - int(lines[0]['audio']['dropouts'])} + 欠载 {int(lines[-1]['audio']['underruns']) - int(lines[0]['audio']['underruns'])}"
      f" + 离线不连续 {a1_off if a1_off is not None else '未测'}（frameprobe，click ±1 ms 排除）；流式不连续 {int(lines[-1]['audio'].get('discontinuities', 0)) - int(lines[0]['audio'].get('discontinuities', 0))}（信息项） | "
      f"{a.hours:g} 小时 0（硬性） | 0 | {'✅' if a1_stream == 0 and not a1_off else '❌'} | — |")
    e1_total = sum(o["skipped"] for o in outputs)
    w(f"| E1 全程 | " + "，".join(f"encoder[{o['index']}] {o['skipped']}" for o in outputs) + f"（共 {e1_total}） | 标准负载下 0 | 0 | {'✅' if e1_total == 0 else '❌'} | — |")
    s2_txt = "—" if s2.get("slope_mb_per_h") is None else f"{s2['slope_mb_per_h']:.2f} MB/h（{'预热 30 min 后' if s2['after_warmup'] else '整段'}逐分钟 {s2['samples']} 点、拟合 {s2.get('fit_span_s', 0) / 3600:.2f} h，R² {f(s2.get('r2'), 3)}；RSS {f(s2.get('rss_first_mb'), 0)} → {f(s2.get('rss_last_mb'), 0)} MB，最大 {f(s2.get('rss_max_mb'), 0)}）"
    if s2_ps and s2_ps.get("slope_mb_per_h") is not None:
        s2_txt += f"；对照：ps 的 RSS（resident）{s2_ps['slope_mb_per_h']:.2f} MB/h"
    w(f"| S2 内存增长 | {s2_txt} | ≤ 10 MB/h | ≤ 2 MB/h | {'✅' if s2['verdict'] == 'pass' else ('❌' if s2['verdict'] == 'fail' else ('⚠️ 参考值已超 10 MB/h（拟合段不足 1 h，不判；8 小时那次判）' if (s2.get('slope_mb_per_h') or 0) > sj.S2_MUST_MB_H else '参考（拟合段不足 1 h，只作参考）'))}{' 达目标' if s2['verdict'] == 'pass' and s2.get('meets_target') else ''} | {delta('s2_mb_per_h', 2, ' MB/h')} |")
    pm_txt = (f"；powermetrics GPU avg {f(pm.get('pm_gpu_active_avg_pct'), 1)}% / p95 {f(pm.get('pm_gpu_active_p95_pct'), 1)}%，GPU 频率均值 {f(pm.get('pm_gpu_freq_avg_mhz'), 0)} MHz（最低 {f(pm.get('pm_gpu_freq_min_mhz'), 0)}）"
              if pm and "pm_gpu_active_avg_pct" in pm else "；powermetrics 未采（无 sudo）")
    thr_txt = f"；按线程见 §5（首尾快照跨 {threads['wall_s'] / 3600:.2f} h，各线程之和 {threads['total_pct']:.1f}%）" if threads else "；没有 threads.log，不按线程归因"
    w(f"| S3 CPU | avg {f(perf['cpu_avg_pct'], 1)}% / p95 {f(perf['cpu_p95_pct'], 1)}% / max {f(perf['cpu_max_pct'], 1)}%（进程级，100 = 一个核{thr_txt}） | avg ≤ 60% | ≤ 40% | {'✅' if s3.get('cpu_pass') else '❌'}{' 达目标' if s3.get('cpu_meets_target') else ''} | {delta('cpu_avg_pct', 1, ' pt')} |")
    w(f"| S3 GPU | avg {f(perf['gpu_avg_pct'], 1)}% / p95 {f(perf['gpu_p95_pct'], 1)}%（IOKit Device Utilization）{pm_txt} | avg ≤ 50% | ≤ 35% | {'✅' if s3.get('gpu_pass') else '❌'}{' 达目标' if s3.get('gpu_meets_target') else ''} | {delta('gpu_avg_pct', 1, ' pt')} |")
    if pm.get("pm_cores"):
        # cpu_pct 的 60% = 进程各线程合计 0.6 个核，不是某个核 60%；这一行用 powermetrics 的每核忙时比（整机、含别的进程）直接回答"有没有一个核在受累"
        by_cluster = {}
        for c in pm["pm_cores"]:
            by_cluster.setdefault(c["cluster"], []).append(c)
        cl_txt = "；".join(f"{name} {len(cs)} 核合计忙 {sum(c['busy_avg_pct'] for c in cs) / 100:.2f} 核、均频 {sum((c['freq_avg_mhz'] or 0) for c in cs) / len(cs):.0f} MHz"
                          for name, cs in by_cluster.items())
        w(f"| S3 按核（整机、含别的进程；powermetrics 每核 1 − idle − down；信息项） | {len(pm['pm_cores'])} 核合计忙碌 {pm['pm_busy_cores_avg']:.2f} 个核；任一时刻最忙的核均值 {pm['pm_hottest_core_avg_pct']:.0f}% / p95 {pm['pm_hottest_core_p95_pct']:.0f}%；{cl_txt}（每核见 §5） | — | — | 信息 | — |")
    if a3.get("drift_ms") is not None:
        w(f"| A3 A/V 漂移 | {a3['drift_ms']:+.2f} ms（整秒配对 {a3['pairs']} 对、跨 {a3['span_s'] / 3600:.2f} h，斜率 {a3['slope_ms_per_s'] * 1000:.4f} µs/s{'；' + a3['note'] if a3.get('note') else ''}） | "
          f"8 小时 ≤ 16 ms | ≤ 5 ms | {'✅' if a3['pass'] else '❌'}{' 达目标' if a3.get('meets_target') else ''} | {delta('a3_drift_ms', 2, ' ms')} |")
        w(f"| A2（信息项） | 整秒配对最大 {f(a3.get('a2_max_abs_ms'))} ms、均值 {f(a3.get('a2_mean_ms'))} ms、标准差 {f(a3.get('a2_std_ms'))} ms | ≤ 16.7 ms | ≤ 5 ms | {'✅' if a3.get('pass_a2') else '❌' if a3.get('pass_a2') is False else '—'} | — |")
    else:
        w(f"| A3 A/V 漂移 | 未判：{a3.get('note')} | 8 小时 ≤ 16 ms | ≤ 5 ms | — | — |")
    w(f"| V1（信息项） | avg {f(perf['v1_avg_ms'])} ms / p99 {f(perf['v1_p99_ms'])} ms / max {f(perf['v1_max_ms'])} ms | avg ≤ 6, p99 ≤ 12 | avg ≤ 4, p99 ≤ 8 | {'✅' if perf['v1_avg_ms'] <= 6 and perf['v1_p99_ms'] <= 12 else '❌'} | {delta('v1_avg_ms', 3, ' ms')} |")
    w(f"| V3（信息项） | p99 {f(perf['v3_p99_ms'])} ms / max {f(perf['v3_max_ms'])} ms | p99 ≤ 4 | p99 ≤ 2 | {'✅' if perf['v3_p99_ms'] <= 4 else '❌'} | {delta('v3_p99_ms', 3, ' ms')} |")
    vs = [s for s in ffp.get("streams", []) if s.get("codec_type") == "video"]
    if vs:
        nb = int(vs[0].get("nb_read_packets") or 0)
        exp_frames = int(round(float(run.get("duration_s") or 0) * fps))
        au = [s for s in ffp.get("streams", []) if s.get("codec_type") == "audio"]
        vdur, adur = float(vs[0].get("duration") or 0), float(au[0].get("duration") or 0) if au else None
        w(f"| V5 / E5（信息项） | 录像 {nb} 帧 / 期望 {exp_frames}（差 {nb - exp_frames:+d}）；视频 {vdur:.3f} s、音频 {f(adur)} s（差 {f((adur - vdur) * 1000 if adur is not None else None, 1)} ms）；ffprobe 解析错误：{'无' if not ff_err else ff_err[:200]} | "
          f"1 小时 ≤ 2 帧；轨道差 ≤ 20 ms | 0 | {'✅' if abs(nb - exp_frames) <= max(2, 2 * a.hours) and not ff_err and (adur is None or abs(adur - vdur) <= 0.020) else '❌'} | — |")
    w("")

    w("## 4. 每 5 分钟窗口（只列超阈值的；全表在 summary.json）\n")
    if bad_w:
        w("| 窗口 | 时间 | 拍数 | V2 | A1（超时 + 欠载 + 离线） | E1 | 各编码器 skipped |\n|---|---|---|---|---|---|---|")
        for x in bad_w[:200]:
            w(f"| {x['index']} | {hms(x['start_ts'])}–{hms(x['end_ts'])} | {x['ticks']} | {x['missed']}{' ❌' if not x['v2_ok'] else ''} | "
              f"{x['dropouts']} + {x['underruns']} + {x.get('offline_discontinuities', 0)}{' ❌' if not x['a1_ok'] else ''} | {x['skipped']}{' ❌' if not x['e1_ok'] else ''} | {x['skipped_by_encoder']} |")
        if len(bad_w) > 200:
            w(f"\n（还有 {len(bad_w) - 200} 个，见 summary.json）")
    else:
        w(f"{len(judged)} 个窗口全部满足（V2 最大 {max(x['missed'] for x in judged)} 帧 / 窗口，A1 0，E1 0）。")
    w("")

    w("## 5. 输出与输入\n")
    w("| encoder | 输出 | 帧数 | 丢（网络 / 落盘） | 编码 skipped | 重连 | 状态（秒数） | 平均码率 |\n|---|---|---|---|---|---|---|---|")
    for o in outputs:
        w(f"| {o['index']} | {out_names.get(o['output'], o['output'])} | {o['frames']} | {o['dropped']} | {o['skipped']} | {o['reconnects']} | "
          f"{'、'.join(f'{k} {v}' for k, v in o['states'].items())} | {o['bitrate_avg'] / 1e6:.2f} Mb/s |")
    if mtx:
        w("")
        w("MediaMTX 收到的（每分钟采 API）：" + "；".join(f"{k} 平均 {v['mbps_avg']:.2f} Mb/s，运行中没进字节的分钟 {v['stalled_minutes']}、未就绪 {v['not_ready_in_run']} 次" for k, v in sorted(mtx.items())))
    w("")
    w("| 输入 | 名字 | fps 均值 / 最低 | fps = 0 的秒数 | 重复 dup | 丢弃 drop | L1 最大 |\n|---|---|---|---|---|---|---|")
    for n, v in inputs.items():
        w(f"| {n} | {in_names.get(n, '')} | {v['fps_avg']:.2f} / {v['fps_min']:.2f} | {v['zero_seconds']} | {v['dup']} | {v['drop']} | {v['latency_max_ms']:.1f} ms |")
    w("")
    if threads:
        w(f"S3 按线程（threads.log 首尾快照 {datetime.datetime.fromtimestamp(threads['first_ts']).strftime('%H:%M:%S')} → "
          f"{datetime.datetime.fromtimestamp(threads['last_ts']).strftime('%H:%M:%S')}，每线程 user + system 增量 / 墙钟；同 cpu_pct 的口径，100 = 一个核；"
          f"按线程名分组，共 {threads['groups']} 组，列前 {len(threads['rows'])}；无名线程 = VideoToolbox / AVFoundation / NDI SDK / HaishinKit / GCD 的工作线程）：\n")
        w("| 线程（组） | 线程数 | CPU 秒 | 占一个核 % |\n|---|---|---|---|")
        for r in threads["rows"]:
            w(f"| `{r['name']}` | {r['threads']} | {r['cpu_s']:.0f} | {r['pct']:.1f}% |")
        w(f"| **合计** | | | **{threads['total_pct']:.1f}%** |")
        w("")

    if pm.get("pm_cores"):
        w("S3 按核（powermetrics 每个核的忙时比 = 1 − idle − down，整机口径、含别的进程；进程的 cpu_pct 是各线程之和、按上面的线程表分摊在这些核上）：\n")
        w("| 核 | 簇 | 忙时比均值 | p95 | 平均频率 |\n|---|---|---|---|---|")
        for c in pm["pm_cores"]:
            w(f"| cpu{c['cpu']} | {c['cluster']} | {c['busy_avg_pct']:.1f}% | {c['busy_p95_pct']:.1f}% | {f(c['freq_avg_mhz'], 0)} MHz |")
        w("")

    w("## 6. 异常与截取的日志（事件前后 5 分钟，重叠的并段）\n")
    if not evs:
        w("没有异常事件。\n")
    else:
        kinds = {}
        for e in evs:
            kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
        w("事件计数：" + "、".join(f"{k} {v}" for k, v in sorted(kinds.items())) + f"；并成 {len(ranges)} 段，截取 {len(excerpt_ranges)} 段 → `{show_path(anomalies_dir)}/`\n")
        w("| 段 | 时间 | 事件（前 6 条） |\n|---|---|---|")
        for n, r in enumerate(excerpt_ranges, 1):
            evtxt = "；".join(f"{hms(e['ts'])} {e['kind']}：{e['detail']}" for e in r["events"][:6]) + (f"；…共 {len(r['events'])} 条" if len(r["events"]) > 6 else "")
            w(f"| {n:02d} | {hms(r['start'])}–{hms(r['end'])} | {evtxt} |")
        w("")
    w("## 7. 数据存放\n")
    w(f"- stats：`{show_path(stats_path)}`；headless（带墙钟时间戳）：`{show_path(os.path.join(od, 'headless.log'))}`；录像：`{show_path(os.path.join(od, 'soak.mov'))}`")
    w(f"- 每分钟采样：`rss.log`、`env.log`、`mtx.log`，每 5 s：`load.log`；powermetrics：`powermetrics.plist`{'' if pm_all else '（没有）'}；MediaMTX 日志：`mediamtx.log`")
    if seg_count:
        w(f"- frameprobe：按 5 分钟分段 `probe-seg/seg*.json`（{seg_count} 段{('，缺 ' + str(len(seg_missing)) + ' 段：' + '、'.join(seg_missing[:10])) if seg_missing else ''}），合并结果 `probe-av-combined.json`；ffprobe：`ffprobe.json`、`ffprobe-errors.txt`")
    else:
        w(f"- frameprobe：`probe-av.json` / `probe-av.md`{'' if probe else '（没有）'}；ffprobe：`ffprobe.json`、`ffprobe-errors.txt`")
    w(f"- 崩溃报告：{('`' + show_path(crash_dir) + '/`：' + '、'.join(crashes)) if crashes else '无'}；Instruments（S2 的 Leaks）：scripts/soak/leaks.sh 单独跑，见 reports/W4-leaks.md")
    w("")
    w("## 8. 已知问题与放行说明\n")
    notes = []
    if tail:
        lt, lf = tail[-1], lines[-1]
        notes.append(f"停机段（最后一拍之后 {len(tail)} 行，{float(lt['ts']) - float(lf['ts']):.0f} s：录制封口、推流排空、音频引擎最后停）不进判定；"
                     f"这段里欠载 +{int(lt['audio']['underruns']) - int(lf['audio']['underruns'])}、超时 +{int(lt['audio']['dropouts']) - int(lf['audio']['dropouts'])}（信息）。")
    if busy_minutes:
        notes.append(f"{busy_minutes} 分钟里机器上有编译 / 测试进程在跑（env.log 的 busy 列）：落在这些分钟里的 V2 / V3 / S3 事件先看是不是被挤的。")
    if not pm_all:
        notes.append("powermetrics 没采（没有 sudo）：GPU 按 §3 S3 的正式口径（IOKit）判，频率 / thermal pressure 缺。")
    if s2["verdict"] == "reference":
        notes.append("S2 在这次运行里只作参考：预热 30 分钟之后的拟合段不足 1 小时（§3 S2 的判定用 8 小时那次）。")
    if threads is None:
        notes.append("S3 没按线程归因：没有 threads.log（这次运行的 soak.sh 还没有每分钟的 thread-cpu 快照，或 scripts/soak/thread-cpu.swift 没编译成功）。")
    if a3.get("extrapolated"):
        notes.append("A3 按整秒配对斜率外推到 8 小时（与 G3 / G4 的 10 分钟外推同口径）；正式值用 8 小时那次。")
    if run.get("camera_note"):
        notes.append(run["camera_note"])
    if seg_missing:
        notes.append(f"frameprobe 有 {len(seg_missing)} 段没出结果（probe-seg/failed.txt、probe.err）：这些段的 A2 配对与离线不连续没算进来。")
    if not notes:
        notes.append("无。")
    for n_ in notes:
        w(f"- {n_}")
    w("")
    os.makedirs(os.path.dirname(report) or ".", exist_ok=True)
    open(report, "w", encoding="utf-8").write("\n".join(out) + "\n")

    summary = {"label": a.label, "machine": machine, "macos": macos, "commit": env.get("commit"), "overall_pass": overall,
               "s1": s1, "s2": s2, "s2_ps": s2_ps, "s3": s3, "a3": a3, "perf": perf, "powermetrics": pm, "threads": threads,
               "outputs": outputs, "inputs": inputs, "mtx": mtx,
               "key": cur_key, "windows": judged, "events": evs, "ranges": [{k: v for k, v in r.items() if k != "events"} | {"events": len(r["events"])} for r in ranges]}
    json.dump(summary, open(os.path.join(od, "summary.json"), "w"), ensure_ascii=False, indent=1, default=str)
    # 第一版基线只在标准时长（make soak / soak-1h 的 8h / 1h 标签）且通过时自动写；其余（冒烟、临时标签）要 --write-baseline
    if a.write_baseline or (not base and overall and a.label in ("8h", "1h")):
        os.makedirs(a.baseline_dir, exist_ok=True)
        json.dump({"checkpoint": f"W4-A-soak{a.label}", "machine": machine, "commit": env.get("commit"), "date": datetime.datetime.now().isoformat(timespec="seconds"),
                   "notes": {"macos": macos, "power": env.get("power", ""), "camera": run.get("camera", ""), "streams": run.get("streams", ""), "ndi": run.get("ndi", "")},
                   "key": cur_key, "s2": s2, "a3": a3}, open(bpath, "w", encoding="utf-8"), ensure_ascii=False, indent=1, sort_keys=True, default=str)
        print(f"基线写入 {bpath}")
    print(f"报告：{report}")
    return 0 if overall else 1


if __name__ == "__main__":
    sys.exit(main())
