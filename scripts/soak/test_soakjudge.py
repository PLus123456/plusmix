#!/usr/bin/env python3
"""scripts/soak/soakjudge.py 的用例（W4-A；测试 ID 进函数名）。跑法：python3 -B -m unittest discover -s scripts/soak -p 'test_*.py'"""
import os
import sys
import unittest

sys.dont_write_bytecode = True   # 不在 scripts/ 下留 __pycache__（.gitignore 不归 W4-A）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import soakjudge as sj  # noqa: E402

T0 = 1_790_000_000.0


def line(i, missed=0, dropouts=0, underruns=0, skipped=(0, 0, 0, 0), dropped=(0, 0, 0, 0), reconnects=(0, 0, 0, 0),
         states=("recording", "publishing", "publishing", "publishing"), rss=800.0, jitter=0.05, render=2.0, fps=None, ts=None, tick=None):
    """第 i 秒的一行（60 fps：tick = 60 i）。encoder 按 soak 的顺序：录制、推流 1、推流 2、NDI。"""
    enc = [{"output": n, "skipped": s, "bitrate": 6e6, "frames": 60 * i, "dropped": d, "disk_free_mb": 1e6, "reconnects": r,
            "connections": 0, "state": st} for n, s, d, r, st in zip((1, 3, 4, 5), skipped, dropped, reconnects, states)]
    return {"ts": T0 + i if ts is None else ts, "tick": 60 * i if tick is None else tick, "render_ms": render, "missed_render": missed,
            "jitter_ms": jitter, "per_input": {"10": {"fps": 30.0 if fps is None else fps, "dup": 0, "drop": 0}},
            "encoder": enc, "display": [], "audio": {"dropouts": dropouts, "underruns": underruns, "discontinuities": 0},
            "rss_mb": rss, "cpu_pct": 50.0, "gpu_pct": 30.0}


