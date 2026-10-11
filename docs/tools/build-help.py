#!/usr/bin/env python3
"""随包 HTML 手册（W4-C2，prompt 103 交付 4）：把 docs/user（中文）与 docs/user/en（英文）转成一组静态网页，写到 App/Resources/Help/。

    python3 docs/tools/build-help.py            # 生成（整个 App/Resources/Help/ 按 docs/user 重写）
    python3 docs/tools/build-help.py --check    # 只比较：产物和现在的 docs/user 对不上就退出 1（挂 lint / CI 用）
    python3 docs/tools/build-help.py --out DIR  # 写到别处（试生成用）

产物：
    Help/index.html                 选语言的入口（App 找不到分语言目录时用它）
    Help/zh-Hans/index.html …       中文：README → index，概念 → concepts，输入 → inputs ……（两种语言文件名一样，语言切换只换目录）
    Help/en/index.html …            英文
    Help/img/…                      手册引用的图片（只拷被引用的）
App（W5-G 的 HelpBook）打开 Help/<界面语言 lproj 名>/index.html；添加输入面板横幅的"看说明"打开 index.html#ndi / #decklink，
入口页里有这两个锚点（并跳到"输入"页对应的一节）。

只用标准库（不依赖 markdown / pandoc），支持 docs/user 用到的 Markdown 子集：标题、段落、列表（含有序列表起始号、嵌套）、GFM 表格、围栏代码块、
引用、分隔线、行内代码 / 粗体 / 斜体 / 链接 / 图片。标题锚点与 check-links.py 同一个算法（GitHub 规则），所以 .md 里的 #锚点 原样可用。
链接：手册内的页 → 对应的 .html；docs/user/img 下的图片 → 拷进 Help/img；手册外的仓库文件（设计方案、测试标准、Samples……）不进包，
写成"链接文字（仓库：路径）"的纯文字。生成后自检：每个相对链接、图片、锚点都要在产物里找得到；产物里不许出现 lint 的禁词
（产物在 App/ 下，scripts/lint-rules.sh 会扫）。输出是确定的（不写时间戳），文档没变重跑没有 diff。
"""
import argparse
import html
import importlib.util
import os
import re
import shutil
import sys
import tempfile
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "docs", "user")
DEFAULT_OUT = os.path.join(ROOT, "App", "Resources", "Help")

# 页序与输出文件名（两种语言同名）。docs/user 里加了新页要在这里登记，否则生成时报错——不悄悄漏页。
PAGES = ["index", "concepts", "inputs", "outputs", "shortcuts", "settings", "troubleshooting"]
LANGS = {
    "zh-Hans": {
        "dir": SRC,
        "files": {"README": "index", "概念": "concepts", "输入": "inputs", "输出": "outputs", "快捷键": "shortcuts",
                  "设置": "settings", "故障排查": "troubleshooting"},
        "html_lang": "zh-Hans",
        "nav": {"concepts": "概念", "inputs": "输入", "outputs": "输出", "shortcuts": "快捷键", "settings": "设置", "troubleshooting": "故障排查"},
        "book": "PlusMix 使用手册",
        "contents": "目录",
        "other": ("en", "English"),
        "repo": "（仓库：{path}）",
        "footer": "PlusMix {version} · 本手册由仓库的 docs/user 生成，随 App 一起安装。",
        "quick": "从 App 打开的说明",
        "quick_items": [("ndi", "NDI® 运行库 / SDK 没装、收不到 NDI® 源", "inputs", "ndi-接收", "输入 › NDI® 接收"),
                        ("decklink", "DeckLink 驱动 / SDK", "inputs", "decklink", "输入 › DeckLink")],
    },
    "en": {
        "dir": os.path.join(SRC, "en"),
        "files": {"README": "index", "concepts": "concepts", "inputs": "inputs", "outputs": "outputs", "shortcuts": "shortcuts",
                  "settings": "settings", "troubleshooting": "troubleshooting"},
        "html_lang": "en",
        "nav": {"concepts": "Concepts", "inputs": "Inputs", "outputs": "Outputs", "shortcuts": "Shortcuts", "settings": "Settings", "troubleshooting": "Troubleshooting"},
        "book": "PlusMix User Guide",
        "contents": "Contents",
        "other": ("zh-Hans", "中文"),
        "repo": " (repository: {path})",
        "footer": "PlusMix {version} · Generated from docs/user in the repository and installed with the app.",
        "quick": "Opened from the app",
        "quick_items": [("ndi", "NDI® runtime / SDK missing, no NDI® sources", "inputs", "ndi-receive", "Inputs › NDI® receive"),
                        ("decklink", "DeckLink driver / SDK", "inputs", "decklink", "Inputs › DeckLink")],
    },
}
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp")
# 与 scripts/lint-rules.sh 同一组禁词（产物在 App/ 下会被它扫到）。
FORBIDDEN = [re.compile(r"vmix", re.I), re.compile(r"\bOBS\b"), re.compile(r"obs[-_ ]?studio|obsproject", re.I)]


