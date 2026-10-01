# APIServerTests 的 WS 用例在 Fade 进行中发 setPreview、断言 applied = true：W5-E 拒收规则合入后必红

归属会话 / 分支：SwitcherControl 测试（W2-C / `w2-control` 写的 `Packages/SwitcherControl/Tests/SwitcherControlTests/APIServerTests.swift`；
第五波里 `Packages/SwitcherControl/Tests/SwitcherControlTests/` 归 W5-J / `w5-app-settings-actions`，prompt 96）。
改动只有几行，G6 合 W5-E 时也可以按胶水（`~Packages/*:50`）改；用户批准的话 W5-E 也可以直接改（见 reports/w5-core-transition-guard.md §3）。
发现于：W5-E（prompt 90，分支 `w5-core-transition-guard`）实现"转场进行中拒收 setPreview / setProgram"（Q66 (a)，用户 2026-09-29 定）后跑 SwitcherControl 全包。

现象：`testAPI_wsEvents_helloSnapshotStatsReceiptAndTally` 失败，两处断言（W5-E 分支 041b0cc，2026-10-01；SwitcherControl 全包 58 个用例里其余 57 个 56 过、1 跳——跳的是原有的人工 C5 用例）：
```
APIServerTests.swift:274: XCTAssertEqual failed: ("Optional(false)") is not equal to ("Optional(true)")   ← 回执 applied
APIServerTests.swift:277: XCTAssertEqual failed: ("Optional(1)") is not equal to ("Optional(4)")         ← 快照 preview
```
用例前面先 Cut（PGM 2 / PVW 1），再 `schedule(.fade(durationTicks: 30), at: Tick(10))`、`prepare(upTo: Tick(20))`（2 → 1 的 Fade 走到 1/3，断言转场中的 tally），
然后"走 WS 发命令"发 `{"setPreview":{"input":4}}`，断言回执 `applied == true`、紧跟的快照 `preview == 4`。
命令落在第 20 拍，转场还在进行（到第 40 拍才对调），按新规则被 reducer 原样返回：回执 applied = false；快照照样推（状态机每条命令都发布），PVW 仍是 1。
这条用例拿 setPreview 当"随便一条 WS 命令"，碰巧发在转场中，不是在测"转场中能改 PVW"。

复现步骤：在 W5-E 分支上 `swift test --package-path Packages/SwitcherControl --filter SwitcherControlTests.APIServerTests/testAPI_wsEvents_helloSnapshotStatsReceiptAndTally`。

严重级：S3（测试用例跟规则不一致，产品行为是对的）；但不改的话 G6 合入 W5-E 之后 `make test` 红。

建议（任选其一）：
- (a) 发 WS 命令之前先 `await s.fixture.stateMachine.prepare(upTo: Tick(40))` 把 Fade 走完（会多推一条快照，用例要先 `receive` 掉它），其余断言不变；
- (b) 保持命令发在转场中，把断言改成新规则：回执 `applied == false`、快照 `preview` 仍是 1（:274 / :277 两行；顺带在 API 层覆盖"转场中被拒"）；
- (c) 换一条与转场无关的命令（例如 `renameInput`）当 WS 命令的例子。
(b) 最省事、还多覆盖一条规则；(a) / (c) 保留"applied = true + 快照跟着变"的覆盖。