class WindowTests(unittest.TestCase):
    def test_S1_windowsAreFiveMinutesAndUseCumulativeDeltas(self):
        lines = [line(i, missed=(2 if i >= 400 else 0)) for i in range(0, 1201)]
        ws = sj.windows(lines, 300)
        self.assertEqual(len(ws), 4)
        self.assertEqual([w["ticks"] for w in ws], [18000, 18000, 18000, 18000])
        self.assertEqual([w["missed"] for w in ws], [0, 2, 0, 0], "增量只记在它发生的那个窗口")

    def test_S1_windowV2OverThresholdFails(self):
        # 必须档 0.02%：18000 拍的窗口里 3 帧（0.0167%）过、4 帧（0.0222%）不过
        ok = sj.judge_window({"ticks": 18000, "missed": 3, "dropouts": 0, "underruns": 0, "skipped": 0})
        bad = sj.judge_window({"ticks": 18000, "missed": 4, "dropouts": 0, "underruns": 0, "skipped": 0})
        self.assertTrue(ok["v2_ok"])
        self.assertFalse(bad["v2_ok"])
        self.assertFalse(bad["ok"])

    def test_S1_windowA1AnyDropoutOrUnderrunFails(self):
        self.assertFalse(sj.judge_window({"ticks": 18000, "missed": 0, "dropouts": 1, "underruns": 0, "skipped": 0})["a1_ok"])
        self.assertFalse(sj.judge_window({"ticks": 18000, "missed": 0, "dropouts": 0, "underruns": 1, "skipped": 0})["a1_ok"])
        self.assertFalse(sj.judge_window({"ticks": 18000, "missed": 0, "dropouts": 0, "underruns": 0, "skipped": 0,
                                          "offline_discontinuities": 1})["a1_ok"], "离线不连续（frameprobe）也算 A1")

    def test_S1_windowE1SumsAllEncoders(self):
        lines = [line(i, skipped=(0, 0, 1 if i >= 10 else 0, 0)) for i in range(0, 301)]
        ws = sj.windows(lines, 300)
        self.assertEqual(ws[0]["skipped"], 1)
        self.assertFalse(sj.judge_window(ws[0])["e1_ok"])

    def test_S1_lastPartialWindowJudgedOnItsOwnTicks(self):
        lines = [line(i, missed=(1 if i >= 350 else 0)) for i in range(0, 361)]
        ws = sj.windows(lines, 300)
        self.assertEqual(ws[-1]["ticks"], 3600)
        self.assertAlmostEqual(ws[-1]["missed"] / ws[-1]["ticks"], 1 / 3600)
        self.assertFalse(sj.judge_window(ws[-1])["v2_ok"], "60 s 的尾巴窗口里 1 帧 = 0.028% > 0.02%")

    def test_S1_runSegmentEndsAtFirstLineWithFinalTick(self):
        # 最后一拍之后引擎停了、各路在收尾（录制封口、推流排空），tick 不再走：这些行是停机段，不进窗口判定
        lines = [line(i) for i in range(0, 181)] + [line(180 + k, tick=10800, underruns=100 * k) for k in range(1, 9)]
        run, tail = sj.run_segment(lines)
        self.assertEqual(len(run), 181)
        self.assertEqual(run[-1]["tick"], 10800)
        self.assertEqual(len(tail), 8)
        self.assertTrue(all(sj.judge_window(w)["a1_ok"] for w in sj.windows(run, 300)))

    def test_S1_tickStallInsideRunIsAnEvent(self):
        lines = [line(i) for i in range(0, 60)]
        for i in range(20, 26):
            lines[i]["tick"] = lines[19]["tick"]          # 引擎卡了 6 s
        for i in range(26, 60):
            lines[i]["tick"] = 60 * i
        ev = [e for e in sj.events(lines) if e["kind"] == "tick_stall"]
        self.assertEqual(len(ev), 1)

    def test_S1_offlineDiscontinuitiesMapToWindowByTick(self):
        lines = [line(i) for i in range(0, 901)]
        ws = sj.windows(lines, 300)
        sj.attach_offline_discontinuities(ws, [{"timeSeconds": 450.0}, {"timeSeconds": 899.5}], fps=60, start_tick=0)
        self.assertEqual([w.get("offline_discontinuities", 0) for w in ws], [0, 1, 1])


class EventTests(unittest.TestCase):
    def test_S1_eventsForMissedDropoutSkipReconnectStateAndGap(self):
        lines = [line(i) for i in range(0, 100)]
        lines[10] = line(10, missed=1)
        for i in range(11, 100):
            lines[i]["missed_render"] = 1
        lines[20]["audio"]["underruns"] = 2
        for i in range(21, 100):
            lines[i]["audio"]["underruns"] = 2
        lines[30]["encoder"][1]["reconnects"] = 1
        lines[30]["encoder"][1]["state"] = "backoff"
        for i in range(31, 100):
            lines[i]["encoder"][1]["reconnects"] = 1
        del lines[50:55]                         # stats 断了 6 s
        kinds = [e["kind"] for e in sj.events(lines)]
        self.assertIn("missed_render", kinds)
        self.assertIn("audio_underruns", kinds)
        self.assertIn("encoder_reconnects", kinds)
        self.assertIn("encoder_state", kinds)
        self.assertIn("stats_gap", kinds)
        self.assertEqual(kinds.count("missed_render"), 1, "累计值不变的后续行不重复报")

    def test_S1_inputFpsStallIsAnEvent(self):
        lines = [line(i, fps=(0.0 if 40 <= i < 60 else 30.0)) for i in range(0, 100)]
        ev = [e for e in sj.events(lines) if e["kind"] == "input_stalled"]
        self.assertEqual(len(ev), 1)
        self.assertIn("10", ev[0]["detail"])

    def test_S1_rangesMergeWithinFiveMinutes(self):
        evs = [{"ts": T0 + 1000, "kind": "a", "detail": ""}, {"ts": T0 + 1200, "kind": "b", "detail": ""},
               {"ts": T0 + 5000, "kind": "c", "detail": ""}]
        rs = sj.merge_ranges(evs, before=300, after=300)
        self.assertEqual(len(rs), 2)
        self.assertEqual(rs[0]["start"], T0 + 700)
        self.assertEqual(rs[0]["end"], T0 + 1500)
        self.assertEqual([e["kind"] for e in rs[0]["events"]], ["a", "b"])

    def test_S1_crashOrShortRunFailsS1(self):
        lines = [line(i) for i in range(0, 601)]
        ws = [sj.judge_window(w) for w in sj.windows(lines, 300)]
        self.assertTrue(sj.s1_verdict(ws, exit_code=0, expected_s=600, covered_s=600, crash_reports=[])["pass"])
        self.assertFalse(sj.s1_verdict(ws, exit_code=134, expected_s=600, covered_s=600, crash_reports=[])["pass"])
        self.assertFalse(sj.s1_verdict(ws, exit_code=0, expected_s=28800, covered_s=600, crash_reports=[])["pass"], "只跑了 10 分钟就停了")
        self.assertFalse(sj.s1_verdict(ws, exit_code=0, expected_s=600, covered_s=600, crash_reports=["x.ips"])["pass"])


