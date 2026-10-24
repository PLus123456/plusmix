# 032 输入编号的上限 1…16（W2-C4 查出的 S1：主 API 加一路编号极大的输入，兼容层 TALLY / XML 按编号分配崩或卡）

状态：**已批**（用户 2026-10-18"22 条都按建议"——reports/G9.md §7.4 裁定表第 8 条：输入编号没上限当 S1 进 KNOWN_ISSUES、契约加编号上限不变量，归 123 P5-5；本文件只记决定，不再停下来问）；
**P5-5（prompt 123，分支 `p5-contracts-5`）已落地**（见文末落地记录）。
来源：reports/w2-control-4.md §3 第 4 条（W2-C4 过兼容层时查出，没写红用例）；reports/G10.md §7 阻塞项第 1 条（0.1.1 唯一的 S1）；docs/KNOWN_ISSUES.md"输入编号没有上限"一行。

## 改什么

1. 契约常量 `InputConfig.numberRange: ClosedRange<Int> = 1...16`——与 App"添加输入满 16 路"（`AddInputModel.nextFreeNumber` / `MainWindowController.freeInputNumber` 在 1…`engine.maxInputs` 里挑空号）和引擎默认 `Engine(maxInputs: 16)` 一致。
2. `MixerStateError.inputNumber(input:)`；`MixerState.validate()` 对编号超过 16 的输入抛它（0 与负数照旧 `reservedInputNumber`）。Show.load / loadShow 先搬迁再 validate，读到不打开——与 031 的 `fileRate`、020 的转场槽同一处理。
3. `CommandValidator`：`addInput` 的编号不在 1…16 → HTTP 400"输入编号必须在 1–16 之间：<n>"（原来只查 ≥ 1，原文案"输入编号必须 ≥ 1"并进这一句）；reducer 同判、原样返回（`testValidator_agreesWithReducer` 要求两边一致）。
   按编号取输入的命令（setInputSource / setPreview / audioGain / removeInput……）照旧：越界的编号进不了状态，永远"输入 n 不存在"（400）。
4. 兼容层不改：编号有界之后 TALLY 串（`reserveCapacity(最大编号)`）与 XML 占位（1…最大编号）最多 16 位 / 16 个。

## 为什么

- 主 API 的 `addInput` 只查"≥ 1、不重复"：加一路 2^62 号之后，开着兼容层时 TALLY 的 `reserveCapacity(2^62)` 分配失败崩、XML 按 1…2^62 逐个写占位卡死（W2-C4 §3 第 4 条）；节目文件 / loadShow 也能把这种编号带进来，
  App / headless 打开这种节目时 `Engine(maxInputs: max(16, 最大编号))` 按编号建渲染输入表，同样是一次按编号的分配。App 自己只在 1…16 里分配编号，越界编号只能从 API / 文件进来。
- W2-C4 给的两条修法里选"编号有上限"：另一条（兼容层只写到某个上限）会改 TALLY / XML 的形状（上游客户端按位置取），而且只护住兼容层；一条不变量让所有按编号分配的读者
  （兼容层、`OfflineRenderer` 的"最大编号 + 1"、App `SwitcherSession` / headless `HeadlessRun` 的 `max(16, 最大编号)`）一起安全。
- 16 = App 与引擎现在的上限。多画面标签槽上限 64（`LabelSet.maxInputSlots`）、测试图案调色板 16 色（`patternID` 默认 (编号 − 1) mod 16）都不受影响。

## 影响谁、怎么迁移

- 契约：一个常量 + 一个 `MixerStateError` case；JSON 形态不变（编号仍是一个整数，范围只在 validate / 校验器里查，解码不拒）、不加命令（仍 42 条）；docs/api.md 重生成（addInput 一条写明 1–16）。
- 老节目文件：编号超过 16 的读进来 validate 报错、不打开（与别的不变量同一处理）。仓库带的 Samples/ 三份、scenarios/ 四份、契约测试的 P3 之前的 g4 老节目编号都在 1…9（`Contracts032Tests.test032_shippedShowsWithinRange_stillLoad` 钉住）；
  App 写不出超过 16 的编号；headless `make-scenario --inputs n` 的 n > 16 写出的节目从此载入被拒（仓库里没有脚本这么用）。
