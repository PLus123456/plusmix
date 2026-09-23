# 018 显示类输出的 Stats 加 `undelivered`（不在呈现 / 发布时没送出去的帧），并把 `dropped` 的口径钉死

提出会话 / 分支：W3-C2 / w3-outputs-3（2026-09-23；来源：本分支复核 013 的填数时把虚拟摄像头的 dropped 收窄成"被扩展丢弃"，
扩展没装时丢的帧从此不在 Stats 里——reports/w3-outputs-3.md §4 第 2 条；用户 2026-09-23："dropped 走提案吧"）
状态：**待批**

## 改什么

### A. `Stats.DisplayEntry` 加一个字段 `undelivered`（JSON 键 `undelivered`；缺键 = 0，写出总是写）

```swift
/// 输出拿到（或该拿到）、但因为当时不在呈现 / 发布而没送出去的帧数，累计（提案 018）。与 dropped 不重叠。
/// - virtualCamera：扩展没装 / 没激活 / 没连上期间收到就丢掉的 PGM 帧（含那段时间本端队列满挤掉的）；
/// - externalDisplay：窗口收起（目标显示器不在）或被遮住期间，当前这个源出了、窗口没画的帧（换源不算：换之前的源不是这个输出的）；
/// - multiviewWindow / monitor：同 externalDisplay 的口径（组装方用 DisplayFrameLedger 记；不记就是 0）。
public var undelivered: UInt64
```

- 位置在 `dropped` 之后：`jsonKeys = ["output", "kind", "frames", "dropped", "undelivered", "state"]`。
- `init(output:kind:frames:dropped:undelivered:state:)`，`undelivered` 默认 0——现有的 `DisplayEntry(output:kind:frames:dropped:state:)` 调用点照样编得过。
- 显式 `init(from:)` 里 `decodeIfPresent(… .undelivered) ?? 0`。

### B. `dropped` 的注释收紧（键与类型不变）

```swift
/// 在呈现 / 发布的时候没送出去的帧数，累计：显示类 = 引擎给了新帧、两次显示刷新之间就被覆盖的；
/// 虚拟摄像头 = 连上之后本端队列满 + 排不进 sink（扩展没及时取）+ 扩展收了没输出的。不在呈现 / 发布时的进 undelivered。
```
（013 原文是"没赶上显示刷新 / 被扩展丢弃的帧数"，本分支已按这个意思实现；这里只是写清楚边界。）

### C. 口径上的一条性质（写进注释，gate 可以核）

显示类（externalDisplay / multiviewWindow / monitor）在一段时间里：**frames + dropped + undelivered ≈ 这段时间里当前源出的新帧数**（差的是首尾还在路上的一两帧）。
W3-C2 的 `testStats_droppedCountsFramesOverwrittenBetweenRefreshes` 已经对 frames + dropped 核过这条（240 fps 源 → 120 Hz 屏，差 ≤ 2）。
虚拟摄像头的 frames 是"扩展收到的"，扩展收了没输出的那部分同时记在 dropped 里（013 起就是这样），所以不套这条；它的守恒是
`countersSnapshot.framesIn = frames + 本端队列满 + 排不进 sink + undelivered`。

## 为什么

- **铁律 4**：所有数字进 Stats。W3-C2 之前，虚拟摄像头"扩展没装时丢了多少帧"混在 dropped 里；W3-C2 按契约注释把 dropped 收窄之后，
  这个数只剩 `VirtualCameraOutput.countersSnapshot.droppedNoDevice` 一处，Stats / API / 测试都看不到。W3-E2 的状态行"找不到虚拟摄像头设备…已丢 n 帧"
  取的是 Stats 的 dropped，合并后会恒为 0（reports/issues/W3C2-app-aux-wiring.md §4）。
