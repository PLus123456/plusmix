# P1 契约冻结 —— 报告（分支 p1-contracts）

日期 2026-09-13。机器 Apple M5 Max / macOS 26.4 / Xcode 26.6 / Swift 6.3.3。worktree `../plusmix-p1-contracts`，从 `main`（78f808d）开。
提交：见 `git log main..p1-contracts`（build × 2、contracts × 2、docs × 2、reports × 1）。

## 1. 做了什么

全部在 `Packages/SwitcherCore/Sources/SwitcherContracts/`（Swift，14 个文件）+ 其下 `C/`（CSwitcherContracts target：`sw_audio_ring.h` + `layout.c`）；测试 `Tests/SwitcherContractsTests/`（8 个文件，48 个测试）；`docs/CONTRACTS.md`（256 行）。公开 API 全部带文档注释。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 时间 | `Time.swift`：`MachTimebase` `HostClock` `HostTime` `HostDuration` `Rational` `FrameRate` `Tick` `TickClockSpec` | `time(of:)` / `tick(at:)` / `duration(ofTicks:)` 全是 Int128 一次乘除；`tick(at:)` 是严格逆 |
| 2 视频 | `Video.swift`：`PixelFormat` `ColorInfo`(+matrix) `RGB8` `YCbCr` `Frame`(@unchecked Sendable，注释写了为什么) `ProgramFormat` | |
| 3 帧槽 / 音频环 | `Slots.swift` 协议 + `FrameSlotStats` `AudioRingStats` `AudioReadResult` `AudioFormat`；`C/include/sw_audio_ring.h` 布局（256 B，v1） | 只定协议与布局，实现归 W1-B / W1-D；输入实现按注入拿它们 |
| 4 输入 | `Input.swift`：`InputKind` `InputState` `InputSource`(+`ScreenTarget` `FileEndAction` `SyntheticSourceSettings`) `InputSettings`(+crop/transform/audio/effects/keyer) `InputConfig` `Input` 协议 | 延迟补偿在 `InputAudioSettings.delayMs` 0–500 |
| 5 状态 / 命令 | `MixerState.swift`：`MixerState` `MixerSnapshot` `TransitionState` `FadeToBlack` `OverlayState` `AudioState` `BusState` `OutputState`(+settings) `Tally`；`Command.swift`：`Command`(27 case) `IssuedCommand` `CommandReceipt` `MixerReducing`(reduce / advance 签名) | tally 只在契约里算一次 |
| 6 Stats | `Stats.swift`，键名逐字 = 测试标准 §7；`jsonLine()` / `parse(line:)` / `parse(lines:)` | |
| 7 Show | `Show.swift`：`Show`(schemaVersion 1) `MixerSettings` `ShowLayout` `ShowError`；`save` / `load` / `migrate` 占位 | |
| 8 Scenario | `Scenario.swift` | |
| 9 TestPattern | `TestPattern.swift`：几何、CRC-4 码字、16 色调色板、BGRA / NV12 画与读、CVPixelBuffer 便利接口、闪光节奏 | 32 块 28 位（唯一偏离，写进 CONTRACTS.md §4） |
| 10 TestSignal | `TestSignal.swift` | click 窗口置满幅 +1.0 |
| 11 CONTRACTS.md | §1 术语对照、§2 每型一段（是什么 / 谁写 / 谁读 / 线程）、§3 口径、§4–5 工装、§6 线程规则检查表、§7 协议草案、§8 Command ↔ §9.1、§9 偏离清单 | |

`make lint` 绿；整仓 `make build` 绿；`make test`（六包 + 两工具冒烟 + App xcodebuild test）绿。

## 2. 每个测试：数值 / 阈值 / 通过否

P1 没有测试标准里的指标 ID，测试名以 `testP1_` 开头。48 个全部通过，SwitcherContractsTests 共 19 s（debug）。

