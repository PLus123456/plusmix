# docs/api.md 的 setBusEffects / setPreview / setProgram 说明还是总线效果接线前、转场拒收前的口径——它是生成物，要改 CommandCatalog

归属会话 / 分支：P5（prompt 99，`p5-contracts`：`Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/` 与 `docs/api.md` 在它的归属行里）；P5 已开工的话交给下一个动 CommandCatalog 的会话
发现于：W4-C2（prompt 103，分支 `w4-docs-2`），提交 3c674fb；照 reports/w5-audio-bus-effects.md §1.6 与 reports/w5-core-transition-guard.md §3 第 6 条改 API 文档时
现象：
- `docs/api.md` 由 `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md` 生成，`CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` 钉着它与生成器一致——**文档会话不能手改**，手改那条用例就红。
- `setBusEffects` 一节只写"整体替换一条总线的效果链；链顺序 = 处理顺序，enabled = false 的格旁路"。W5-C（88）接线之后还应写明（W5-C 报告 §1.6 原话的要点）：
  `q` 是经典 Q（半增益处带宽）；连续的 `parametricEQ` 合成一格、一格最多 16 段；每条总线最多 3 格（被别的效果隔开的 EQ 另占一格），超出 / 认不出的 `id` 不装；
  参数超范围被钳；开了压缩 / 限幅的总线，消费者流（录制 / 推流 / NDI）的 PTS 已扣掉处理延迟，本机监听会晚 5–35 ms。
- `setPreview` / `setProgram` 的说明没写"转场进行中（`transition.isActive`，含 T-bar 推到一半）被忽略，回执 applied = false"（W5-E / 提案 023 第一节，已批）。
- W4-C2 先把这些口径写进了手写的 `docs/api/README.md` §6"几条命令的现行口径"，所以读 API 文档的人现在能找到；`docs/api.md` 里那几句仍是旧口径。
复现步骤：读 `docs/api.md` 的 `#### setBusEffects`、`#### setPreview`、`#### setProgram` 三节，对照 reports/w5-audio-bus-effects.md §1.2 / §1.3 / §1.5 与 MixerReducer.swift 的 `case .setPreview` / `case .setProgram`。
严重级：S3（文档与实现不一致）
建议：在 `CommandCatalog` 这三条命令的 summary / 参数说明里补上述口径，重生成 `docs/api.md`；补完后可以把 `docs/api/README.md` §6 里重复的部分删成一句链接（归文档会话，103 的后续）。