def load_slugger():
    """标题锚点用 check-links.py 的 github_slug（同一个算法，两边不会各算各的）。"""
    spec = importlib.util.spec_from_file_location("check_links", os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-links.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.github_slug


github_slug = load_slugger()


def version():
    try:
        with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as f:
            for line in f:
                m = re.match(r'\s*MARKETING_VERSION:\s*"?([0-9][0-9.]*)"?', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return "?"


# ---------------------------------------------------------------- 块级解析

FENCE_RE = re.compile(r"^(\s*)(`{3,}|~{3,})(.*)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
HR_RE = re.compile(r"^\s{0,3}([-*_])(\s*\1){2,}\s*$")
LIST_RE = re.compile(r"^(\s*)([-*+]|\d{1,9}[.)])(\s+)(.*)$")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$")
QUOTE_RE = re.compile(r"^\s{0,3}>\s?(.*)$")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_table_start(lines, i):
    return i + 1 < len(lines) and "|" in lines[i] and TABLE_SEP_RE.match(lines[i + 1]) is not None


def starts_block(lines, i):
    line = lines[i]
    return bool(FENCE_RE.match(line) or HEADING_RE.match(line) or HR_RE.match(line) or LIST_RE.match(line)
                or QUOTE_RE.match(line) or is_table_start(lines, i))


def split_row(line):
    """表格一行拆格：反引号里的 | 与 \\| 不算分隔。"""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    cells, cur, in_code, ticks, i = [], [], False, 0, 0
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s) and s[i + 1] == "|":
            cur.append("|")
            i += 2
            continue
        if ch == "`":
            n = 1
            while i + n < len(s) and s[i + n] == "`":
                n += 1
            if not in_code:
                in_code, ticks = True, n
            elif n == ticks:
                in_code = False
            cur.append("`" * n)
            i += n
            continue
        if ch == "|" and not in_code:
            cells.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
        i += 1
    cells.append("".join(cur).strip())
    return cells


def parse_blocks(lines):
    blocks, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = FENCE_RE.match(line)
        if m:
            ind, fence, info = len(m.group(1)), m.group(2), m.group(3).strip()
            body, i = [], i + 1
            while i < n:
                close = FENCE_RE.match(lines[i])
                if close and close.group(2)[0] == fence[0] and len(close.group(2)) >= len(fence) and not close.group(3).strip():
                    i += 1
                    break
                body.append(lines[i][ind:] if lines[i][:ind].strip() == "" else lines[i].lstrip())
                i += 1
            blocks.append(("code", info, "\n".join(body)))
            continue
        m = HEADING_RE.match(line)
        if m:
            blocks.append(("heading", len(m.group(1)), m.group(2)))
            i += 1
            continue
        if HR_RE.match(line):
            blocks.append(("hr",))
            i += 1
            continue
        if is_table_start(lines, i):
            header = split_row(lines[i])
            aligns = []
            for cell in split_row(lines[i + 1]):
                c = cell.strip()
                aligns.append("center" if c.startswith(":") and c.endswith(":") else "right" if c.endswith(":") else "left" if c.startswith(":") else None)
            rows, i = [], i + 2
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(split_row(lines[i]))
                i += 1
            blocks.append(("table", header, aligns, rows))
            continue
        if QUOTE_RE.match(line):
            inner = []
            while i < n and lines[i].strip() and (QUOTE_RE.match(lines[i]) or not starts_block(lines, i)):
                q = QUOTE_RE.match(lines[i])
                inner.append(q.group(1) if q else lines[i])
                i += 1
            blocks.append(("quote", parse_blocks(inner)))
            continue
        m = LIST_RE.match(line)
        if m:
            block, i = parse_list(lines, i)
            blocks.append(block)
            continue
        para = [line]
        i += 1
        while i < n and lines[i].strip() and not starts_block(lines, i):
            para.append(lines[i])
            i += 1
        blocks.append(("para", para))
    return blocks


def parse_list(lines, i):
    """从第 i 行起的一个列表（同一缩进、同一种列表符号）。条目内容按缩进剥掉后递归成块；空行隔开的条目 = 松散列表。"""
    first = LIST_RE.match(lines[i])
    base = len(first.group(1))
    ordered = first.group(2)[0].isdigit()
    start = int(first.group(2)[:-1]) if ordered else None
    items, loose, n = [], False, len(lines)
    while i < n:
        m = LIST_RE.match(lines[i])
        if not m or len(m.group(1)) != base or m.group(2)[0].isdigit() != ordered:
            break
        content_indent = base + len(m.group(2)) + len(m.group(3))
        body = [m.group(4)]
        i += 1
        blank_inside = False
        while i < n:
            line = lines[i]
            if not line.strip():
                # 空行：后面还有更深缩进的内容才算条目里的空行
                j = i + 1
                while j < n and not lines[j].strip():
                    j += 1
                if j < n and indent_of(lines[j]) >= content_indent:
                    body.extend([""] * (j - i))
                    blank_inside = True
                    i = j
                    continue
                break
            if indent_of(line) >= content_indent:
                body.append(line[content_indent:])
                i += 1
                continue
            mm = LIST_RE.match(line)
            if mm and len(mm.group(1)) > base:
                body.append(line.lstrip())   # 缩进不够条目内容那么深的子列表：当成条目里的列表
                i += 1
                continue
            if mm or starts_block(lines, i):
                break
            body.append(line.strip())   # 懒续行
            i += 1
        items.append(parse_blocks(body))
        if blank_inside:
            loose = True
        # 条目之间的空行
        j = i
        while j < n and not lines[j].strip():
            j += 1
        if j > i and j < n:
            m2 = LIST_RE.match(lines[j])
            if m2 and len(m2.group(1)) == base and m2.group(2)[0].isdigit() == ordered:
                loose = True
                i = j
                continue
        if j > i:
            break
    return ("list", ordered, start, items, loose), i


# ---------------------------------------------------------------- 行内

CJK_END = re.compile(r"[⺀-鿿豈-﫿＀-￯　-〿]$")
CJK_START = re.compile(r"^[⺀-鿿豈-﫿＀-￯　-〿]")


def join_lines(lines):
    """段落里的软换行：两边都是中文（含全角标点）时直接接上，否则补一个空格（浏览器把换行显示成空格，中文中间会多出一个空）。"""
    out = ""
    for raw in lines:
        line = raw.strip()
        if not out:
            out = line
        elif CJK_END.search(out) and CJK_START.search(line):
            out += line
        else:
            out += " " + line
    return out


class Renderer:
    def __init__(self, ctx):
        self.ctx = ctx

    def inline(self, text):
        store = []

        def keep(s):
            store.append(s)
            return "\x00%d\x00" % (len(store) - 1)

        # 行内代码先摘出来（里面的 * [ ] 不算格式）
        def code(m):
            return keep("<code>%s</code>" % html.escape(m.group(2).strip() if m.group(2).strip() else m.group(2), quote=False))
        text = re.sub(r"(`+)(.+?)\1", code, text)

        def image(m):
            src = self.ctx.resolve_image(m.group(2))
            return keep('<img src="%s" alt="%s">' % (html.escape(src), html.escape(m.group(1))))
        text = re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)", image, text)

        def link(m):
            label = self.emphasis(html.escape(m.group(1), quote=False))
            kind, value = self.ctx.resolve_link(m.group(2))
            if kind == "href":
                return keep('<a href="%s">%s</a>' % (html.escape(value), label))
            note = "" if self.ctx.same_as_label(m.group(1), value) else html.escape(self.ctx.lang["repo"].format(path=value), quote=False)
            return keep('<span class="repo-ref">%s</span>%s' % (label, '<span class="repo-path">%s</span>' % note if note else ""))
        text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)

        text = self.emphasis(html.escape(text, quote=False))
        while "\x00" in text:
            text = re.sub(r"\x00(\d+)\x00", lambda m: store[int(m.group(1))], text)
        return text

    @staticmethod
    def emphasis(s):
        s = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])", r"<em>\1</em>", s)
        return s

    def blocks(self, blocks, tight=False):
        out = []
        for b in blocks:
            kind = b[0]
            if kind == "heading":
                level, text = b[1], b[2]
                slug = self.ctx.slugs.add(text)
                out.append('<h%d id="%s">%s</h%d>' % (level, html.escape(slug), self.inline(text), level))
            elif kind == "para":
                body = self.inline(join_lines(b[1]))
                out.append(body if tight else "<p>%s</p>" % body)
            elif kind == "code":
                cls = ' class="language-%s"' % html.escape(b[1].split()[0]) if b[1] else ""
                out.append("<pre><code%s>%s</code></pre>" % (cls, html.escape(b[2], quote=False)))
            elif kind == "hr":
                out.append("<hr>")
            elif kind == "quote":
                out.append("<blockquote>%s</blockquote>" % self.blocks(b[1]))
            elif kind == "table":
                header, aligns, rows = b[1], b[2], b[3]

                def cell(tag, text, k):
                    a = aligns[k] if k < len(aligns) else None
                    return '<%s%s>%s</%s>' % (tag, ' style="text-align:%s"' % a if a else "", self.inline(text), tag)
                head = "".join(cell("th", t, k) for k, t in enumerate(header))
                body = "".join("<tr>%s</tr>" % "".join(cell("td", t, k) for k, t in enumerate(r)) for r in rows)
                out.append('<div class="table"><table><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>' % (head, body))
            elif kind == "list":
                ordered, start, items, loose = b[1], b[2], b[3], b[4]
                tag = "ol" if ordered else "ul"
                attr = ' start="%d"' % start if ordered and start not in (None, 1) else ""
                lis = "".join("<li>%s</li>" % self.blocks(item, tight=not loose) for item in items)
                out.append("<%s%s>%s</%s>" % (tag, attr, lis, tag))
        return "\n".join(out)


