#!/usr/bin/env python3
"""scripts/perf/perfjudge.py 的用例（W4-A；测试 ID 进函数名）。跑法：python3 -m unittest discover -s scripts/perf -p 'test_*.py'"""
import json
import os
import plistlib
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # 不在 scripts/ 下留 __pycache__（.gitignore 不归 W4-A）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perfjudge as pj  # noqa: E402


def stats_line(ts, tick, render=2.0, missed=0, jitter=0.05, cpu=50.0, gpu=30.0, rss=800.0, skipped=0):
    return {"ts": ts, "tick": tick, "render_ms": render, "missed_render": missed, "jitter_ms": jitter,
            "per_input": {}, "encoder": [{"output": 1, "skipped": skipped, "bitrate": 6e6, "frames": tick, "dropped": 0,
                                          "disk_free_mb": 1e6, "reconnects": 0, "connections": 0, "state": "recording"}],
            "display": [], "audio": {"dropouts": 0, "underruns": 0, "discontinuities": 0},
            "rss_mb": rss, "cpu_pct": cpu, "gpu_pct": gpu}


class PercentileTests(unittest.TestCase):
    def test_S3_percentileIsNearestRankLikeStatsSummary(self):
        values = list(range(1, 101))            # 1..100
        self.assertEqual(pj.percentile(values, 0.95), 95)
        self.assertEqual(pj.percentile(values, 0.99), 99)
        self.assertEqual(pj.percentile([5, 1, 3, 2, 4], 0.99), 5)   # N = 5 → 第 5 个（与 StatsSummary 的最近秩法相同）
        self.assertEqual(pj.percentile([], 0.95), 0)

    def test_S3_perfMetricsCpuGpuAverageAndP95(self):
        lines = [stats_line(1000 + i, 60 * i, cpu=float(i % 100), gpu=float(i % 50)) for i in range(301)]
        m = pj.perf_metrics(lines)
        self.assertAlmostEqual(m["cpu_avg_pct"], sum(i % 100 for i in range(301)) / 301)
        self.assertEqual(m["cpu_p95_pct"], pj.percentile([float(i % 100) for i in range(301)], 0.95))
        self.assertEqual(m["gpu_p95_pct"], pj.percentile([float(i % 50) for i in range(301)], 0.95))

    def test_V2_ratioUsesTickSpanAndCumulativeDelta(self):
        lines = [stats_line(1000 + i, 60 * i, missed=(3 if i > 100 else 1)) for i in range(301)]
        m = pj.perf_metrics(lines)
        self.assertEqual(m["v2_missed"], 2)          # 末行 − 首行
        self.assertEqual(m["ticks"], 18000)
        self.assertAlmostEqual(m["v2_ratio"], 2 / 18000)

    def test_V1_V3_seriesMatchStatsSummaryDefinitions(self):
        lines = [stats_line(1000 + i, 60 * i, render=2.0 + (i % 10) / 10, jitter=0.01 * (i % 7)) for i in range(200)]
        m = pj.perf_metrics(lines)
        renders = [2.0 + (i % 10) / 10 for i in range(200)]
        self.assertAlmostEqual(m["v1_avg_ms"], sum(renders) / 200)
        self.assertEqual(m["v1_p99_ms"], pj.percentile(renders, 0.99))
        self.assertEqual(m["v3_p99_ms"], pj.percentile([0.01 * (i % 7) for i in range(200)], 0.99))
        self.assertAlmostEqual(m["v3_max_ms"], 0.06)


