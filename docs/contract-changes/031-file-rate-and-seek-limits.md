# 031 文件播放速率与定位秒数的不变量（Codex 审查 D01：非法速率 / 超大定位值整个进程崩）

状态：**第 1–4 条已落地**（P5-4 / prompt 115，2026-10-18，分支 `p5-contracts-4`，提交 6348cfa；文字 75c4fb4；见文末落地记录）；第 5 条 FileInput 钳位归 117。原状态：**已批**（用户 2026-10-17 定"Codex 的崩溃 / 数据类 0.1.1 前必须修"；G9 写成提案记决定，归 P5-4 落地，prompt 115；校验器 116 在 CommandBus/ 用同一常量，FileInput 117 用同一常量钳位）。
来源：reports/codex-debug-audit-20261013.md §1.2 D01——`rate = 0 / −1 / 0.0001 / 1e300` 当前校验器和 reducer 都收，非正速率在 FileInput 的 precondition 崩、极小正数取倒数崩；`seekPlayback(seconds: 1e300)` 在钳到时长之前就做 Int64 换算溢出。主 API、节目文件、FileInput 三处都要同一条边界，单修 API 不够。

## 改什么

1. `InputSource.file` 的速率范围常量 `FileSource.rateRange: ClosedRange<Double>`：界面 rate 控件已有的范围优先（P5-4 落地时查 AddInputSheet / InputSettingsPanel 的控件）；没有就 **0.1 … 8**（W2-A4 实测 8 倍速带音频不饿）。非有限数、不在范围 = 非法。
2. `PlaybackLimits.maxSeekSeconds = 7 × 86 400`（一周；文件本身的时长再由 FileInput 钳）。非有限、负数、超上限 = 非法。
3. `MixerState.validate()` 对节目文件里 `file` 来源的 rate 不在范围报新错误 `MixerStateError.fileRate(input:rate:)`（loadShow 先 `migratingLegacyKeys()` 再 validate，P5-2 的先例；老文件 rate 缺键 = 1 不受影响）。
4. CommandValidator（116 的目录 CommandBus/ 这三条由 115 顺手改，116 不再碰）：`setInputSource` / `addInput` 的 file 来源按 `rateRange` 拒（400 "播放速率必须在 0.1–8 之间"）、`seekPlayback(seconds:)` 按 `maxSeekSeconds` 拒（原来只查有限非负）。
5. FileInput（117）：`precondition(rate > 0 && rate.isFinite)` 改成钳进 `rateRange` + `lastError` 一句；seek 先用 Double 钳到 [0, duration] 再换 Rational / Int64。

## 为什么

同一条边界三处共用，才不会 API 拒了、节目文件绕过去、底层仍崩（Codex 的原话："修复需同时覆盖 API、节目文件和 FileInput 底层转换边界"）。

## 影响谁、怎么迁移

- 契约：两个常量 + 一个 `MixerStateError` case；JSON 形态不变、命令数仍 42。
- 老节目文件里 rate 超范围（没人这么写过，界面写不出来）→ 读进来 validate 报错，与别的不变量同一处理（提示 + 不打开）。
- docs/CONTRACTS.md §（输入来源）一句；docs/api.md 重生成（校验器描述变）。

## 落地记录（P5-4 / prompt 115，2026-10-18）

分支 `p5-contracts-4`，提交 6348cfa（契约 + reducer + 校验器 + 目录 + docs/api.md），CONTRACTS.md 的文字 75c4fb4。第 1–4 条落了；第 5 条（FileInput）归 117，没动。

- **常量**（Input.swift）：`FileSource.rateRange: ClosedRange<Double> = 0.1...8`、`PlaybackLimits.maxSeekSeconds: Double = 7 * 86_400`（两个只放常量的 enum）。界面 rate 控件查过：App 的添加输入面板与输入设置"来源"节共用的"播放速率"是 `TextField(value:format: .number)`，没有范围（AddInputSheet 只做 `fileRate > 0 ? fileRate : 1`），所以按正文默认 0.1…8。
  非法的判法一律 `range.contains(x)`（对 NaN / ±∞ 给 false），没另加判定函数。