class Slugs:
    """同一页里重复的标题照 GitHub 加 -1、-2（与 check-links.py 的 headings() 一致）。"""

    def __init__(self):
        self.seen = {}

    def add(self, text):
        base = github_slug(text)
        n = self.seen.get(base, 0)
        self.seen[base] = n + 1
        return base if n == 0 else "%s-%d" % (base, n)


# ---------------------------------------------------------------- 一页

class PageContext:
    def __init__(self, builder, lang_code, src_path, out_name):
        self.builder = builder
        self.lang_code = lang_code
        self.lang = LANGS[lang_code]
        self.src_path = src_path
        self.out_name = out_name
        self.slugs = Slugs()

    def resolve_image(self, src):
        if re.match(r"^[a-z][a-z0-9+.-]*:", src):
            return src
        path = os.path.normpath(os.path.join(os.path.dirname(self.src_path), src))
        if not os.path.isfile(path):
            raise SystemExit("[build-help] %s 引用的图片不存在：%s" % (rel(self.src_path), src))
        return "../img/" + self.builder.add_image(path)

    def resolve_link(self, target):
        """('href', 产物里的相对地址) 或 ('repo', 仓库里的路径)。"""
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            return "href", target
        file_part, _, anchor = target.partition("#")
        path = os.path.normpath(os.path.join(os.path.dirname(self.src_path), file_part.replace("%20", " ")))
        frag = "#" + anchor if anchor else ""
        if path.lower().endswith(IMAGE_EXT) and path.startswith(SRC + os.sep):
            return "href", "../img/" + self.builder.add_image(path)
        page = self.builder.page_for(path)
        if page:
            lang_code, name = page
            href = name + ".html" if lang_code == self.lang_code else "../%s/%s.html" % (lang_code, name)
            return "href", href + frag
        if os.path.isdir(path):
            readme = os.path.join(path, "README.md")
            page = self.builder.page_for(readme)
            if page:
                lang_code, name = page
                return "href", (name + ".html" if lang_code == self.lang_code else "../%s/%s.html" % (lang_code, name)) + frag
        return "repo", rel(path)

    @staticmethod
    def same_as_label(label, path):
        label = label.strip().strip("`")
        return label == path or path.endswith("/" + label) or label.rstrip("/") == path