class RegressionTests(unittest.TestCase):
    def base(self, **kw):
        m = {"v1_avg_ms": 2.0, "v1_p99_ms": 2.5, "v2_ratio": 0.0, "v3_p99_ms": 0.1, "cpu_avg_pct": 50.0, "cpu_p95_pct": 60.0,
             "gpu_avg_pct": 30.0, "gpu_p95_pct": 35.0}
        m.update(kw)
        return m

    def test_L5_regressionOver10PercentFails(self):
        rows = pj.compare(self.base(v1_avg_ms=2.25), self.base(), pj.DEFAULT_RULES)
        row = next(r for r in rows if r["metric"] == "v1_avg_ms")
        self.assertTrue(row["regression"])
        self.assertAlmostEqual(row["delta_pct"], 12.5)

    def test_L5_within10PercentPasses(self):
        rows = pj.compare(self.base(v1_avg_ms=2.19, cpu_avg_pct=54.9), self.base(), pj.DEFAULT_RULES)
        self.assertFalse(any(r["regression"] for r in rows))

    def test_L5_improvementIsNeverRegression(self):
        rows = pj.compare(self.base(v1_avg_ms=1.0, gpu_avg_pct=10.0), self.base(), pj.DEFAULT_RULES)
        self.assertFalse(any(r["regression"] for r in rows))

    def test_L5_zeroBaselineCountFallsBackToMustThreshold(self):
        # V2 基线 0：比例算不出（0 → 任何数都是无穷大），按必须档（≤ 0.02%）判，并在 note 里写明
        ok = pj.compare(self.base(v2_ratio=1 / 18000), self.base(), pj.DEFAULT_RULES)
        row = next(r for r in ok if r["metric"] == "v2_ratio")
        self.assertFalse(row["regression"])
        self.assertIn("基线为 0", row["note"])
        bad = pj.compare(self.base(v2_ratio=5 / 18000), self.base(), pj.DEFAULT_RULES)
        self.assertTrue(next(r for r in bad if r["metric"] == "v2_ratio")["regression"])

    def test_L5_absoluteFloorFromConfigSuppressesTinyDeltas(self):
        # 用户可以在 scripts/perf/regression.json 给某项加绝对下限（默认没有）：+50% 但只多 0.05 ms、下限 0.1 ms → 不算退步
        rules = json.loads(json.dumps(pj.DEFAULT_RULES))
        rules["v3_p99_ms"]["floor"] = 0.1
        rows = pj.compare(self.base(v3_p99_ms=0.15), self.base(), rules)
        self.assertFalse(next(r for r in rows if r["metric"] == "v3_p99_ms")["regression"])
        rows = pj.compare(self.base(v3_p99_ms=0.15), self.base(), pj.DEFAULT_RULES)
        self.assertTrue(next(r for r in rows if r["metric"] == "v3_p99_ms")["regression"], "默认没有下限：+50% 就是退步")

    def test_L5_missingMetricOnEitherSideIsSkipped(self):
        rows = pj.compare({"v1_avg_ms": 2.0}, {"v1_avg_ms": 2.0, "pm_gpu_active_avg_pct": 30}, pj.DEFAULT_RULES)
        self.assertEqual([r["metric"] for r in rows], ["v1_avg_ms"])

    def test_E4_vmafDropOverOnePointIsRegression(self):
        rows = pj.compare({"e4_vmaf_mean": 88.9}, {"e4_vmaf_mean": 90.0}, pj.DEFAULT_RULES)
        self.assertTrue(rows[0]["regression"], "§4 E4：相对上一版本 VMAF 不降超过 1 分")
        rows = pj.compare({"e4_vmaf_mean": 89.1}, {"e4_vmaf_mean": 90.0}, pj.DEFAULT_RULES)
        self.assertFalse(rows[0]["regression"])

    def test_L5_baselineSelectionOnlySameMachineAndMacOSMajor(self):
        with tempfile.TemporaryDirectory() as d:
            for name, os_ver in [("perf-m5max-macos26.json", "26.6.2"), ("perf-m5max-macos27.json", "27.0")]:
                with open(os.path.join(d, name), "w") as f:
                    json.dump({"machine": "m5max", "notes": {"macos": os_ver}, "perf": {"v1_avg_ms": 2}}, f)
            self.assertEqual(os.path.basename(pj.baseline_path(d, "m5max", "27.0.1")), "perf-m5max-macos27.json")
            self.assertEqual(os.path.basename(pj.baseline_path(d, "m1air", "27.0")), "perf-m1air-macos27.json")
            self.assertEqual(pj.os_major("26.6.2"), "26")

    def test_L5_machineTag(self):
        self.assertEqual(pj.machine_tag("Apple M5 Max", "MacBook Pro"), "m5max")
        self.assertEqual(pj.machine_tag("Apple M1", "MacBook Air"), "m1air")
        self.assertEqual(pj.machine_tag("Apple M4 Pro", "Mac mini"), "m4pro")


