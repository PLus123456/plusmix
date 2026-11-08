#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成"导播台落地方案"网页（用户从上面复制每个会话的 prompt）：docs/plan/prompts/*.md → 每个会话一张卡片，
"复制 前言 + 本段"把 00 通用前言拼在前面。卡片上的状态标签按仓库里分支的状态自动算：
  分支已在 main → 已合入 main；在某个检查点分支上（标题以 G 开头的会话的分支：g2-m0 / g3 / g4 / release/0.1 / g6 …）→ 已合入 <检查点>，等合 main；
  分支存在且有 reports/<分支>.md → 完成未合并；分支存在 → 进行中；分支不存在 → 未开始；没有分支的（01 环境清单）→ 人工。
用法：scripts/gen-prompt-page.py [--out PATH]（默认 .build/prompt-page.html）[--template scripts/prompt-page/template.html]
     然后用 Artifact 工具把 --out 的文件发布到原网页（同一个 URL 原地更新）。模板是原网页去掉卡片后的壳（方案正文 + 样式 + 复制脚本），
     里面四个占位：{{STATS}}（顶部数字）、{{STATUS}}（进度提示）、{{LIB}}（卡片）、{{GENERATED}}（生成时间 / 提交）。
"""
import argparse, datetime, glob, html, os, re, subprocess

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

def git(*args):
    r = subprocess.run(["git", "-c", "core.quotePath=false", *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()

def branch_exists(b):
    return git("rev-parse", "--verify", "--quiet", f"refs/heads/{b}")[0] == 0

def is_ancestor(a, b):
    return git("merge-base", "--is-ancestor", a, b)[0] == 0

def has_report(b):
    return git("cat-file", "-e", f"{b}:reports/{b.replace('/', '-')}.md")[0] == 0

def parse(path):
    text = open(path, encoding="utf-8").read().rstrip("\n")
    lines = text.split("\n")
    m = re.match(r"^##\s+(\d+)\s+(.*)$", lines[0])
    number, title = int(m.group(1)), m.group(2).strip()
    branch = None
    for l in lines[1:4]:
        mb = re.search(r"分支：`?([A-Za-z0-9._/-]+)", l)
        if mb:
            branch = mb.group(1)
            break
    return dict(number=number, title=title, branch=branch, text=text, file=os.path.basename(path))

def status(p, gates):
    b = p["branch"]
    if b is None:
        return ("人工" + ("（已完成）" if "你自己做" in p["title"] else ""), "done")
    if b == "main":
        return ("已在 main", "done")
    if not branch_exists(b):
        return ("未开始", "")
    # OSS-1 2026-11-08 开源前重写了 main 的历史（去掉 docs/spec/ui-mock），之前合入的分支都不再是新 main 的祖先；
    # 本地留着重写前的 main 当备份分支 main-pre-oss，合入判定两边都认（docs/history/README.md）。
    if is_ancestor(b, "main") or (branch_exists("main-pre-oss") and is_ancestor(b, "main-pre-oss")):
        return ("已合入 main", "done")
    for g in gates:
        if g != b and branch_exists(g) and is_ancestor(b, g):
            return (f"已合入 {g}，等合 main", "wait")
    if b in gates:
        return ("完成，等合 main", "wait")
    if has_report(b):
        return ("完成未合并", "wait")
    return ("进行中", "run")

def is_gate(p):
    return re.match(r"^G\d", p["title"]) is not None

def kind(p):
    n = p["number"]
    if is_gate(p):
        return "g"
    if n < 10 or re.match(r"^(P\d|UIA)", p["title"]):
        return "p"
    return "w"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=".build/prompt-page.html")
    ap.add_argument("--template", default="scripts/prompt-page/template.html")
    a = ap.parse_args()
    prompts = sorted((parse(f) for f in glob.glob("docs/plan/prompts/*.md")), key=lambda p: p["number"])  # 按编号排，三位数（100+）也对
    gates = [p["branch"] for p in prompts if is_gate(p) and p["branch"]]
    cards, counts = [], {"done": 0, "wait": 0, "run": 0, "": 0}
    groups = {"done": [], "wait": [], "run": [], "": []}
    for p in prompts:
        num = f"{p['number']:02d}"
        label, cls = status(p, gates)
        if p["number"] > 0:
            counts[cls] += 1
            groups[cls].append(f"{num} {p['title'].split('（')[0].split(' ')[0]}")
        title = html.escape(p["title"])
        # 卡片名：去掉开头的 "P1 " / "W1-A " 之类的编号，标签里另放
        code = re.match(r"^([A-Z]\d+(?:-[A-Z]?\d*)?|UIA)\s*", p["title"])  # G14 修：两位数的 G1x / P5-2 以前被截成 G1 / P5
        short = "通用前言" if p["number"] == 0 else (code.group(1).replace("-", "") if code else "—")
        name = html.escape(p["title"][code.end():] if code else p["title"])
        branch = html.escape(p["branch"] or "—")
        pill = f'<span class="status {cls}">{html.escape(label)}</span>' if p["number"] > 0 else ""
        open_attr = " open" if p["number"] == 0 else ""
        cards.append(
            f'<details class="card {kind(p)}" id="c{num}"{open_attr}><summary><span class="chev">›</span><span class="code">{num} · {short}</span>'
            f'<span class="name">{name}</span>{pill}<span class="branch">{branch}</span></summary><div class="body"><div class="actions">'
            f'<button class="copy primary" data-pre="pre-{num}" data-pre2="1">复制 前言 + 本段</button><button class="copy" data-pre="pre-{num}">只复制本段</button></div>'
            f'<pre id="pre-{num}">{html.escape(p["text"])}\n</pre></div></details>')
    rc, head = git("rev-parse", "--short", "HEAD")
    rc, cur = git("rev-parse", "--abbrev-ref", "HEAD")
    when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    total = len(prompts) - 1
    stats = ('<div class="stats">\n'
             f'  <div class="stat"><b>{total}</b><span>会话 prompt</span></div>\n'
             f'  <div class="stat"><b>{counts["done"]}</b><span>已合入 main / 已完成</span></div>\n'
             f'  <div class="stat"><b>{counts["wait"]}</b><span>完成，等合 main</span></div>\n'
             f'  <div class="stat"><b>{counts["run"] + counts[""]}</b><span>进行中 / 未开始</span></div>\n'
             '</div>')
    def lst(k):
        return "、".join(groups[k]) if groups[k] else "无"
    status_html = ('<div class="callout"><b>进度（' + html.escape(when) + '，仓库 ' + html.escape(cur) + ' @ ' + html.escape(head) + '）。</b> '
                   f'已合入 main / 已完成：{html.escape(lst("done"))}。<br>完成、等合 main：{html.escape(lst("wait"))}。<br>'
                   f'进行中：{html.escape(lst("run"))}；未开始：{html.escape(lst(""))}。<br>'
                   '下一步：同一波次的会话各开一个 worktree（<span class="k">git worktree add ../plusmix-&lt;分支&gt; -b &lt;分支&gt; main</span>）开工；'
                   '排法按页首"现在怎么开"那张表（哪些能并行、谁叠在谁上；叠分支的会话 lint 加 --base）；检查点在整波之后合并、跑全量、写报告。</div>')
    tmpl = open(a.template, encoding="utf-8").read()
    out = (tmpl.replace("{{STATS}}", stats).replace("{{STATUS}}", status_html).replace("{{LIB}}", "\n".join(cards))
           .replace("{{GENERATED}}", html.escape(f"生成于 {when}，{cur} @ {head}")))
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    open(a.out, "w", encoding="utf-8").write(out)
    print(f"{a.out}：{len(prompts)} 张卡（{total} 个会话；已完成 {counts['done']}，等合 main {counts['wait']}，进行中 {counts['run']}，未开始 {counts['']}），{len(out)} 字节")

if __name__ == "__main__":
    main()