class S2Tests(unittest.TestCase):
    def test_S2_perMinuteSamplesTakeFirstLineOfEachMinute(self):
        lines = [line(i, rss=800 + i) for i in range(0, 181)]
        pm = sj.per_minute(lines, "rss_mb")
        self.assertEqual([round(v) for _, v in pm], [800, 860, 920, 980])

    def test_S2_slopeFitAfterThirtyMinuteWarmup(self):
        # 前 30 min 从 700 涨到 850（预热），之后每小时 +1 MB：拟合只看预热之后 → ≈ 1 MB/h
        lines = []
        for i in range(0, 4 * 3600 + 1, 10):
            rss = 700 + 150 * min(i, 1800) / 1800 + (max(0, i - 1800) / 3600.0)
            lines.append(line(i, rss=rss))
        s2 = sj.s2_fit(sj.per_minute(lines, "rss_mb"), warmup_s=1800)
        self.assertAlmostEqual(s2["slope_mb_per_h"], 1.0, places=2)
        self.assertTrue(s2["after_warmup"])
        self.assertEqual(s2["verdict"], "pass")

    def test_S2_shortRunIsReferenceOnly(self):
        lines = [line(i, rss=800 + i / 60) for i in range(0, 1201)]      # 20 分钟：不够预热
        s2 = sj.s2_fit(sj.per_minute(lines, "rss_mb"), warmup_s=1800)
        self.assertFalse(s2["after_warmup"])
        self.assertEqual(s2["verdict"], "reference")

    def test_S2_leakOverTenMbPerHourFails(self):
        lines = [line(i, rss=800 + 12.0 * i / 3600) for i in range(0, 3 * 3600 + 1, 30)]
        s2 = sj.s2_fit(sj.per_minute(lines, "rss_mb"), warmup_s=1800, min_fit_s=3600)
        self.assertAlmostEqual(s2["slope_mb_per_h"], 12.0, places=3)
        self.assertEqual(s2["verdict"], "fail")


