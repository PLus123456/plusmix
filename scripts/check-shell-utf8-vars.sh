#!/bin/bash
# 变量名后面紧跟非 ASCII 字符（全角标点 / 中文）的写法要改成 ${name}（make lint 的一部分；补充规则 4 自动挂上）。
# macOS 的 /bin/bash 3.2 在 UTF-8 locale 下把紧跟的那个字的首字节也算进变量名：set -u 下直接 "unbound variable" 退出，
# 不开 set -u 就悄悄展开成空。用户的终端是 UTF-8、Claude 会话里的 Bash 是 C locale，所以会话里从来测不出来——
# 2026-09-27 make soak（env-snapshot.sh）、2026-10-13 make lint（check-rt-symbols.sh）、2026-11-08 G14 的 make gen（scripts/dev-signing/sign-mode.sh 第 66 行）
# 三次都这么断。scripts/soak/test_soakjudge.py 的 test_S1_shellScriptsBraceVariablesBeforeNonASCII 查同一件事，但没人把它挂进流水线，
# G12 / W4-B3 新加的脚本就又漏了，所以 G14 把同一条检查挂进 make lint。
# 扫：scripts/**/*.sh、Packages/*/Scripts/*.sh、Tools/**/*.sh、Makefile、scripts/**/*.mk（.build 不扫）。
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import glob, re, sys
pat = re.compile(rb"\$([A-Za-z_][A-Za-z0-9_]*)(?=[\x80-\xff])")
files = sorted(set(
    glob.glob("scripts/**/*.sh", recursive=True) + glob.glob("scripts/**/*.mk", recursive=True)
    + glob.glob("Packages/*/Scripts/*.sh") + glob.glob("Tools/**/*.sh", recursive=True) + ["Makefile"]))
files = [f for f in files if "/.build/" not in f]
bad = []
for f in files:
    with open(f, "rb") as fh:
        for n, line in enumerate(fh, 1):
            for m in pat.finditer(line):
                bad.append(f"    {f}:{n}: {m.group().decode()} 后面紧跟非 ASCII 字符，写成 ${{{m.group(1).decode()}}}")
if bad:
    print("\033[31m[check-shell-utf8-vars] %d 处变量名后面紧跟非 ASCII 字符（UTF-8 终端里 bash 3.2 会把它算进变量名）：\033[0m" % len(bad))
    print("\n".join(bad))
    sys.exit(1)
print("\033[32m[check-shell-utf8-vars] %d 个脚本 / Makefile：没有变量名紧跟非 ASCII 字符的写法\033[0m" % len(files))
PY