- **`MixerStateError.fileRate(input:rate:)`**；`validate()` 对 file 来源的 rate 不在范围抛它（Show.load / loadShow 先搬迁再 validate，读到不打开）。
- **校验器**（CommandValidator）：`setInputSource` / `addInput` 的 file 来源"播放速率必须在 0.1–8 之间：<值>"、`seekPlayback`"定位秒数必须在 0–604800 之间（一周）：<值>"（原来只查有限非负），HTTP 400；文字从常量生成（`fileRateRangeText` / `maxSeekText`，目录摘要共用）。
  **reducer 同判**：addInput / setInputSource 越界原样返回、seekPlayback 用 `(0...maxSeekSeconds).contains`——`testValidator_agreesWithReducer` 要求"校验器拒的 reducer 一定原样返回"，所以 reducer 这半一起落了（直接发给状态机的脚本 / 测试同样进不去）。
- **目录**：setInputSource / addInput / seekPlayback 三条摘要写明边界 → docs/api.md 重生成（仍 42 条）。
- **与正文不同 / 多做的两处**：
  1. **"老文件 rate 缺键 = 1"在 main 上原来不成立**：`InputSource` 的 file case 走合成 Codable、rate 必填，探针证实缺键直接 keyNotFound、整份节目读不进来（不是"不受影响"）。按正文的意思补成真的：内部 Form 的 rate 改成可选、缺键解成 1，写出照旧总是写 rate（逐字不变，`Contracts014Tests` / `ContractsP3Tests` 的快照没动）。
  2. **`InputSettings.clamped()` 把 `playback.seekSeconds` 钳到 [0, 一周]**（原来只钳 ≥ 0）：`setInputSettings` / `addInput` 整体带进来的定位请求是 seekPlayback 之外的第二个入口（组装方看到 (seekTick, seekSeconds) 变了就交给 FileInput），同一个 1e300 从这里进来还是崩；与 021 "seekPlayback 拒、setInputSettings 钳负数"同一做法——钳，不拒。
- **用例**：`Contracts031Tests` 4 条（常量；validate + Show.load；缺 rate = 1 + 写出不变；clamped 的上限）、`ReducerTests.testW1B_reduce_everyCommand_beforeAfterTable` 加 9 行、`CommandBusTests.testValidator_agreesWithReducer`（合法 +4 / 非法 +10）与 `test031_fileRateAndSeekSecondsOutOfRange_rejectedWithReason`、
  `APIServerTests.test031_postCommand_fileRateAndSeekOutOfRange_400`（真 HTTP：rate 0 / −1 / 1e300、seconds 1e300 → 400 带理由、不占 sequence，rate 8 → 200）、`CommandCatalogTests.testCatalog_031_fileRateAndSeekLimitsDocumented`。
- **还没堵上的**：117 合入之前，绕过状态机直接构造 `FileInput(rate:)` / 调 `seek(toSeconds:)` 的路径仍会崩；App / headless 的运行表都从状态快照来（启动时 `validate()`、之后命令进不了越界值），这条路现在走不到。
- **迁移的副作用**（报告 §4）：App 的速率数字框能写出 0.05、10 这类值——P5-4 之前存下这种节目，现在打开会被 validate 拒（"不打开"），添加 / 应用来源会 400。界面钳位或给老文件做搬迁要用户定、归 App 会话。

## 落地记录与 2026-10-18 用户裁定

- P5-4（29a64ad）：`FileSource.rateRange` = 0.1…8、`PlaybackLimits.maxSeekSeconds` = 7 × 86 400、`MixerStateError.fileRate`、校验器三条 400；**老文件缺 rate 键读成 1**（main 上原来整份读不进来，探针证实，按本提案的意思补）；`clamped()` 顺带把 `setInputSettings` 的定位秒数钳到一周（第二条定位入口，钳不是拒）——用户 2026-10-18 定**维持**。
- W2-A5（7a35448，叠在 P5-4 上）：FileInput 的 precondition 改成钳进范围 + lastError、seek 先用 Double 钳再换 Rational / Int64；**定位过尾仍 = 从头**（1e300 / +∞ / 过尾都从第 0 帧播，不是停在末帧）——用户 2026-10-18 定**维持**；NaN 速率按 1 播。
- 迁移副作用比正文写的大：App 的速率数字框没设范围，0.05 / 10 能写进节目文件，这种老节目现在打不开、界面填了被 400——用户 2026-10-18 定 **(c) App 把数字框钳到 0.1–8**（G10 胶水 ≤ 20 行，超了归 126 W5-Q）。
