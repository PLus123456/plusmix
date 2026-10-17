# 031 文件播放速率与定位秒数的不变量（Codex 审查 D01：非法速率 / 超大定位值整个进程崩）

状态：**已批**（用户 2026-10-17 定"Codex 的崩溃 / 数据类 0.1.1 前必须修"；G9 写成提案记决定，归 P5-4 落地，prompt 115；校验器 116 在 CommandBus/ 用同一常量，FileInput 117 用同一常量钳位）。
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
