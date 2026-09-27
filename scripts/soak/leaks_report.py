#!/usr/bin/env python3
"""S2 的 Instruments Leaks 结果 → reports/W4-leaks.md（scripts/soak/leaks.sh 调；W4-A）。

xctrace export 的 XML：<trace-toc> 列出每个 run 的 data/table（schema 属性是表名）；按 --xpath 导出一张表得到 <node><schema>…</schema><row>…</row>…；
行里每个子元素是一列，重复的值只在第一次出现时带 id、之后写 ref="id"（要自己解引用），fmt 属性是人读的格式。
表名因 Xcode 版本而异：这里不写死，凡 schema 名里带 leak 的表都导出来、按列名猜"大小 / 地址 / 负责库 / 负责帧 / 类型"归类；
解析不出来的列原样列出，原始 XML 留在 out-dir（leaks-<schema>.xml）。
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET   # 输入是本机 xctrace export 的输出（不是外部来源）；标准库 expat 默认不解外部实体，不另引 defusedxml

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf"))
import perfjudge as pj  # noqa: E402

# 负责库 / 帧 → 归属会话（docs/OWNERSHIP.md；报告里"定位到归属会话"用）
OWNERS = [
    (r"SwitcherEngine", "W1-B（SwitcherEngine）"), (r"SwitcherRender", "W1-C / W3-B（SwitcherRender）"),
    (r"SwitcherContracts", "P 系列（SwitcherContracts）"), (r"SwitcherAudioIntegration|AudioEngine", "W2-E（SwitcherAudio Integration）"),
    (r"SwitcherAudio|CSwitcherAudioRT|AudioMixer", "W1-D（SwitcherAudio）"), (r"SwitcherStreaming|StreamOutput|HaishinKit", "W2-D（SwitcherStreaming / HaishinKit）"),
    (r"SwitcherNDISend|NDISender", "W2-D（SwitcherNDISend）"), (r"libndi|NDIlib", "NDI SDK（第三方）"),
    (r"SwitcherOutputs|Recorder|VideoEncoder|AudioEncoder", "W1-E（SwitcherOutputs）"), (r"SwitcherNDI\b|NDIInput", "W3-A（SwitcherNDI）"),
    (r"SwitcherInputs|FileInput|CameraInput|ImageInput", "W2-A（SwitcherInputs）"), (r"SwitcherTestKit|Synthetic", "W1-A（SwitcherTestKit）"),
    (r"SwitcherControl|CommandBus|APIServer", "W2-C（SwitcherControl）"), (r"switcher-headless|switcher_headless", "headless（G2–G4 / W4-A）"),
]


def owner_of(text):
    for pat, who in OWNERS:
        if re.search(pat, text or ""):
            return who
    return "系统库 / 未知（看负责帧）"


def export_table(trace, schema, out_path):
    xp = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    res = subprocess.run(["xctrace", "export", "--input", trace, "--xpath", xp], capture_output=True, timeout=1800)
    open(out_path, "wb").write(res.stdout)
    return res.returncode, res.stdout


def parse_rows(xml_bytes):
    """→ (列名列表, 行列表[{列: (文本, fmt)}])；解 id / ref。"""
    root = ET.fromstring(xml_bytes)
    ids = {}
    for el in root.iter():
        if "id" in el.attrib:
            ids[el.attrib["id"]] = el
    def value(el):
        if "ref" in el.attrib and el.attrib["ref"] in ids:
            el = ids[el.attrib["ref"]]
        text = (el.text or "").strip()
        fmt = el.attrib.get("fmt", "")
        if not text and len(el):
            # 复合值（回溯、库引用……）：取第一个带 fmt 或文本的后代
            for sub in el.iter():
                sub2 = ids.get(sub.attrib.get("ref"), sub)
                if sub2.attrib.get("fmt") or (sub2.text or "").strip():
                    return (sub2.text or "").strip(), sub2.attrib.get("fmt", "")
        return text, fmt
    cols, rows = [], []
    for schema in root.iter("schema"):
        for col in schema.iter("col"):
            m = col.find("mnemonic")
            if m is not None and m.text:
                cols.append(m.text)
        break
    for row in root.iter("row"):
        r = {}
        for child in row:
            r[child.tag] = value(child)
        rows.append(r)
    return cols, rows


def to_bytes(text, fmt):
    for s in (text, fmt):
        if not s:
            continue
        m = re.match(r"^\s*([0-9][0-9,.]*)\s*(bytes?|B|KB|KiB|MB|MiB|GB|GiB)?\s*$", s, re.I)
        if m:
            v = float(m.group(1).replace(",", ""))
            unit = (m.group(2) or "B").lower()
            mult = {"b": 1, "byte": 1, "bytes": 1, "kb": 1024, "kib": 1024, "mb": 1024 ** 2, "mib": 1024 ** 2, "gb": 1024 ** 3, "gib": 1024 ** 3}[unit]
            return v * mult
    return None


def summarize(cols, rows):
    def pick(*keys):
        for k in keys:
            for c in (rows[0].keys() if rows else cols):
                if k in c.lower():
                    return c
        return None
    size_c = pick("size", "bytes")
    addr_c = pick("address")
    lib_c = pick("responsible-library", "library", "image")
    frame_c = pick("responsible-frame", "frame", "caller", "symbol")
    type_c = pick("type", "category", "class")
    addrs = set()
    total = 0.0
    groups = {}
    def cell(r, c):
        """一格的人读值：有 fmt 用 fmt，否则用文本；没有这一列为空串。"""
        if not c or not r.get(c):
            return ""
        text, fmt = r[c]
        return fmt or text

    for r in rows:
        if addr_c and r.get(addr_c):
            addrs.add(cell(r, addr_c))
        b = to_bytes(*r[size_c]) if size_c and r.get(size_c) else None
        total += b or 0
        key = " · ".join(v for v in (cell(r, lib_c), cell(r, frame_c), cell(r, type_c)) if v) or "（没有负责库 / 帧列）"
        g = groups.setdefault(key, {"count": 0, "bytes": 0.0})
        g["count"] += 1
        g["bytes"] += b or 0
    top = sorted(groups.items(), key=lambda kv: (-kv[1]["bytes"], -kv[1]["count"]))[:25]
    return {"rows": len(rows), "unique_addresses": len(addrs) if addr_c else None, "total_bytes": total if size_c else None,
            "columns": list(rows[0].keys()) if rows else cols, "size_col": size_c, "lib_col": lib_c, "frame_col": frame_c, "type_col": type_c,
            "top": [{"key": k, **v, "owner": owner_of(k)} for k, v in top]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--report", default="reports/W4-leaks.md")
    ap.add_argument("--light", action="store_true")
    a = ap.parse_args()
    od = a.out_dir
    toc_path = os.path.join(od, "toc.xml")
    toc = ET.parse(toc_path).getroot()
    tables = []
    for run in toc.iter("run"):
        if run.attrib.get("number") != "1":
            continue
        for t in run.iter("table"):
            tables.append(dict(t.attrib))
    leak_tables = [t for t in tables if "leak" in t.get("schema", "").lower()]
    results = {}
    for t in leak_tables:
        schema = t["schema"]
        path = os.path.join(od, f"leaks-{re.sub(r'[^A-Za-z0-9_-]', '_', schema)}.xml")
        rc, blob = export_table(a.trace, schema, path)
        try:
            cols, rows = parse_rows(blob)
            results[schema] = summarize(cols, rows)
        except Exception as ex:  # noqa: BLE001 —— 版本差异导致的格式变化：留原始 XML、报告写明
            results[schema] = {"error": f"解析失败（{ex}），原始 XML：{path}", "rc": rc}
    env = {}
    if os.path.exists(os.path.join(od, "environment.txt")):
        env = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.join(od, "environment.txt"), encoding="utf-8") if "=" in l)
    lines, _ = pj.load_stats(os.path.join(od, "stats.jsonl")) if os.path.exists(os.path.join(od, "stats.jsonl")) else ([], 0)
    perf = pj.perf_metrics(lines) if lines else {}
    total_rows = sum(r.get("rows", 0) for r in results.values() if "rows" in r)
    out = [f"# W4-A S2 · Instruments Leaks（{a.minutes:g} 分钟，{'G4 场景' if a.light else 'soak 负载'}）\n",
           f"生成：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}。trace：`{a.trace}`（Instruments 打开可看回溯）；脚本：scripts/soak/leaks.sh → scripts/soak/leaks_report.py。\n",
           f"**结果：Leaks 表 {len(leak_tables)} 张、共 {total_rows} 行**" + ("（没有找到 leak 表：看 toc.xml 里的表名，可能模板 / 版本不同）" if not leak_tables else "") + "\n",
           "Leaks 模板会周期性挂起进程扫堆，这一趟的 V2 / A1 / V3 不作数；S2 的斜率以 make soak 为准，这里是找泄漏源的证据。\n",
           "## 环境\n",
           f"- {env.get('chip', '?')} · {env.get('model', '?')} · macOS {env.get('macos', '?')}；提交 `{env.get('commit', '?')}`；电源 {env.get('power', '?')}"]
    if perf:
        out.append(f"- 这一趟 stats：{perf['lines']} 行，RSS {perf['rss_min_mb']:.0f} → {perf['rss_max_mb']:.0f} MB（最大）；V2 {perf['v2_missed']}（Leaks 挂起导致，不判）")
    out.append("")
    for schema, r in results.items():
        out.append(f"## 表 `{schema}`\n")
        if "error" in r:
            out.append(f"- {r['error']}\n")
            continue
        tb = r.get("total_bytes")
        out.append(f"- 行数 {r['rows']}；不同地址 {r.get('unique_addresses', '—')}；字节合计 {('%.1f KB' % (tb / 1024)) if tb is not None else '—（没有大小列）'}")
        out.append(f"- 列：{', '.join(r['columns'])}（大小列 {r['size_col']}，库 {r['lib_col']}，帧 {r['frame_col']}，类型 {r['type_col']}）\n")
        if r["top"]:
            out.append("| 负责库 · 帧 · 类型 | 块数 | 字节 | 归属 |\n|---|---|---|---|")
            for t in r["top"]:
                out.append(f"| {t['key'][:160]} | {t['count']} | {t['bytes']:.0f} | {t['owner']} |")
            out.append("")
    out.append("## 全部表（run 1）\n")
    out.append(", ".join(sorted({t.get('schema', '?') for t in tables})) or "（空）")
    out.append("")
    os.makedirs(os.path.dirname(a.report) or ".", exist_ok=True)
    open(a.report, "w", encoding="utf-8").write("\n".join(out) + "\n")
    json.dump({"tables": tables, "results": results}, open(os.path.join(od, "leaks-summary.json"), "w"), ensure_ascii=False, indent=1)
    print(f"报告：{a.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