def rel(path):
    """仓库里的路径写成相对仓库根的；仓库外的（--out 到草稿区）写绝对路径。"""
    r = os.path.relpath(path, ROOT)
    return path if r.startswith("..") else r


CSS = """
:root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #ffffff; --line: #d2d2d7; --code-bg: #f2f2f5; --link: #0a66d0; --nav-bg: #f7f7f9; }
@media (prefers-color-scheme: dark) {
  :root { --fg: #f2f2f7; --muted: #a1a1a6; --bg: #1c1c1e; --line: #3a3a3c; --code-bg: #2c2c2e; --link: #5eaaff; --nav-bg: #242426; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.65 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif; }
header.nav { position: sticky; top: 0; background: var(--nav-bg); border-bottom: 1px solid var(--line); z-index: 1; }
header.nav .inner { max-width: 980px; margin: 0 auto; padding: 8px 16px; display: flex; flex-wrap: wrap; gap: 4px 14px; align-items: baseline; }
header.nav .book { font-weight: 600; margin-right: 8px; }
header.nav a { color: var(--link); text-decoration: none; white-space: nowrap; }
header.nav a.current { color: var(--fg); font-weight: 600; }
header.nav .lang { margin-left: auto; }
main { max-width: 980px; margin: 0 auto; padding: 8px 16px 48px; }
h1 { font-size: 28px; margin: 24px 0 12px; }
h2 { font-size: 21px; margin: 32px 0 10px; padding-top: 8px; border-top: 1px solid var(--line); }
h3 { font-size: 17px; margin: 24px 0 8px; }
a { color: var(--link); }
code { font: 13px ui-monospace, "SF Mono", Menlo, monospace; background: var(--code-bg); padding: 1px 4px; border-radius: 4px; }
pre { background: var(--code-bg); padding: 10px 12px; border-radius: 8px; overflow-x: auto; }
pre code { background: none; padding: 0; }
.table { overflow-x: auto; margin: 12px 0; }
table { border-collapse: collapse; min-width: 50%; }
th, td { border: 1px solid var(--line); padding: 6px 10px; vertical-align: top; text-align: left; }
th { background: var(--nav-bg); }
th:first-child, td:first-child { min-width: 6.5em; }
h1, h2, h3, h4, [id] { scroll-margin-top: 64px; }
img { max-width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; }
blockquote { margin: 12px 0; padding: 4px 14px; border-left: 3px solid var(--line); color: var(--muted); }
.repo-path { color: var(--muted); font-size: 13px; }
.quick { margin-top: 32px; padding: 10px 14px; border: 1px solid var(--line); border-radius: 8px; }
.quick h2 { border: none; margin-top: 4px; padding-top: 0; font-size: 17px; }
footer { color: var(--muted); font-size: 13px; border-top: 1px solid var(--line); margin-top: 40px; padding-top: 10px; }
"""