class SegmentProbeTests(unittest.TestCase):
    """frameprobe 对整条长录像的内存随帧数线性涨（1 h 约 41 GB），soak 改成按 5 分钟切段逐段跑、再合并。"""
    def seg(self, pairs, clicks=300, discs=()):
        return {"av": {"pairs": [{"flashTimeSeconds": t, "offsetMs": o, "onSecondTick": on, "tick": 0} for t, o, on in pairs],
                       "flashCount": len(pairs), "clickCount": clicks, "matchedCount": sum(1 for _, o, _ in pairs if o is not None),
                       "offSecondCount": sum(1 for _, o, on in pairs if o is not None and not on)},
                "discontinuities": {"count": len(discs), "events": [{"timeSeconds": t, "jump": 0.6} for t in discs]}}

    def test_A3_segmentsCombineOnAbsoluteTimeline(self):
        # 两段：第 0 段偏移 0，第 1 段（300 s 起）偏移 1 ms → 斜率 = 1 ms / 300 s；非整秒配对不进拟合
        s0 = self.seg([(1.0, 0.0, True), (2.0, 0.0, True), (2.5, -40.0, False)])
        s1 = self.seg([(1.0, 1.0, True), (2.0, 1.0, True)], discs=(10.0,))
        c = sj.combine_segment_probes([(0.0, s0), (300.0, s1)])
        on = c["av"]["onSecond"]
        self.assertEqual(on["count"], 4)
        self.assertAlmostEqual(on["spanSeconds"], 301.0)
        self.assertAlmostEqual(on["meanMs"], 0.5)
        self.assertAlmostEqual(on["maxAbsMs"], 1.0)
        self.assertGreater(on["slopeMsPerSecond"], 0)
        self.assertAlmostEqual(on["driftOverSpanMs"], on["slopeMsPerSecond"] * 301.0)
        self.assertEqual(c["av"]["offSecondCount"], 1)
        self.assertEqual(c["av"]["passA2"], True)
        self.assertEqual(c["discontinuities"]["count"], 1)
        self.assertAlmostEqual(c["discontinuities"]["events"][0]["timeSeconds"], 310.0, msg="不连续的时刻换回整条录像的时间轴")
        self.assertEqual(c["segments"], 2)

    def test_A3_combinedProbeFeedsSameJudgement(self):
        s0 = self.seg([(float(t), 0.0, True) for t in range(1, 300)])
        s1 = self.seg([(float(t), 0.0, True) for t in range(1, 300)])
        c = sj.combine_segment_probes([(0.0, s0), (28500.0, s1)])
        a3 = sj.a3_from_probe(c, hours=8)
        self.assertFalse(a3["extrapolated"], "两段跨满 8 小时：直接用斜率 × 首尾间隔")
        self.assertAlmostEqual(a3["drift_ms"], 0.0)
        self.assertTrue(a3["pass"])

    def test_A2_segmentOverThresholdFailsPassA2(self):
        c = sj.combine_segment_probes([(0.0, self.seg([(1.0, 20.0, True)]))])
        self.assertEqual(c["av"]["passA2"], False)


class A3Tests(unittest.TestCase):
    def av(self, drift, span, slope):
        return {"av": {"onSecond": {"count": 1000, "driftOverSpanMs": drift, "spanSeconds": span, "slopeMsPerSecond": slope,
                                    "maxAbsMs": 0.5, "meanMs": 0.1, "stdMs": 0.1}, "passA2": True}}

    def test_A3_eightHourDriftWithin16msPasses(self):
        a3 = sj.a3_from_probe(self.av(12.0, 28790, 12.0 / 28790), hours=8)
        self.assertAlmostEqual(a3["drift_ms"], 12.0)
        self.assertFalse(a3["extrapolated"])
        self.assertTrue(a3["pass"])

    def test_A3_eightHourDriftOver16msFails(self):
        self.assertFalse(sj.a3_from_probe(self.av(-17.0, 28790, -17.0 / 28790), hours=8)["pass"], "按绝对值判")

    def test_A3_shortRunExtrapolatesSlopeToEightHours(self):
        a3 = sj.a3_from_probe(self.av(0.5, 3590, 0.001), hours=1)
        self.assertTrue(a3["extrapolated"])
        self.assertAlmostEqual(a3["drift_ms"], 0.001 * 8 * 3600)
        self.assertFalse(a3["pass"], "28.8 ms > 16 ms")

    def test_A3_missingProbeIsNotJudged(self):
        a3 = sj.a3_from_probe(None, hours=8)
        self.assertIsNone(a3["pass"])