- **两种事不能混在一个数里**：dropped 回答"在跑的时候跟不跟得上"（有负载时才涨，gate 判"无负载 dropped 0"），undelivered 回答"有多长时间没在送"
  （扩展没装、显示器拔了、窗口被盖住）。混在一起的话，扩展没装的机器上 dropped 每秒涨 60，"dropped 0"的判定就永远红；分开以后两个判定各管各的。
- 外部显示同理：W3-C2 现在把"收起 / 被遮住期间没画的帧"直接丢掉不记（只为了不污染 dropped），有了这个字段就能记下来——拔线测试（清单）可以直接看
  "拔掉这段 undelivered 涨了多少、插回来 dropped 仍是 0"。

## 考虑过的别的做法

1. **回到 P3 的口径**（dropped 含没连上时丢的，不加字段）：不动契约，但两种事混在一起（上面第二条），也和 013 的注释"被扩展丢弃"对不上。
2. **维持 W3-C2 现状**（不加字段）：那个数留在 Stats 之外，违反铁律 4；W3-E2 的"已丢 n 帧"只能删掉或绕开 Stats 去读对象。
3. **只给虚拟摄像头填、显示类恒 0**（本提案的最小版）：契约一样加字段，填数只改 `VirtualCameraOutput.statsEntry` 一行；外部显示以后再补。可以接受，但外部显示那边的数现成就有（下面第 3 条），建议一起做。

## 影响谁

| 谁 | 改什么 |
|---|---|
| SwitcherContracts（`Stats.swift`） | `DisplayEntry` 加字段、`init` 默认参数、`init(from:)` 缺键 0、`jsonKeys`；`dropped` 注释（B） |
| SwitcherContractsTests | `CodableTests` 钉 `jsonKeys` 那一行；`ContractsP3Tests` / `Samples.swift` 的往返样例加 undelivered；补"老 display 条目缺键 = 0" |
| docs/CONTRACTS.md §2.7、测试标准 §7 | display[] 的字段列表加 `undelivered` 与一句含义（测试标准由用户改或授权） |
| SwitcherOutputs `VirtualCamera/` | `statsEntry`：`undelivered = droppedNoDevice`（计数已有，一行） |
| SwitcherOutputs `External/` | `DisplayFrameLedger`：断开（收起 / 遮挡）前记住最后画出的版本，恢复后第一帧与它的版本差 − 1 记进 undelivered（换源才彻底断开不记）；`AuxInputPresenter`：不在呈现的时段里帧槽分支的 dropped 增量记进 undelivered（换输入不记）；`ExternalDisplayWindow.undeliveredFrames` → `statsEntries` |
| SwitcherTestKit `Stats/StatsSummary` | `DisplaySummary` 加 `undelivered`（末行 − 首行），解码缺键 = 0（老摘要 / 基线原样可解；现有基线 g4-m5max.json 没有 displays） |
| App | `OutputStatusText.virtualCamera` 的 waitingExtension 文案改读 `undelivered`（W3-E2 的"已丢 n 帧"就对了）；`MainWindowController` 的两项不改也编得过（默认 0），要记就接 `DisplayFrameLedger` |
| headless | 不涉及（没有显示类输出，display 写空数组） |

分支：w3-outputs-3（本分支）与 w3-app-3（W3-E2）都没合并；若批了，契约改动落在哪个分支上，另一个合并时顺序在后即可，不用 rebase。

## 怎么迁移

缺键 = 0：老 stats.jsonl、老摘要原样可解；写出总是写全。不涉及 Show（`schemaVersion` 不升）。

## 谁来落地（建议，等用户定）

照 014 / 015 的先例：用户批了并授权的话，由 **W3-C2 在本分支**一次做完——契约那几行 + 两处测试 + CONTRACTS.md 一句 + External / VirtualCamera 的填数 + TestKit `DisplaySummary` 一个字段，
OWNERSHIP 的 W3-C2 行记上授权与多出的文件；App 的文案（`OutputStatusText`）留给合并检查点或 W3-E2 之后的 App 会话。不授权就按惯例交给下一个契约会话（P 系列），本分支维持现状。
