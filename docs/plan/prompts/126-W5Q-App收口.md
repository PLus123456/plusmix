## 126 W5-Q App 收口：速率数字框钳位、竖拍文件信息摘要、D06 两个边角、030 的界面展示、ISO 用例看 passA4（用户 2026-10-18 裁定 #2 / #1；G10 合入后开，与 123 / 124 / 125 并行）
分支：w5-app-closeout（从 G10 快进后的 main 开）。只准动：App/。
先读：reports/G9.md §7.4（裁定表第 1 / 2 / 13 / 14 / 15 条）；reports/G10.md §4.3（G10 的 App 胶水做了哪几条——速率框钳位、ISOAppTests 断言若已做就不重做）；reports/p5-contracts-4.md §4 第 2 条（031：App 数字框没范围、老节目越界值打不开）；reports/w2-inputs-5.md §3（`FileInfo.displayWidth / displayHeight`）；reports/w5-app-fixes.md §3（D06 两个边角）/ §5（换节目排队、tee 不随来源换、`measurePoppedMenu`、无障碍源码扫描）；reports/w1-testkit-6.md §5（ISOAppTests 只断言极差）；docs/contract-changes/030-effect-latency-in-stats.md。

交付（先写红测试，用例名带编号）：
1. **速率数字框钳 0.1–8**（裁定 #2 (c)，G10 胶水没做的话）：添加输入面板与输入设置窗的播放速率框按 `FileSource.rateRange` 钳（NumberFormatter 的上下限 + 提交时钳位 + 提示一句）；打开含越界速率的老节目：读进来被契约拒之前先按界面口径提示"速率 x 超出 0.1–8"（怎么提示看 D04 那条打开事务里现有的错误路径），不静默。
2. **竖拍文件信息摘要**（117 §3）："添加输入"的文件信息用 `FileInfo.displayWidth / displayHeight`（转正后的尺寸），编码尺寸放括号里。
3. **D06 两个边角**（119 §3）：录着 ISO 时删这一路再加同编号——新路不接旧录制器（录制器停在删除那一拍、提示一句）；换源瞬间若有别的路注册，ISO 音轨的混音器槽位不换（跟着这一路的编号走）；两条用例。
4. **030 的界面展示**（裁定 #1 之后）：音频设置窗 / 状态窗显示每路与各总线效果链的处理延迟与压缩器实测值，**读 Stats 的 `audio.effects`**（铁律 4：不再直接读 `AudioEngineStatus`；压缩页"延迟自测"一行改读同一份）。
5. **ISOAppTests 看 passA4**（121 §5，G10 胶水没做的话）：A4 相关 App 用例在两个极差之外断言 `passA4 == true`。
6. `make test-app` 两遍 0 红、`make lint BRANCH=w5-app-closeout`。

不做：Stream Deck / 控制层；包里的东西；任何阈值。
报告 reports/w5-app-closeout.md 五段；不 push、不 merge。
