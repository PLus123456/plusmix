## 85 UIA 界面对照调研：竞品 28 版实机截图 → 菜单逻辑、功能缺口、目视检查（用户 2026-09-28 直接指派；只写文档、不改代码；本卡是补记，会话已完成）
分支：claude/vmix-28-guide-menu-ui-c83cd1（从 main c836cce 开）。只准动：docs/ui-study/、docs/OWNERSHIP.md（自记一行）；2026-09-29 续做又加了 docs/plan/（本 prompt 与 86–104、落地方案 §8、页面模板与生成脚本）、docs/KNOWN_ISSUES.md、docs/user/、docs/integrations/、docs/api/vmix-compat.md、docs/release/third-party.md、THIRD_PARTY/NDI/NOTICE.md、.gitignore——都是按实情改文档 / 记录，不改代码。
先读：docs/ui-study/README.md（入口，含怎么做的与可信度）；要开工的会话再读 05 落地拆分与自己那条 prompt 点名的章节。

用户原话要点：在另一台 Windows 机器上按竞品 28.0.0.42 逐项截了 157 张图并做了索引（/Users/plus/plusmix/vmix-28-guide/，不入库）；先研究好菜单逻辑、看怎么改，再看还有哪些功能没加上；另外做目视检查——中间那块丑、没对齐，下边有个按钮的菜单超出边框——都要记录在案；可以多派 agent。

做了什么（18 个 agent + 本会话复核）：
1. 分区调研 R1–R8：8 区逐图读 + 读对应代码；R8 不看截图，拿 v1 规格和界面稿逐条核对实现。
2. 目视检查：临时拷贝里加巡检脚本把 App 真跑起来截图、导出视图树量尺寸，两处点名问题都做了改法原型并实测（03 §1、§2）。
3. 核对 VF1–VF5 共 401 条：326 属实、67 改措辞、7 与图不符（都是截图细节），代码结论 0 条不符。
4. 汇总：01 菜单逻辑（6 条总规则）、01a 改动总表（130 条，P0 8 条）、02 功能缺口（缺陷 63、v1 缺口 14、建议 55、后续方案 22 组、不做 38）、03 目视检查（2 处点名 + 32 条）、04 待拍板（68 条）、05 落地拆分（三批工作包）；问题单 reports/issues/UIA-*.md 14 张。

结论（细节见落地方案 §8）：参考软件的规则是"就近齿轮、主体直接干活、小箭头弹快捷菜单、底栏菜单朝上"；我们功能大多都有但入口几乎全在菜单栏，转场是固定类型按钮，底栏菜单往窗口外弹；最重的缺陷是效果链不生效（S1）与一步就停直播的五条（X01–X05）。根源之一是 W2-B 写"留给 W3-E"的一批入口没进 W3-E 的 prompt——以后检查点写续做 prompt 时对一遍上一轮报告里的"留给 xx"清单。

2026-09-29 续做（同一分支，用户指派"把 artifacts 接着往下做 prompt、把这部分作为记录写进去、更新软件相关文档"）：按 05 的三批写成 prompt 86–104 与 docs/OWNERSHIP.md 的对应行；落地方案加 §8（调研记录、现状缺陷、第五波拆分、默认拍板值）；手册 / 集成文档 / 已知问题按实情改（reports/issues/UIA-w4-docs-manual-vs-implementation.md 的九处，中英两份）；vmix-28-guide/ 加进 .gitignore；页面重生成并原地更新。
没做：任何代码、任何契约提案（候选见 01a 第 5 节，编号 020–023 由 P5 / prompt 99 写并请用户批）。
坑（reports/claude-vmix-28-guide-menu-ui-c83cd1.md §5）：NSButton 是翻转坐标（菜单朝上要 `y: -menu.size.height + 1`，popover 朝上用 `.minY`）、`NSStackView.alignment = .width` 无效、NSPopover 装 NSHostingView 要设 preferredContentSize、隔离跑 App 截图的做法（XCTestConfigurationFilePath=/dev/null + 另一个 bundle id）、竞品截图里的"默认"只是截图时的值。
