# 打开数值越界的节目文件时，"打开失败"提示框第二行是枚举原样（034 的 `durationTicks(…)` / `format(…)` / `overlayCount(…)` 等，与 `inputNumber(input: 17)` 同一类）

归属会话 / 分支：下一个 App 会话（W5 系；若 128 P5-6 照 KNOWN_ISSUES 那条去补 `inputNumber` 的 catch，最好顺手一起做）
发现于：W4-C5（prompt 135，分支 `w4-docs-5`）写故障排查 §7"打开越界节目"那一行时
严重级：S3（文案是程序写法，不伤节目；文件本来就打不开）

## 现象

034（P5-7）之后 `Show.load` 对越界的节目文件抛错、不打开：格式宽高 16–8192、帧率 1–240 fps、四处时长 0–864 000 拍、音频对齐帧数 0–24 000、叠加恰好 4 个、
屏幕输入 / 合成源的帧率与尺寸。App 走现有的"打开失败"提示（`AppController.presentError`，App/Sources/AppController.swift:736）：

```swift
let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
```

`MixerStateError` 不是 `LocalizedError`，`ShowDocuments.load`（App/Sources/Show/ShowDocuments.swift:82）只把 `.fileRate` 换成了按界面口径的 `OutOfRangeFileRates`，
其余照原样抛，所以提示框第二行是 Swift 的默认描述。本会话用 swift 探针（Swift 6.4，Xcode 27.x）确认了实际文字：

| 越界的 | 提示框第二行 |
|---|---|
| 时长（转场 / 槽 / FTB / 叠加动画） | `durationTicks(900000)` |
| 叠加个数 | `overlayCount(0)` |
| 某路屏幕 / 合成源帧率 | `inputFrameRate(input: 3)` |
| 节目格式 | `format(SwitcherContracts.ProgramFormat(width: …, height: …, frameRate: …))`（推断，同一个默认描述规则） |
| 音频对齐帧数 | `alignmentFrames(99999)`（推断，同上） |
| 帧率 ≤ 0（解码阶段） | `DecodingError.dataCorrupted: Data was corrupted. Path: …. Debug description: 帧率必须为正` |

手册现在照实写了这一行（docs/user/故障排查.md §7、en/troubleshooting.md §7：列出范围与这几个名字对应哪一项，叫用户用文本编辑器改）。
KNOWN_ISSUES 产品缺陷表"W4-C4 口径缺口剩下的"那一行只记了 `inputNumber(input: 17)`（→ 128），034 这几种没记。

## 建议

- 在 App 里给 `MixerStateError` 补一个界面口径的描述（`ShowDocuments.load` 里 catch 成一个 `LocalizedError`，或 App 侧 `extension MixerStateError: LocalizedError`——契约类型不动），
  一句话说清"哪一项、多少、范围是多少、怎么改"，同 `OutOfRangeFileRates` 的做法；`DecodingError` 里带"帧率必须为正"的也换成一句人话。
- 用例：照 `Contracts034Tests` 的几份坏 JSON 各打开一次，断言 `lastPresentedError` 的第二行不含 `(` 开头的枚举写法、含范围数字。
- 修了告诉文档会话：故障排查 §7 那一行改成新的提示原文。