| 测试 | 数值 | 阈值 / 要求 | 通过 |
|---|---|---|---|
| `tickTime_5994_tick216000_isExact` | 时基 125/3、1/1、本机三种下误差 = 0；24 MHz 下 = 86 486 400 000 tick；8 小时同样 0 | 误差 0 | ✅ |
| `tickTime_floatAccumulationDrifts` | 浮点累加 1 h 差 −7.1 ns，8 h 差 +1.26 µs | 证明 ≠ 0 | ✅ |
| `tickTime_intervalsNeverAccumulate` | 30/59.94/60/29.97/25 × 3 种时基，20000 拍相邻间隔 ∈ {⌊T⌋, ⌈T⌉}，第 n 拍 = ⌊n·T⌋ | 精确 | ✅ |
| `tickTime_tickAt_isExactInverse` | 4 帧率 × 3 时基 × 2000 随机拍：tick(at: time(of: n)) = n，前 1 tick = n−1 | 精确 | ✅ |
| `hostTime_conversionsUseTimebase` `rational_reducesAndCompares` `frameRate_presets` `tick_arithmetic` `time_codableShapes` | 换算、约分、128 位乘法、JSON 形态快照 | — | ✅ |
| `pattern_crc4_matchesIndependentReference` | 10 个值与 Python 独立实现一致 | 一致 | ✅ |
| `pattern_codewordRoundTrip100k` | 100 000 随机 28 位值编解码恒等 | 100% | ✅ |
| `pattern_checkCatchesSingleBlockFlip` | 5000 值 × 32 位单翻转全部返回 nil；全 0 / 全 1 字无效 | 100% | ✅ |
| `pattern_imageRoundTrip_bgra1080p` / `_nv12_1080p` / `_otherSizes` | 1080p BGRA 1500 帧、NV12 600 帧、720p/2160p/640×360/1366×768 × BGRA+NV12 各 100 帧，四项字段恒等 | 100% | ✅ |
| `pattern_degradedDecodeIs100Percent` | 高斯 σ=1.5（vImage 9×9）+ 色度 2×2 平均 + ±10 均匀噪声：60/60 帧四项全对 | 100% | ✅ |
| `pattern_bgraAndNV12Agree` `pattern_blankFramesDecodeToNil` | 两格式解码一致；全黑 / 全白 / 纯灰 128 → 帧号、时间、ID 都 nil | — | ✅ |
| `palette_pairwiseYCbCrDistance` | 16 色两两 BT.709 limited YCbCr 最小距离 56.6 | ≥ 48 | ✅ |
| `pattern_geometryAt1080pMatchesSpec` `_geometryScalesWithWidth` `_flashTick` `_contentFromHostTime` `_cvPixelBufferRoundTrip` | 布局数值、偶数对齐、闪光周期 60 拍 = 1001/1000 s、CVPixelBuffer BGRA/NV12 往返、UYVY 拒绝 | — | ✅ |
| `signal_toneLevelIsMinus20dBFS` | RMS 换算 −20.00 dBFS；1 kHz 峰谷位置正确 | ±0.05 dB | ✅ |
| `signal_clicksLandOnFlashInstants` | 60 / 59.94 两档 click 起点 = k × 48000 / 48048，窗口 48 样本 = 1.0 | 精确 | ✅ |
| `signal_driftShiftsClickIndexAndHostTime` | +100 ppm：click k 序号 = round(48004.8 k)，host time 偏离闪光 ≤ 10.4 µs | ≤ 1 样本 | ✅ |
| `signal_renderIsChunkIndependent` | 6 种块长拼接与整段逐样本相等；8 h 处仍正常 | 相等 | ✅ |
| `stats_jsonKeysSnapshot` | 整行 JSON 字面量钉死；顶层键集合 = §7 的 11 个 | 逐字 | ✅ |
| `stats_roundTrip` `mixerState_roundTrip` `show_roundTrip` `show_migratePlaceholder` `scenario_roundTrip` `inputTypes_codable` `jsonValue_roundTrip` | Codable 往返恒等；Show 顶层键 = 7 个；v2 / 缺 schemaVersion 抛错 | 恒等 | ✅ |
| `command_everyCaseRoundTrips` | 27 个 case 各 ≥ 1 样例往返；`caseName` 的 switch 无 default（加 case 不加样例编译红） | 全覆盖 | ✅ |
| `command_jsonShapeSnapshot` | 10 条命令 wire format 字面量 | 逐字 | ✅ |
| `audioRingHeader_layoutIsFrozen` `_inlineHelpers` | Swift 看到的 14 个 offset / size 256 / align 8 与 `layout.c` 一致；宏值；内联辅助 | 一致 | ✅ |
| `mixerState_defaults` `_validateCatchesBrokenInvariants` `_lookups` `tally_derivation` `inputSettings_clamped` `snapshot_isImmutableReferenceToState` `renderInputTable_reusesStorage` | 4 overlay / 4 bus 顺序、编号唯一、tally 8 种情形、范围钳制、表复用 | — | ✅ |
| `versionIsSemver` | 0.1.0 | — | ✅ |

BLOCKED：无。

## 3. 没做的和原因

- **`AudioRing` / `FrameSlot` 的实现**：按 prompt 只定协议和布局，实现归 W1-D / W1-B。
- **`reduce` / `advance` 的实现**：只定 `MixerReducing` 协议签名，归 W1-B。
- **Show 的真实迁移**：只有 v1，`migrate` 是占位（v1 恒等，其他版本抛 `unsupportedSchemaVersion`）。
- **命令合法性校验的签名**：没定。reduce 非法命令返回原状态；API 的 400 由 W2-C 对着快照自己判。要的话提案加。
- **`Stats.encoder` 的推流字段**（帧数 / 网络丢帧 / 重连次数）：§7 只有 skipped / bitrate，严格照抄；W2-D 需要时提案。
- **图像层 10 万帧往返**：10 万在码字层做；图像层 1080p 做了 2100 帧 + 其他尺寸 800 帧（debug 下每帧约 2 ms，10 万帧要 4 分钟）。