PAGE = """<!doctype html>
<html lang="{html_lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="stylesheet" href="../style.css">
</head>
<body>
<header class="nav"><div class="inner"><span class="book">{book}</span>{nav}<a class="lang" href="../{other_dir}/{name}.html" hreflang="{other_dir}">{other_label}</a></div></header>
<main>
{body}
<footer>{footer}</footer>
</main>
{script}</body>
</html>
"""

CHOOSER = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PlusMix 使用手册 · User Guide</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<main>
<h1>PlusMix 使用手册 · User Guide</h1>
<ul>
<li><a href="zh-Hans/index.html" hreflang="zh-Hans">简体中文</a></li>
<li><a href="en/index.html" hreflang="en">English</a></li>
</ul>
</main>
</body>
</html>
"""


class Builder:
    def __init__(self, out):
        self.out = out
        self.images = {}          # 源路径 → Help/img 下的文件名
        self.pages = {}           # 源 .md 绝对路径 → (语言, 输出名)
        self.titles = {}          # (语言, 输出名) → 页标题（H1）
        for code, lang in LANGS.items():
            names = sorted(f for f in os.listdir(lang["dir"]) if f.endswith(".md"))
            for f in names:
                stem = f[:-3]
                if stem not in lang["files"]:
                    raise SystemExit("[build-help] %s 没在 docs/tools/build-help.py 的 LANGS[%r]['files'] 里登记输出文件名" % (rel(os.path.join(lang["dir"], f)), code))
                self.pages[os.path.join(lang["dir"], f)] = (code, lang["files"][stem])
            missing = set(lang["files"]) - {f[:-3] for f in names}
            if missing:
                raise SystemExit("[build-help] docs/user（%s）少了这些页：%s" % (code, ", ".join(sorted(missing))))
        for path, (code, name) in self.pages.items():
            with open(path, encoding="utf-8") as f:
                for line in f:
                    m = HEADING_RE.match(line)
                    if m and len(m.group(1)) == 1:
                        self.titles[(code, name)] = m.group(2)
                        break

    def page_for(self, path):
        return self.pages.get(path)

    def add_image(self, path):
        if path not in self.images:
            name = os.path.basename(path)
            if name in self.images.values():
                raise SystemExit("[build-help] 两张图同名：%s" % name)
            self.images[path] = name
        return self.images[path]

    def nav(self, code, current):
        lang = LANGS[code]
        links = []
        for name in PAGES:
            title = lang["contents"] if name == "index" else lang["nav"][name]
            cls = ' class="current"' if name == current else ""
            links.append('<a%s href="%s.html">%s</a>' % (cls, name, html.escape(title)))
        return "".join(links)

    def build(self):
        os.makedirs(self.out, exist_ok=True)
        ver = version()
        written = {}
        for path, (code, name) in sorted(self.pages.items(), key=lambda kv: (kv[1][0], PAGES.index(kv[1][1]))):
            lang = LANGS[code]
            ctx = PageContext(self, code, path, name)
            with open(path, encoding="utf-8") as f:
                blocks = parse_blocks(f.read().split("\n"))
            body = Renderer(ctx).blocks(blocks)
            script = ""
            if name == "index":
                items = []
                for anchor, text, page, frag, where in lang["quick_items"]:
                    items.append('<li id="%s">%s：<a href="%s.html#%s">%s</a></li>' % (anchor, html.escape(text), page, html.escape(frag), html.escape(where))
                                 if code == "zh-Hans" else
                                 '<li id="%s">%s: <a href="%s.html#%s">%s</a></li>' % (anchor, html.escape(text), page, html.escape(frag), html.escape(where)))
                body += '\n<section class="quick"><h2 id="app">%s</h2><ul>%s</ul></section>' % (html.escape(lang["quick"]), "".join(items))
                targets = ", ".join('"%s": "%s.html#%s"' % (a, p, f) for a, _, p, f, _ in lang["quick_items"])
                # App 的"看说明"打开 index.html#ndi 之类：有脚本时直接跳到那一节，没有脚本时停在入口页的这个列表上
                script = '<script>(function () { var m = {%s}; var h = decodeURIComponent(location.hash.slice(1)); if (m[h]) location.replace(m[h]); })();</script>\n' % targets
            other_dir, other_label = lang["other"]
            title = "%s — %s" % (self.titles[(code, name)], lang["book"]) if name != "index" else lang["book"]
            page = PAGE.format(html_lang=lang["html_lang"], title=html.escape(title), book=html.escape(lang["book"]), nav=self.nav(code, name),
                               other_dir=other_dir, name=name, other_label=html.escape(other_label), body=body,
                               footer=html.escape(lang["footer"].format(version=ver)), script=script)
            written[os.path.join(code, name + ".html")] = page.encode("utf-8")
        written["style.css"] = CSS.lstrip().encode("utf-8")
        written["index.html"] = CHOOSER.encode("utf-8")
        for src, name in sorted(self.images.items()):
            with open(src, "rb") as f:
                written[os.path.join("img", name)] = f.read()
        return written


# ---------------------------------------------------------------- 自检

def verify(files):
    """产物里每个相对 href / src 都要指到产物里的文件，带锚点的要有那个 id；不许有禁词。"""
    errors = []
    ids = {}
    for path, data in files.items():
        if path.endswith(".html"):
            text = data.decode("utf-8")
            ids[path] = set(html.unescape(m) for m in re.findall(r'\sid="([^"]+)"', text))
    for path, data in files.items():
        if not path.endswith((".html", ".css")):
            continue
        text = data.decode("utf-8")
        for pat in FORBIDDEN:
            for m in pat.finditer(text):
                errors.append("%s：出现禁词 %r（scripts/lint-rules.sh 会扫 App/）" % (path, m.group(0)))
        if not path.endswith(".html"):
            continue
        for attr, target in re.findall(r'\s(href|src)="([^"]+)"', text):
            target = html.unescape(target)
            if re.match(r"^[a-z][a-z0-9+.-]*:", target):
                continue
            file_part, _, anchor = target.partition("#")
            dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) if file_part else path
            if dest not in files:
                errors.append("%s：%s 指向产物里没有的 %s" % (path, attr, target))
                continue
            if anchor and dest.endswith(".html") and anchor not in ids.get(dest, set()):
                errors.append("%s：%s 里没有锚点 #%s" % (path, dest, anchor))
    return errors


def current_files(out):
    found = {}
    if not os.path.isdir(out):
        return found
    for dirpath, _, filenames in os.walk(out):
        for name in filenames:
            if name.startswith("."):
                continue
            p = os.path.join(dirpath, name)
            with open(p, "rb") as f:
                found[os.path.relpath(p, out)] = f.read()
    return found


def main(argv):
    ap = argparse.ArgumentParser(description="docs/user → App/Resources/Help（随包 HTML 手册）")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录（默认 App/Resources/Help）")
    ap.add_argument("--check", action="store_true", help="不写文件，只比较产物是否与 docs/user 一致")
    args = ap.parse_args(argv[1:])
    files = Builder(os.path.abspath(args.out)).build()
    errors = verify(files)
    if errors:
        print("[build-help] 产物自检 %d 处问题：" % len(errors))
        for e in errors:
            print("    " + e)
        return 1
    total = sum(len(v) for v in files.values())
    if args.check:
        have = current_files(args.out)
        stale = sorted(set(files) ^ set(have) | {k for k in files if k in have and files[k] != have[k]})
        if stale:
            print("[build-help] %s 和 docs/user 对不上（%d 个文件）：先跑 python3 docs/tools/build-help.py" % (rel(os.path.abspath(args.out)), len(stale)))
            for k in stale[:20]:
                print("    " + k)
            return 1
        print("[build-help] %s 与 docs/user 一致（%d 个文件，%.1f KB）" % (rel(os.path.abspath(args.out)), len(files), total / 1024))
        return 0
    out = os.path.abspath(args.out)
    parent = os.path.dirname(out)
    os.makedirs(parent, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".help-", dir=parent)
    try:
        for name, data in files.items():
            p = os.path.join(tmp, name)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
        if os.path.isdir(out):
            shutil.rmtree(out)
        os.replace(tmp, out)
    finally:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
    print("[build-help] 写了 %s：%d 个文件，%.1f KB（中文 %d 页、英文 %d 页、图片 %d 张）" % (
        rel(out), len(files), total / 1024,
        sum(1 for k in files if k.startswith("zh-Hans" + os.sep)), sum(1 for k in files if k.startswith("en" + os.sep)),
        sum(1 for k in files if k.startswith("img" + os.sep))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