if __name__ == "__main__":
    unittest.main()


class ShellLocaleTests(unittest.TestCase):
    def test_S1_shellScriptsBraceVariablesBeforeNonASCII(self):
        # macOS 的 /bin/bash 3.2 在 UTF-8 locale 下把 `$label（` 里"（"的首字节也算进变量名，set -u 下直接"未定义变量"退出
        # （2026-09-27 用户在终端里跑 make soak 就这么断在 env-snapshot.sh / make-e4-clip.sh；会话里的 Bash 没设 LANG，测不出来）。
        # 变量后面紧跟中文 / 全角标点一律写成 ${name}。
        import glob
        import re
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        bad = []
        for path in sorted(glob.glob(os.path.join(root, "soak", "*.sh")) + glob.glob(os.path.join(root, "perf", "*.sh"))):
            with open(path, "rb") as f:
                for n, line in enumerate(f, 1):
                    for m in re.finditer(rb"\$[A-Za-z_][A-Za-z0-9_]*(?=[\x80-\xff])", line):
                        bad.append(f"{os.path.relpath(path, root)}:{n}: {m.group().decode()}")
        self.assertEqual(bad, [], "变量后面紧跟非 ASCII 字符要写成 ${name}：\n" + "\n".join(bad))


class S3Tests(unittest.TestCase):
    """§4 S3 与 §5 L4：S3 是长稳的判定项之一（第一次 8 小时 CPU 60.1% 时总判定漏了它）。"""

    def test_S3_cpuAvgOverSixtyFails(self):
        s3 = sj.s3_verdict({"cpu_avg_pct": 60.1, "cpu_p95_pct": 62.7, "gpu_avg_pct": 25.8, "gpu_p95_pct": 28.0})
        self.assertFalse(s3["cpu_pass"]); self.assertTrue(s3["gpu_pass"]); self.assertFalse(s3["pass"])

    def test_S3_gpuAvgOverFiftyFails(self):
        s3 = sj.s3_verdict({"cpu_avg_pct": 30.0, "cpu_p95_pct": 35.0, "gpu_avg_pct": 50.5, "gpu_p95_pct": 60.0})
        self.assertTrue(s3["cpu_pass"]); self.assertFalse(s3["gpu_pass"]); self.assertFalse(s3["pass"])

    def test_S3_atMustBoundaryPassesAndTargetIsSeparate(self):
        s3 = sj.s3_verdict({"cpu_avg_pct": 60.0, "cpu_p95_pct": 65.0, "gpu_avg_pct": 50.0, "gpu_p95_pct": 55.0})
        self.assertTrue(s3["pass"]); self.assertFalse(s3["meets_target"])
        s3 = sj.s3_verdict({"cpu_avg_pct": 40.0, "cpu_p95_pct": 45.0, "gpu_avg_pct": 35.0, "gpu_p95_pct": 40.0})
        self.assertTrue(s3["pass"]); self.assertTrue(s3["meets_target"])

    def test_S3_missingCountersIsNotJudged(self):
        self.assertIsNone(sj.s3_verdict({})["pass"])

    def test_S3_overallVerdictFailsWhenOnlyS3Fails(self):
        s1 = {"pass": True}; s2_ok = {"verdict": "pass"}; a3_ok = {"pass": True}
        s3_bad = sj.s3_verdict({"cpu_avg_pct": 60.1, "cpu_p95_pct": 62.7, "gpu_avg_pct": 25.8, "gpu_p95_pct": 28.0})
        s3_ok = sj.s3_verdict({"cpu_avg_pct": 54.9, "cpu_p95_pct": 57.1, "gpu_avg_pct": 26.4, "gpu_p95_pct": 37.0})
        self.assertFalse(sj.overall_verdict(s1, s2_ok, s3_bad, a3_ok))
        self.assertTrue(sj.overall_verdict(s1, s2_ok, s3_ok, a3_ok))
        # 参考 / 判不了的项不算失败；S1 / S2 / A3 各自失败时也不过
        self.assertTrue(sj.overall_verdict(s1, {"verdict": "reference"}, {"pass": None}, {"pass": None}))
        self.assertFalse(sj.overall_verdict({"pass": False}, s2_ok, s3_ok, a3_ok))
        self.assertFalse(sj.overall_verdict(s1, {"verdict": "fail"}, s3_ok, a3_ok))
        self.assertFalse(sj.overall_verdict(s1, s2_ok, s3_ok, {"pass": False}))


