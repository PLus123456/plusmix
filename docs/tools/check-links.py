#!/usr/bin/env python3
"""文档链接检查（W4-C）：docs/、Samples/、README.md、README.zh-CN.md 里的 Markdown 相对链接都要指向存在的文件；带锚点的还要能在目标文件里找到那个标题。

    python3 docs/tools/check-links.py            # 全部；有坏链接退出 1
    python3 docs/tools/check-links.py docs/user  # 只查某个目录

顺带查：Samples/ 下的 *.switcher.json 能被解析、里面 image / file 的相对路径存在；docs/api.md 里没有相对链接指向不存在的文件。
只查仓库内的相对链接；http(s)://、mailto:、纯锚点（#…）跳过。锚点按 GitHub 的规则生成：小写、去标点、空格换 -、中文原样保留。
放在 docs/tools/ 而不是 scripts/ 是因为 W4-C 只准动 docs/（docs/OWNERSHIP.md）；要挂进 make lint 只需在 scripts/ 下加一个调它的 check-*.sh。
"""
import json
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SCOPES = ["docs", "Samples", "README.md", "README.zh-CN.md"]

LINK_RE = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
IMAGE_RE = re.compile(r"!\[[^\]]*\]\(([^)\s]+)\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def github_slug(text):
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)       # 标题里的链接只留文字
    text = re.sub(r"[`*_~]", "", text)
    text = text.strip().lower()
    out = []
    for ch in text:
        if ch == " ":
            out.append("-")
        elif ch == "-" or ch == "_" or ch.isalnum() or unicodedata.category(ch).startswith("L") or unicodedata.category(ch).startswith("N"):
            out.append(ch)
        # 其余标点丢掉
    return "".join(out)


def headings(path):
    slugs = {}
    in_fence = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            m = HEADING_RE.match(line)
            if not m:
                continue
            base = github_slug(m.group(2))
            n = slugs.get(base, 0)
            slugs[base] = n + 1
            # 重复标题 GitHub 加 -1、-2
            slugs.setdefault(base if n == 0 else f"{base}-{n}", 1)
    return set(slugs)


def markdown_files(scopes):
    for scope in scopes:
        p = os.path.join(ROOT, scope)
        if os.path.isfile(p):
            if p.endswith(".md"):
                yield p
            continue
        for dirpath, dirnames, filenames in os.walk(p):
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "ui-mock"]
            for name in filenames:
                if name.endswith(".md"):
                    yield os.path.join(dirpath, name)


def check_markdown(path, errors):
    in_fence = False
    heading_cache = {}
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for target in LINK_RE.findall(line) + IMAGE_RE.findall(line):
                if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                    if target.startswith("#"):
                        anchor = target[1:]
                        heading_cache.setdefault(path, headings(path))
                        if anchor not in heading_cache[path]:
                            errors.append(f"{rel(path)}:{lineno}: 本页没有锚点 #{anchor}")
                    continue
                file_part, _, anchor = target.partition("#")
                file_part = file_part.replace("%20", " ")
                dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) if file_part else path
                if not os.path.exists(dest):
                    errors.append(f"{rel(path)}:{lineno}: 目标不存在 {target}")
                    continue
                if anchor and dest.endswith(".md"):
                    heading_cache.setdefault(dest, headings(dest))
                    if anchor not in heading_cache[dest]:
                        errors.append(f"{rel(path)}:{lineno}: {rel(dest)} 里没有锚点 #{anchor}")


def check_samples(errors):
    samples = os.path.join(ROOT, "Samples")
    for dirpath, _, filenames in os.walk(samples):
        for name in filenames:
            if not name.endswith(".switcher.json"):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as f:
                    show = json.load(f)
            except (OSError, ValueError) as e:
                errors.append(f"{rel(path)}: 不是合法 JSON：{e}")
                continue
            if show.get("schemaVersion") != 1:
                errors.append(f"{rel(path)}: schemaVersion 应为 1")
            for inp in show.get("inputs", []):
                src = inp.get("source", {})
                for kind in ("image", "file"):
                    p = src.get(kind, {}).get("path")
                    if p and not p.startswith("/") and not os.path.exists(os.path.join(dirpath, p)):
                        errors.append(f"{rel(path)}: 输入 {inp.get('number')} 的 {kind} 路径不存在：{p}")
            if len(show.get("mixer", {}).get("overlays", [])) != 4:
                errors.append(f"{rel(path)}: overlays 必须恰好 4 个")
            if [b.get("bus") for b in show.get("audio", {}).get("buses", [])] != [0, 1, 2, 3]:
                errors.append(f"{rel(path)}: audio.buses 必须是 0–3 各一条、按顺序")


def rel(path):
    return os.path.relpath(path, ROOT)


def main(argv):
    scopes = argv[1:] or DEFAULT_SCOPES
    errors = []
    count = 0
    for path in markdown_files(scopes):
        count += 1
        check_markdown(path, errors)
    if not argv[1:] or any(s.startswith("Samples") for s in argv[1:]):
        check_samples(errors)
    if errors:
        print(f"[check-links] {len(errors)} 处问题（扫描 {count} 个 Markdown）：")
        for e in errors:
            print("    " + e)
        return 1
    print(f"[check-links] 通过：{count} 个 Markdown 的相对链接与锚点都能解析，Samples 节目文件合法")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