- App / headless：`Engine(maxInputs: max(16, 最大编号))` 从此恒为 16（validate 过的节目最大编号 ≤ 16），不用改；打开越界老节目时走现有"节目文件不合法"那一路的提示。
- 兼容层 / Tally：代码不改。"主 API 加极大编号之后 TALLY / XML 照常应答"的回归用例按 prompt 123 应进 VMixCompatTests，但 VMixCompat 不在 P5-5 的目录——P5-5 用临时探针在本分支上跑过（落地记录），
  用例全文交 G 类会话或 W2-C 系：reports/issues/P55-w2-control-vmixcompat-huge-input-number-test.md。

## 不做

- 不改兼容层 TALLY / XML 的形状；不查引用（叠加 / Stinger / 多画面格子 / 输出来源里写的编号仍按"没有这路"处理，`validate()` 只查结构，用户 2026-09-27 定）。
- 输出编号不设上限：不在本条裁定里（App 按"最大输出编号 + 1"给新输出编号，最大编号是 `Int.max` 时溢出，见 reports/p5-contracts-5.md §4，要不要同样设上限请用户定）。

## 落地记录（P5-5 / prompt 123，2026-10-24）

分支 `p5-contracts-5`。按正文落了，没有与正文不同的地方。

- **契约**：`InputConfig.numberRange = 1...16`（Input.swift，紧挨着 `jsonKeys`）；`MixerStateError.inputNumber(input:)`；`validate()` 在"编号 ≥ 1"之后、"不重复"之前查上限（所以 0 / 负数仍报 `reservedInputNumber`、17 号重复两次报 `inputNumber(17)`）。
- **reducer**：`addInput` 的 `config.number > noInput` 换成 `numberRange.contains`（同一条判断把下限也包了），越界原样返回；loadShow 本来就先 validate。
- **校验器**：`addInput` 越界 → "输入编号必须在 1–16 之间：<n>"（文字由 `CommandValidator.inputNumberRangeText` 从常量生成，命令目录共用）；0 / 负数也走这一句（原来"输入编号必须 ≥ 1"）。
- **命令目录**：addInput 摘要"编号须在 1–16 之间（提案 032）、已存在则拒绝……"、参数说明"number（1–16）"→ docs/api.md 重生成，只变这两行，仍 42 条。
- **用例**（先红后绿，红灯日志见 reports/p5-contracts-5.md §2）：`Contracts032Tests` 4 条（常量；validate + Show.load，含 JSON 里直接写 2^62；仓库带的节目都在范围里照读；InputConfig 键与写出形态不变）、
  `ReducerTests.test032_addInputAndLoadShow_inputNumberAboveRangeRefused`（17 / 99 / 2^62 / Int.max 原样返回、16 照收、loadShow 带 17 号不载入、状态机回执 applied = false）与 everyCommand 表 3 行、
  `CommandBusTests.test032_inputNumberAboveRange_rejectedWithReason`（总线 400 带理由、不占 sequence、按编号取输入的命令照旧"不存在"、加满 16 路后 17 号仍拒）与 `testValidator_agreesWithReducer`（合法 +2 / 非法 +8）、
  `APIServerTests.test032_postCommand_inputNumberAboveRange_400`（真 HTTP：2^62 / 17 → 400 带理由，修前是 200、状态里留下 `[1, 2, 3, 4, 16, 17, 4611686018427387904]`）、`CommandCatalogTests.testCatalog_032_inputNumberRangeDocumented`。
- **兼容层确认**（116 报告 §3 的触发条件，临时探针、没提交）：同一套状态机 + 总线上起主 API 和兼容层，主 API POST addInput 2^62 / Int.max / 17 → 400；绕过校验器直接发给状态机 → reducer 不收；
  兼容层 TCP `TALLY` → `TALLY OK 1200`、TCP `XML` 与 HTTP `/api` 都照常应答（2056 字节）。修前的树上同一触发条件的结果见报告 §2。
