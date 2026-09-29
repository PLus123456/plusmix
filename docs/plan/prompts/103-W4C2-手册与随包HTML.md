## 103 W4-C2 手册与实现再对齐、随包 HTML 手册、快捷键表重排（第五波 · 文档；G6 之后随各批合入更新）
分支：w4-docs-2（从 G6 合入后的 main 开；每合入一批（G6 / G7）rebase 一次再改）。只准动：docs/（spec/ 与 plan/ 除外）、Samples/、README.md、App/Resources/Help/（随包手册的产物目录，App 只读它）。
先读：reports/issues/UIA-w4-docs-manual-vs-implementation.md（九处；85 已按 2026-09-29 的实情改过一遍，实现变了要改回来）；docs/ui-study/02-功能缺口.md X53–X57；04 Q33（默认：随包 HTML，从 docs/user 生成）、Q64；reports/w5-*.md 各份的 §3 / §5（实现到底做成了什么样）；docs/tools/check-links.py；reports/w4-docs.md §5（上一次文档会话的坑）。

交付：
1. 手册跟实现：效果链（88 / 102 之后改回"已生效"、写明范围）、录制"文件格式"（87）、停止前确认与未保存询问（87）、退出口径（Q67）、推流失败路与重试（87 / 92）、底栏三段式与工具条（92 / 93）、格子按钮（94）、设置窗（96）、tally 开关与远程控制页（98）、转场槽与 T-bar 横放（100）、播放控制与状态面板（101）；中英两份一起改；截图（docs/user 若有）重拍。
2. 快捷键表按 96 的默认表重排（⌥1–⌥4、⌃1–⌃4 等），快捷键.md / en/shortcuts.md 同步。
3. 兼容层文档：覆盖表按 100 的 Transition1–4 / SetTransitionEffect 映射与 X51 的 501 口径改；"不做"的理由按 02 X57 更新（docs/integrations/vmix-compat.md、docs/api/vmix-compat.md）。
4. 随包 HTML 手册：`docs/tools/build-help.py`（或 .sh）把 docs/user（中英）转成一组静态 HTML 到 App/Resources/Help/（含目录页、相对链接、图片），`make help` 目标由检查点挂（本会话写脚本并在报告里给 Makefile 的一行）；93 的帮助菜单打开它。
5. docs/user/README.md 与 en/README.md 加一句"界面按 0.1.x 改版后的样子写；0.1.0 的老界面对照见 docs/ui-study/03"。
6. `make lint` 的 check-links 绿；每个文档里的命令能复制执行；样例 Show 在 App 里打开无错误。

不做：规格（docs/spec）与计划（docs/plan）。
报告 reports/w4-docs-2.md（五段）：哪些说法改回了"已生效"、随包手册的大小与生成时间。不 push、不 merge。