class ThreadCPUTests(unittest.TestCase):
    """S3 归因：scripts/soak/thread-cpu.swift 的快照（tid<TAB>user_us<TAB>system_us<TAB>name）按首尾差算占核百分比。"""
    LOG = ("# ts=1000 pid=42 threads=3\n"
           "1\t1000000\t0\tswitcher.render\n"
           "2\t0\t500000\t\n"
           "3\t100000\t100000\tcom.apple.coremedia.sharedRootQueue.48\n"
           "# ts=1030 pid=42 threads=3\n"
           "1\t4000000\t0\tswitcher.render\n"
           "2\t0\t2000000\t\n"
           "3\t100000\t100000\tcom.apple.coremedia.sharedRootQueue.48\n"
           "# ts=1060 pid=42 threads=4\n"
           "1\t7000000\t0\tswitcher.render\n"
           "2\t0\t3500000\t\n"
           "3\t100000\t100000\tcom.apple.coremedia.sharedRootQueue.48\n"
           "5\t600000\t0\tcom.apple.coremedia.sharedRootQueue.49\n")

    def test_S3_threadLogParsesSnapshots(self):
        snaps = sj.parse_thread_log(self.LOG)
        self.assertEqual([s["ts"] for s in snaps], [1000.0, 1030.0, 1060.0])
        self.assertEqual(snaps[0]["threads"][1], (1000000, 0, "switcher.render"))
        self.assertEqual(snaps[0]["threads"][2][2], "")

    def test_S3_threadBreakdownUsesFirstAndLastSnapshotAndGroupsNames(self):
        b = sj.thread_cpu_breakdown(sj.parse_thread_log(self.LOG))
        self.assertEqual(b["wall_s"], 60.0)
        rows = {r["name"]: r for r in b["rows"]}
        self.assertAlmostEqual(rows["switcher.render"]["pct"], 10.0)                       # (7 − 1) s / 60 s
        self.assertAlmostEqual(rows["（无名：系统 / SDK / GCD 线程）"]["pct"], 5.0)           # 3.5 − 0.5
        # 两个 sharedRootQueue.NN 合成一组：旧的 0 增量 + 新出现的按累计 0.6 s
        self.assertEqual(rows["com.apple.coremedia.sharedRootQueue"]["threads"], 2)
        self.assertAlmostEqual(rows["com.apple.coremedia.sharedRootQueue"]["pct"], 1.0)
        self.assertAlmostEqual(b["total_pct"], 16.0)
        self.assertEqual(b["rows"][0]["name"], "switcher.render")

    def test_S3_threadBreakdownHonoursRunSegmentBounds(self):
        b = sj.thread_cpu_breakdown(sj.parse_thread_log(self.LOG), t_start=1000, t_end=1030)
        self.assertEqual(b["wall_s"], 30.0)
        self.assertAlmostEqual({r["name"]: r for r in b["rows"]}["switcher.render"]["pct"], 10.0)
        self.assertIsNone(sj.thread_cpu_breakdown(sj.parse_thread_log(self.LOG), t_start=1060, t_end=1060))
        self.assertIsNone(sj.thread_cpu_breakdown([]))
