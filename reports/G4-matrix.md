## 编译矩阵（scripts/gate4-matrix.sh，2026-09-20 13:49–13:52）

SwitcherInputs 的可选 target（W3-A）在三种 SDK 配置下 `swift build` + `swift test --filter 'NDITests|DeckLinkTests'`（debug）。

| 配置 | 环境 | swift build | NDITests + DeckLinkTests | 通过 |
|---|---|---|---|---|
| A | 都在（本机默认）（`NOOP_MATRIX=1`） | ✅ | ✅ 37 个，失败 0，跳过 5：NDITests 20（跳过 2）、DeckLinkTests 17（跳过 3） | ✅ |
| B | 只有 NDI（`DECKLINK_SDK_DIR=/nonexistent`） | ✅ | ✅ 37 个，失败 0，跳过 12：NDITests 20（跳过 2）、DeckLinkTests 17（跳过 10） | ✅ |
| C | 都不在（`NDI_SDK_DIR=/nonexistent DECKLINK_SDK_DIR=/nonexistent`） | ✅ | ✅ 37 个，失败 0，跳过 20：NDITests 20（跳过 10）、DeckLinkTests 17（跳过 10） | ✅ |

- 日志：`.build/gate4/matrix/`。切配置只改环境变量（清单重新求值），最后按默认配置重编一次还原产物。跳过的用例：A = NDI 外部源手动项 + 无 SDK 行为用例、DeckLink 硬件项 L1 / L2 / S5；B = DeckLink Fake 7 条 + 硬件项（BLOCKED-SDK / 硬件）；C = NDI 回环 10 条（BLOCKED-SDK）+ DeckLink 同 B，无 SDK 行为用例真跑。
- 结论：**通过**。
