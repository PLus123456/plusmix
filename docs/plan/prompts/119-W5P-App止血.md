## 119 W5-P App 止血：D04 打开 / 保存错配、K01 开录覆盖旧录像、D06 ISO 换源定格、D16 LastSession 相对路径、D07 换源重试占编号 + 111 / 112 / 109 留下的 App 口径（Codex 2026-10-13 审查 + 用户 2026-10-17 裁定；G9 合入后现在就能开，与 115–118 / 120 / 121 并行）
分支：w5-app-fixes（从 G9 合入后的 main 开）。只准动：App/（App/Sources/Engine/ControlRuntime.swift 的 MIDI 反馈那几行归 116，别碰那一段）。
先读：reports/codex-debug-audit-20261013.md §1.2 D04 / K01、§1.3 D06 / D07、§1.4 D16、§2（新增 App 回归探针的四条断言）与 §4（两个产品行为，**用户 2026-10-17 定**：ISO 录制中换源**跟着新来源继续录、Recorder 不断**；开录遇到同名文件**自动加后缀**；两种都不许静默丢数据）；reports/codex-debug-audit-20261013-DebugAuditTests.swift.txt（Codex 的四条红用例，原样搬进 App/Tests/DebugAuditTests.swift 当"先写红测试"，断言不改、函数名加 D04 / D06 / D16 / K01 编号）；reports/issues/W4C3-w5-app-gaps-found-by-docs.md（15 条；第 7 条归 116）；reports/w2-stream-4.md §3 第 1–2 条 / §4（底栏"起不来"→ 用户 10-17 定改"失败"；credentialsRequired 也停维持）；reports/w5-app-followups.md §3 第 7 / 9 条（格子"转场"、T-bar 遇没选输入的 Stinger，用户 10-17 定：格子先弹选择整条不发、T-bar 灰掉并提示）与 §5（设置两种写法、测试宿主设置被异步提交写脏、defaults suite 固定名字）；AppController.swift:196 / :394 / :512；OutputRuntime.swift:240 / :363；InputRuntime.swift:80；AudioRuntime.swift:70；ShowDocuments.swift:115；reports/w2-app-2.md:99（K01 早有记录）。

交付（先写红测试；Codex 的四条先跑红再修）：
1. **D04**：读文件、提交文档身份、替换会话做成一个串行事务——取得替换锁之前不改 `currentURL`；重入的打开排队或拒绝、不能提前改保存目标；保存永远写当前运行的那份节目。用例 = Codex 的 D04（A / B 重叠打开后保存：session 与保存目标配对、B 的输入不变）。
2. **K01**：录制路径分配层查磁盘已有文件——同名就自动加后缀（`name-2.mov`、`name-3.mov`…，与当前在录的也去重）、永不删旧文件；覆盖快速起停、固定模板 `fixed`、同秒再录、MP4 转封装目标同名的情况；Recorder 的库接口（约定覆盖）不改。用例 = Codex 的 K01（37 字节旧文件原样保住）+ 固定模板连录两次得两个文件。
3. **D06**：ISO 录制中换来源 → `OutputRuntime` 把在录的 ISO 消费者换到新 tee 分支、Recorder 不断、节目拍点连续；换源到新分支第一帧之间重复旧帧按 dup 记账、不定格到底。用例 = Codex 的 D06（forwarded 涨、lastSequence 变）。
4. **D16**：自动保存 LastSession 时记下原节目的基准目录（或把相对素材路径落成绝对），恢复后相对素材仍指向原目录。用例 = Codex 的 D16。
5. **D07**：`AudioRuntime` 的延迟注册带每路 generation + 目标校验，stop / unregister / 再换源一并作废旧任务；用例用可控计钟替身（A → B → C 最终注册 C、不残留 B、重试计数不累到 11）。
6. **111 留下的**：底栏对鉴权停下的推流写"失败"（`OutputButtonSummary.routeState`：运行表的原因来自停在 failed 的推流对象时按 Stats 的 failed 显示；"点主体 = 重试起不来的路"仍把它算进去）；推流页红字按原因分两句（鉴权停下的写"改对后点「重试」"）、编码详情"重试间隔最长 n s（一直重试，鉴权失败除外）"；状态行 `StatusLineFormatter.runningEncoders` 排除 failed（W4C3 第 11 条）。
7. **112 留下的**：格子"转场"遇当前那组是没选输入的 Stinger → 先弹这个槽的输入选择、整条不发（PVW 也不换）；当前槽是这种槽时 T-bar 行灰掉 + 提示"转场 n 是 Stinger、还没选输入"（推了照契约会硬切，所以界面拦）。
8. **W4C3 的 S3 一批**（第 1–6、8–9、12–15 条，按顺序做、做不完写 §3）：状态窗"显示日志…"改成实情（或开控制台带 `process == "PlusMix"` 过滤）；状态窗 / 统计窗 / 多画面窗口 `forwardHotkeys`；输入设置的效果页不显示限幅节；限幅延迟提示按总线分开写、"首帧晚约 3 拍"、三处英文文案；设置窗播放按钮认"播完"；英文 T-bar 行写短；查询串自定义参数名存下来 / 换写法按表里的名字去掉；Adobe 摘要看密码空不空；效果链编辑器不把第 4 段起的 EQ / 认不出的格挪到链尾（API 设的顺序原样保住）；SDK 没编进来的两种横幅的"添加"小字。
9. `make test-app` 两遍（0 红；显示类 / 推流类红先单独复跑；别的会话跑 MediaMTX 用例时 App 推流用例会红）；`make lint BRANCH=w5-app-fixes`；用例名带编号（`testD04_…` / `testK01_…` / `testW4C3_…`）。

不做：Stream Deck（116）；包里的东西（D05 / D08 归 118，D13–D15 归 117）；LastSession"崩溃后恢复"（用户没定）；任何阈值。
报告 reports/w5-app-fixes.md 五段；不 push、不 merge，做完交 G10（prompt 122）。

**G9 追加（2026-10-18）**：Opus 5.5 子代理做完、未合并——`w5-app-fixes` = 7e94924，报告 reports/w5-app-fixes.md，等 G10（122）合入。用户 2026-10-18 裁定（reports/G9.md §7.4 表）：§4 三条裁定全维持（换源 PGM 停旧画面、029 不连 T-bar 拒、查询串参数名只记本机）；W4C3 第 8 条（推流 last_error 枚举原文）归 G10 胶水；D06 两个边角归 126；它说的 ToolbarMenuTests 环境红 = D04，G10 从名单拿掉。

**G10 追加（2026-10-19）**：已合入 `g10`（合并提交 7de05e2），0 冲突（最后合）；合入顺序 115 → 117 → 116 → 118 → 120 → 121 → 119，每一路合完跑了被改动的包整包 + App 相关类 + lint（reports/G10.md §4.2）。KNOWN_ISSUES 的销号在"2026-10-19 G10 合入已修"表；本路 §3 / §4 留下的归 123–126（reports/G10.md §7）。agent worktree 已清（分支 `w5-app-fixes` 与 harness 分支留着）。