## 4. 对契约的疑问（等你拍板；细节在 CONTRACTS.md §9）

1. **Command 与信封分离**：`Command` 纯操作，`IssuedCommand{sequence, issuedAt, command}`。prompt 写"每条命令带 sequence 和 issuedAt"，我理解为总线上的信封；脚本 / API 里没有 host time。
2. **MixerState 多了 `format` 和 `inputs`**，`Show.mixer` 只是切换部分（`MixerSettings`）。否则 addInput / setInputSettings 在纯函数里无处落地，且 Show 里 inputs/audio/outputs 会存两份。
3. **每路输入音频参数只存在 `inputs[i].settings.audio`**，`AudioState` 无 perInput。prompt 两处都写了，我选了只存一份。
4. **`ftb` 是 `FadeToBlack{on, durationTicks, level}`** 而非 §4 的 Bool：§5 第 4 步"乘一个黑色比例"需要进度。
5. **命令比 §9.1 多 8 个**（setTransition / autoTransition / setOverlay / busGain / busMute / setAFV / renameInput / addOutput+removeOutput+setOutputSettings）：都是 W2/W3 prompt 已写明的功能。不要的话删 case 是一行事，但 W1-B 的 reduce 要同步。
6. **`startStream(dest)` 落成 `startStream(output:)`**：dest = 编号为 output 的 stream 输出，url/key 在它的 `OutputSettings.stream` 里；`startRecord(output:)` 同理，ISO = 同一拍发多条。
7. **`InputState.error(message:)` 带标签**；`ColorInfo` 多 `matrix`；`RGBColor` → `RGB8`、`Layout` → `ShowLayout`（与 QuickDraw / SwiftUI 同名类型冲突，`import Accelerate` 就撞）。
8. **Stats 的 render_ms / jitter_ms 口径**：窗口平均 / 窗口最大值（一个数）。每帧 p99 由 W1-C 在测试内直接测。若你要在 jsonl 里也有 p99，得改字段形态（提案）。
9. **C target 目录**：放在 `Sources/SwitcherContracts/C/`。若你更想要顶层 `Sources/CSwitcherContracts/`，在 OWNERSHIP.md 的 P1 行加这个 token，我搬回去（5 分钟）。
10. **调色板去掉了中灰**（换成蓝绿 0,128,128）：纯灰画面不该解出输入 ID。prompt 没规定颜色，只规定距离。

## 5. 下一个会话需要知道的坑

- **Swift 不导入 `_Alignas(64)` 的 C 结构**（"record is over aligned"，Swift 6.3.3 实测）。`sw_audio_ring` 用显式 padding 把两条计数放到偏移 128 / 192，结构自然对齐 8；**W1-D 分配环头必须自己保证 64 字节对齐**（`posix_memalign` / `allocate(byteCount:alignment: 64)`），`LayoutTests` 里有示范。
- **`@_exported import CSwitcherContracts`** 在 `SwitcherContracts.swift` 里；同一模块内其他文件仍要各自 `import CSwitcherContracts`（Slots.swift 就是）。下游 `import SwitcherContracts` 就能看到 `sw_audio_ring`。
- **`import Accelerate` / AppKit 会带进 QuickDraw 的 `RGBColor`**，所以契约里叫 `RGB8`。以后起名先 grep SDK：`Layout`、`Input`、`Frame` 这种短名都有撞车风险（`Layout` 已改 `ShowLayout`）。
- **Int 键字典 JSON 是对象**（SE-0320）：`Stats.per_input` 的 `[Int: PerInput]` 编成 `{"1": {...}}`，不用自己写 Codable。
- **枚举关联值必须全部带标签**，否则合成的 Codable 键是 `_0`。`Command` 加 case 时照做，并在 `Samples.commands()` 加样例（`caseName` 的 switch 会逼你）。
- **`Tick` 的 Codable 来自 RawRepresentable**（JSON 就是整数）；`HostTime` / `HostDuration` 自定义单值编码；`FrameRate` 编成 Rational 对象。
- **BSD sed 不认 `\b`**，批量改名用 perl。
- **TestPattern 的灰底是 full-range RGB 电平**：写 NV12 时换成 limited Y（64 → 71，192 → 181）。frameprobe 把 .mov 解成 BGRA 后拿到的又是 64 / 192，V7 的 (gray − 64) / 128 公式在 RGB 空间成立；W1-C 的 NV12 kernel 要按 BT.709 limited 做，否则这条链会差一个电平。
- **click 窗口是"置 +1.0"不是"相加"**，W2-E 的波形不连续检测器要把 click 窗口两端各算一次跳变。
- **`Geometry` 最小尺寸 320×180**（precondition）；所有坐标向下取偶。
- **测试时间**：SwitcherContractsTests 19 s，大头是退化解码 10 s（60 帧 vImage 卷积 + 逐像素 Swift 循环，debug）。想快就把帧数改小，别改阈值。
- **worktree 里 `make test` 会弹一次空 App 窗口**（P0 报告已提）。