class PowermetricsTests(unittest.TestCase):
    def sample(self, idle, freq_mhz, gpu_mw, pressure="Nominal"):
        return plistlib.dumps({"elapsed_ns": 1_000_000_000, "thermal_pressure": pressure,
                               "gpu": {"idle_ratio": idle, "freq_hz": freq_mhz * 1e6, "gpu_energy": gpu_mw},
                               "processor": {"cpu_power": 3000.0, "combined_power": 5000.0,
                                             "clusters": [{"name": "P0-Cluster", "freq_hz": 3.5e9, "idle_ratio": 0.8},
                                                          {"name": "E-Cluster", "freq_hz": 1.2e9, "idle_ratio": 0.6}]}})

    def test_S3_powermetricsPlistStreamGpuActiveRatio(self):
        blob = b"\0".join([self.sample(0.7, 800, 2000), self.sample(0.6, 900, 2500), self.sample(0.5, 1000, 3000, "Moderate")]) + b"\0"
        samples = pj.parse_powermetrics(blob)
        self.assertEqual(len(samples), 3)
        s = pj.powermetrics_summary(samples)
        self.assertAlmostEqual(s["pm_gpu_active_avg_pct"], 40.0)
        self.assertAlmostEqual(s["pm_gpu_active_p95_pct"], 50.0)
        self.assertAlmostEqual(s["pm_gpu_freq_avg_mhz"], 900.0)
        self.assertEqual(s["pm_thermal_pressure"], {"Nominal": 2, "Moderate": 1})
        self.assertIn("P0-Cluster", s["pm_cluster_freq_avg_mhz"])

    def test_S3_powermetricsTruncatedTailIsIgnored(self):
        blob = self.sample(0.7, 800, 2000) + b"\0" + self.sample(0.6, 900, 2500)[:40]
        self.assertEqual(len(pj.parse_powermetrics(blob)), 1)


class E4Tests(unittest.TestCase):
    def test_E4_alignmentFindsOffsetOfFirstSourceFrame(self):
        import math
        src = [100 + 40 * math.sin(i * 0.37) + (i % 13) for i in range(900)]
        rec = [16.0] * 7 + src + [src[-1]] * 30                 # 7 帧黑场（文件输入起播前），末尾停在末帧
        offset, cost = pj.align_offset(rec, src, max_offset=60)
        self.assertEqual(offset, 7)
        self.assertLess(cost, 1e-9)

    def test_E4_vmafSummaryPerSegment(self):
        frames = [{"frameNum": i, "metrics": {"vmaf": 90.0 if i < 600 else (80.0 if i < 1200 else 60.0),
                                              "psnr_y": 40.0, "float_ssim": 0.95}} for i in range(1800)]
        s = pj.vmaf_summary({"frames": frames}, [("static", 0, 600), ("slow", 600, 1200), ("high", 1200, 1800)])
        self.assertAlmostEqual(s["e4_vmaf_mean"], (90 + 80 + 60) / 3)
        self.assertAlmostEqual(s["segments"]["static"]["vmaf_mean"], 90.0)
        self.assertAlmostEqual(s["segments"]["high"]["vmaf_mean"], 60.0)
        self.assertAlmostEqual(s["e4_psnr_y_db"], 40.0)
        self.assertEqual(s["e4_vmaf_min"], 60.0)
        self.assertEqual(s["frames"], 1800)


if __name__ == "__main__":
    unittest.main()
