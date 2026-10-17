# gate3-report.py 的 A4 只看 maxClickSpreadMs：W1-A6 加的"判定事件里有文件缺 click 算不过"到不了 gate 的判定

归属会话 / 分支：G10（`g10`，prompt 122；scripts/ 归检查点）；App / Outputs 两条 ISO 用例各归原会话（见"顺带"）
发现于：W1-A6 / `w1-testkit-6`，2026-10-18，prompt 121 交付 2
严重级：S3（只影响量法；在缺 click 的录像上 gate 的 A4 行会误判"通过"，G8 / G9 的产物上没有这种事件，结论不变）

## 现象

用户 2026-10-17 对 113 的裁定（测试标准 §2.3）："判定事件里有文件缺 click 算 A4 不过"。W1-A6 在 frameprobe 里落实了：
`multi.events[*].missingClickFiles` 列出缺的文件、`multi.missingClickEventCount` 计数、有缺的 `multi.passA4 = false`。
但按用户裁定"那一格照旧 nil、极差只算剩下的"，**`maxClickSpreadMs` 的数字不变**——而 `scripts/gate3-report.py` 第 366–368 行：

```python
multi = av_multi.get("multi", {}) if av_multi else {}
a4_max = multi.get("maxClickSpreadMs")
a4_ok = a4_max is not None and a4_max <= frame_ms
```

只看极差、不看 `passA4`。一个文件整秒的 click 丢了，gate4 的 A4 行照样 ✅。

## 复现步骤

`swift test --package-path Packages/SwitcherTestKit --filter SwitcherTestKitTests.FrameAnalysisTests/testA4_avMulti_fileMissingClickInJudgedEvent_failsA4`
（第 5 s 那个事件 [2] 没有 click：`maxClickSpreadMs` = 0.02 ms，`passA4` = false，`missingClickEventCount` = 1）；
把这个 `MultiFileAVReport` 写成 probe-av-multi.json 交给 gate3-report.py，A4 行判过。

## 建议

- gate3-report.py：`a4_ok = a4_max is not None and a4_max <= frame_ms and multi.get("passA4") is not False`，
  A4 那一格的说明里带上 `missingClickEventCount`（> 0 时写"n 个判定事件有文件缺 click"）。老 JSON 没有这两个字段（`passA4` 一直有），
  `is not False` 对老 JSON 与新 JSON 都对。字段名一个没改。
- 顺带（只读给各自的会话）：`App/Tests/ISOAppTests.swift`（App 会话）与 `Packages/SwitcherOutputs/Tests/ISOTests/ISOAlignmentTests.swift`（W3-C）
  也只断言 `maxFlashSpreadMs` / `maxClickSpreadMs`，要让缺 click 也红，各加一句 `XCTAssertNotEqual(multi["passA4"] as? Bool, false)`。
- G8 / G9 的产物用 W1-A6 的 release frameprobe 重算：判定事件里缺 click 的 0 个，`passA4` 都是 true（reports/w1-testkit-6.md §2），改了脚本结论也不变。
