# W3-E 界面二期（设置面板、调音台、面板与窗口）报告

分支 `claude/w3-app2-ui-panels-828cd5`（桌面端开的 worktree 分支；prompt 里叫 `w3-app2`，本地另打了同名引用 `git branch -f w3-app2 HEAD` 给 `check-ownership.sh` 用，同 W2-B2 的做法）。
基于 main `f1bd1ee`（G3 合入后）。机器：MacBook Pro M5 Max，macOS 26.6.2，Xcode 27.0（Swift 6.4），接电源，只有内置屏。

## 1. 做了什么

只动了 `App/`（+ 本报告、`docs/contract-changes/008`）。SwiftUI 表单全部放 NSHostingView（设计方案 §10），模型只发 Command、只读快照（W2-B 的绑定规则）。

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 Add Input 完整 | `UI/AddInputSheet.swift`（重写为 SwiftUI） | 八种类型（设计方案 §6：合成源、摄像头 / 采集卡、DeckLink、屏幕 / 窗口 / 应用、视频文件、图片、NDI、纯音频设备），各自参数页（合成源含 `SyntheticSourceSettings` 全部项；屏幕含窗口 / 应用列表（ScreenCaptureKit，选到才取）、帧率、系统音频；文件含播完动作 / 速率；音频设备列 Core Audio 有输入声道的设备），编号选择。DeckLink 设备列表 / NDI 源发现在 W3-A，合入前手填标识 |
| 2 输入设置窗 | `Settings/InputSettingsPanel.swift` | 六节：基本（改名）、裁切 / 变换、音频（增益 / 静音 / 独听 / 声像 / 延迟补偿 0–500 ms / 四总线送出）、抠像（键色 / 容差 / 柔化 / 溢色）、效果链、来源（只读摘要 + DeckLink / NDI 特有项占位，见 §4）。缩略图右键"设置…"、调音台条子"设置…"、输入菜单都能开 |
| 3 输出设置 | `Settings/OutputSettingsPanel.swift`、`Settings/VirtualCameraSupport.swift` | 六页：录制（编码器 H.264 / HEVC / ProRes ×3、容器 .mov / .mp4、分辨率、码率、关键帧间隔、音频编码、目录、文件名模板 + 示例、片段间隔、停止后转 MP4）、ISO 路选择（每路一个 source = .input(n) 的录制输出）、推流目的地列表（地址 / 密钥 / 重连上限 / 每路编码参数，加删）、外部显示（屏 × 来源，加删）、NDI 发送（源名 / 分组 / 转换 auto|gpu|cpu = W2-D 的 `ndi.conversion` 键 / 来源）、虚拟摄像头（开关 + 来源 + 安装状态：`OSSystemExtensionRequest` 属性查询 / 激活 / 卸载，扩展 bundle ID 从 Info.plist 的 `SwitcherCameraExtensionBundleID` 读，W3-C 定） |
| 4 调音台完整 | `UI/MixerPanelView.swift`（重写：AppKit 容器 + SwiftUI） | 每路条子：表（AudioEngineStatus 50 ms）、竖推子（audioGain）、静音、独听、声像、M/A/B/H 送出、AFV 门控增益显示、设置按钮；四总线：表、推子、LUFS、静音、效果链（EQ ≤ 3 段 / 压缩 / 限幅参数，`Settings/EffectChainView.swift`）；头部 AFV 开关 + PFL / AFL；底部 Master 读数 + A1（Stats 1 Hz）。面板宽 200 → 340 |
| 5 叠加面板 / 多画面 / 外部显示 | `UI/OverlayPanel.swift`（重写）、`UI/AuxWindows.swift`、`UI/PanelCoordinator.swift` | 叠加：通道 → 输入、开关、位置预设（整幅 / 四角 / 下三分之一 / 自定义 x y w h）、动画（切入 / 淡入 / 滑入 / 缩放 + 拍数）；多画面独立窗口（窗口菜单 / 底栏按钮）；外部显示菜单（窗口菜单 + 底栏"外部输出"：每块屏 × PGM / PVW / 多画面 / 每路输入）→ 加一路 externalDisplay 输出，窗口跟着快照开关（全屏 borderless；测试宿主用普通窗口），关窗口 = removeOutput |
| 6 快捷键编辑器 / MIDI 映射 | `Settings/HotkeyEditorPanel.swift`、`Settings/MIDIMappingPanel.swift` | 快捷键：行编辑（组合键文本 / 录键 / 动作种类 + 参数 / 备注）、冲突检查、恢复默认表、保存到 `hotkeys.json` 并立刻换给 HotkeyDispatcher；MIDI：来源列表（1 Hz 刷新）、触发（CC / 14-bit CC / Note + 通道 + 号）、learn（MIDIController.startLearn，期间不派发）、动作（T-bar / 输入增益 / 总线增益 / 动作）、冲突 / 范围检查、保存到 `midi.json` 并换表。测试宿主两张表都指到临时目录 |
| 7 偏好设置 | `Settings/PreferencesPanel.swift`、`AppSettings.swift` | 节目分辨率 / 帧率（在 Show 里，改了换 session）、API 开关 / 地址 / 端口 / token、音频输出设备列表、第三方 API 兼容层（VMixCompat）开关 + 端口 + 法律提示（新键 `compatLayerEnabled` / `compatLayerPort`）、语言（写 AppleLanguages）、更新（W4-B 接 Sparkle，占位）。API / 音频 / 兼容层用 W2-B2 的同一组 UserDefaults 键 |
| 8 本地化骨架 | `L10n.swift`、`App/Resources/{zh-Hans,en}.lproj/Localizable.strings` | 525 条键，用户可见文案全部 `L("键")`（菜单、底栏、状态行、提示、格子、所有面板）；测试宿主固定 zh-Hans 让中文断言跨机器成立；LocalizationTests 扫源码：键都在表里、两种语言键集合相同且占位符一致、App/Sources 里没有写死的中文（日志 / 断言除外） |

其他：`AppController` 加 `panels` / 两张表的文件位置 / `applyHotkeyTable` / `applyMIDITable` / `changeProgramFormat` / `restartSession` / `updateSettings`；`SwitcherSession` / `ControlRuntime` 接收 MIDI 表参数（不再在 session 里读用户文件）；底栏录制按钮只管 PGM 那一路录制输出（ISO 各路由 W3-C 同拍起步），推流按钮起停全部目的地；`OutputRuntime.stopRecording` 没按 prompt 末条简化（见 §3）。

## 2. 测试（`xcodebuild test`，SwitcherTests 44 个：42 过 2 跳，约 2 min）

| 测试 ID / 名字 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| UI 表驱动 `testPanels_openChangeOneItemSnapshotFieldChanges` | 26 个用例（添加输入 sheet、输入设置 ×6、录制 / ISO / 推流 ×2 / 外部显示 / NDI / 虚拟摄像头、调音台 ×6、叠加、快捷键、MIDI、偏好 ×2、多画面）全部字段变了，3.0 s | 每个面板打开、改一项、3 s 内快照对应字段变了 | ✅ |
| `testPanels_preferencesProgramFormatReplacesSession` | 720p60 新 session 0.63 s 内起来、输入带过去并 live；格式没变不换 | 20 s 内 | ✅ |
| `testPanels_preferencesLegalNoticeDevicesAndLanguage` | 法律提示含"律师"；设备选项 ≥ 2；AppleLanguages 写 ["en"] / 跟随系统删掉（看 App 自己的持久域，全局域里有系统语言） | — | ✅ |
| `testPanels_externalDisplayMenuAndWindowLifecycle` | 1 屏 × 4 项（PGM / PVW / 多画面 / 输入 1）；开窗 = 加 externalDisplay 输出（输入 1 = 多画面纹理里那一格）、关窗 = 删输出 | — | ✅ |
| Show 往返 `testShow_allSettingsRoundTripExact` | 全字段夹具（8 种来源、裁切 / 变换 / 音频 / 效果链 / 抠像、Wipe + Stinger 参数、FTB、4 个叠加、4 总线 + 效果链 + AFV + PFL、7 个输出、3 个布局键）save → load 相等，再编码逐字节相同 | 完全一致 | ✅ |
| `testShow_documentsRoundTripKeepsEverythingButOutputTargets` | 只清 record / stream 的 enabled，其余相等 | — | ✅ |
| `testShow_appOpenThenSaveRoundTrip` | App 打开全字段节目（720p60，8 路，5 路占位）0.73 s；makeShow 的 inputs / mixer / audio / outputs / layout 与文件逐节相等；另存再开仍相等 | — | ✅ |
| 无障碍 `testAccessibility_allPanelControlsHaveLabels`（运行期，AppKit 层） | 主窗口 48 个 AppKit 控件（按钮 / 搜索框 / 分段控件 / 竖推子）+ 各面板宿主视图里的竖推子，缺 label 0 | 0 | ✅ |
| 无障碍 `testAccessibility_swiftUIControlsDeclareLabels`（源码扫描，SwiftUI 层） | App/Sources 12 个 SwiftUI 文件，每个 Slider / Stepper / TextField / SecureField / Picker / Toggle / ColorPicker / Button / makeNSView 都带文案或 accessibilityLabel，违规 0 | 0 | ✅（局限见 §5 第 10 条） |
| 本地化 `testL10n_bothLanguagesHaveSameKeysAndNoEmptyValues` / `everyKeyUsedInSourcesExists` / `noHardcodedChineseInUISources` / `lookupUsesOverrideAndFallsBackToKey` | 527 条键两种语言集合相同、占位符一致、无空值；源码 474 处静态键都在表里；App/Sources 无写死中文（日志 / 断言除外）；覆盖语言 / 缺键回退 | 全 0 违规 | ✅ |
| 调音台 `testMixer_stripsMetersAndCommands` | 1 号（1 kHz −20 dBFS）条子表 > −40 dBFS、2 号无音频无读数、Master 表有读数；推子 / 静音 / 独听 / 声像 / 送出 / 延迟（9999 → reducer 钳 500）/ 每路效果链 / 总线推子静音 / AFV / PFL（音频引擎跟着换，输入不重建）/ Master 限幅 / FTB → −∞；A1 0 / 0 / 0 | — | ✅ |
| `testMixer_effectParamsSchema` | 三种效果的 id 与键名、编辑器往返（空链 = 空） | — | ✅ |
| `testHotkeyEditor_addBindingConflictSaveApplyAndRecord` | k → Cut 存盘 + 派发器换表 + 按 k 真 Cut；k / K 冲突不存；"cmd+" 不存；录键 shift+cmd+j；换动作 toggleOverlay(2)；恢复默认 23 条 | — | ✅ |
| `testMIDIMapping_learnFromVirtualSourceAndSave` | 虚拟源起 session 时连上；learn → CC 9 @ ch3（期间不派发）；存盘 + 换表；CC 9 = 64 推 T-bar 到 0.504；冲突 / 通道 17 不存；取消 learn | — | ✅（虚拟源要先于 session 建，§5 第 11 条） |
| 旧测试 26 个（W2-B / W2-B2） | 改了 3 处入口（Master 推子 / 表走调音台模型、底栏外部输出 / 多画面按钮可用、AddInput 八种）；`testInputs_builtInCameraLiveWithin5sAndPictureShows` 仍 BLOCKED-权限；`testStream_10sToLocalMediaMTX_framesContinuous` 在全量跑时因没编 frameprobe 跳过，单独编好后再跑见文末 | 仍绿 | ✅ |

运行记录：全量 `xcodebuild test` 44 个测试 42 过 2 跳（摄像头 BLOCKED-权限；推流因全量跑时没编 frameprobe 跳过），`swift build -c release --package-path Tools/frameprobe` 之后单独再跑
`testStream_10sToLocalMediaMTX_framesContinuous` 17 s 过、`testRecord_5sTwoTracksDurationExact` 7 s 过（底栏推流按钮改成"起停全部目的地"后行为不变）。
`make lint BRANCH=w3-app2`：禁词 / 版本 / Package.swift / 依赖方向 / 归属（48 个改动文件都在 App/、reports、docs/contract-changes 内）/ 实时符号全绿。

### 人工检查（用户做；自动测试驱动的是模型，没有人点过控件）

前提：`make gen build-app`，打开 `.build/DerivedData/Build/Products/Debug/Switcher.app`。

- [ ] 底栏"添加输入…"：左栏八种类型切换、合成源页的滑杆 / 噪声 / 图案 ID、屏幕页选"单个窗口"后列表能出来（要屏幕录制授权）、音频设备页列出声卡；编号 / 名字 / 添加。
- [ ] 缩略图右键"设置…"：六节都能改并立刻生效（裁切 / 变换看 PGM；延迟补偿 / 声像听耳机；抠像开关等 W3-B）；改名回车生效。
- [ ] 输出 › 录制设置：改编码器 / 目录 / 模板，示例文件名跟着变；ISO 页勾一路 → 输出表多一路（W3-C 合入前只是配置）；推流页加一个 rtmp://127.0.0.1:1935/s1 → 底栏"推流"可用。
- [ ] 窗口 › 外部显示 › 某块屏 › PGM：全屏黑底出画面（只有内置屏时会盖住主窗口，⌘Q 或菜单"关闭全部外部显示"）。
- [ ] 窗口 › 多画面窗口：16:9 窗口出多画面。
- [ ] 调音台：条子的表在动、推子 / 静音 / 独听 / 声像 / M A B H 都能改，AFV 开关 + PFL / AFL，总线"效果"弹出 EQ / 压缩 / 限幅（音频引擎暂不读效果）。
- [ ] 切换 › 快捷键…：录键、改动作、冲突提示、保存后立刻生效；MIDI 映射…：插着 MIDI 设备启动 App 后 Learn 能学到（换过节目后新插的设备连不上，见 issue）。
- [ ] 偏好设置：改 API 端口 → 应用并重起引擎 → `curl` 新端口；改格式 720p60 → 引擎重起、标题条 / 状态行的节目格式变；语言切 English 重开 App 全英文。



- **`OutputRuntime.stopRecording` 按 W2-B2 报告 §4 第 6 条简化**：prompt 末条写"若 G4 没做"；main 上的 `Recorder` 已含 W1-E2（G3 合入），可以简化，但它是接线逻辑不是面板，且 W3-C 同时在 App/ 里做 ISO 录制（会动同一段），留给 G4 / W3-C 一起改，免得冲突。
- **DeckLink / NDI 特有项**（输入口 / 连接类型、视频格式；带宽模式、tally 回传）：契约里没有字段，W3-A prompt 第 3 条说由它走提案；输入设置窗留了禁用控件 + 说明，批了就接（提案 008 疑问 2）。
- **对齐延迟 / 监听点（提案 007）**：待批，契约里还没有，偏好设置 / 调音台没放；批了加两个控件（AudioState 字段，改法同监听模式）。
- **每路 AFV 开关**：契约只有全局 AFV（设计方案 §7 也是全局），条子上做的是显示该路当前门控增益 + 头部全局开关；每路参与开关要加字段（提案 008 疑问 1）。
- **兼容层真的起来**：W3-D 的 VMixCompat target 还没合进 App，偏好设置只保存两个键；ControlRuntime 按键起模块是 G4 / W3-D 合入后的一行。
- **虚拟摄像头安装的真实验证**：没有 W3-C 的扩展包也没有 Team ID，只能验证请求发得出、错误文案显示（BLOCKED-签名）；测试宿主不发请求。
- **外部显示的 W3-C 替换**：W3-C 会做 `ExternalDisplayOutput`（Packages 里 + 显示器插拔），本会话的窗口是 App 级的最小实现（MetalDisplayView + 跟快照），G4 合并时以 W3-C 的为准、保留这里的菜单 / 设置面板。
- **屏幕录制 / 摄像头权限相关的自动测试**：与 W2-B2 一样 BLOCKED-权限；添加输入的窗口 / 应用列表在 Claude 的 Bash 下取不到（选到"窗口"页时显示失败文案）。

## 4. 对契约的疑问

写进 `docs/contract-changes/008-ui-commands-monitor-bus-effects-output-toggle-input-source.md`（待批）：

1. `Command` 缺 `setMonitorMode` / `setBusEffects`：调音台的 PFL / AFL 与总线效果链现在经 `loadShow(当前状态改一项)` 整体替换（`MixerModel.replaceWholeState`），转场中会被 `resetTransientState` 打断。
2. 非录制 / 推流输出（NDI / 外部显示 / 虚拟摄像头 / 多画面）没有改 `enabled` / 改名的命令：现在 `removeOutput + addOutput` 同编号翻转（`OutputSettingsModel.replace`），运行表会看到一次消失再出现。
3. 没有 `setInputSource`：输入设置窗的"来源"只读；换来源只能删了重加，而 `removeInput` 会清掉 PGM / PVW / 叠加对它的引用。
4. `EffectSlot` 参数键名口径（`parametricEQ` {centerHz, q, gainDb}、`dynamicsProcessor` {thresholdDb, headroomDb, expansionRatio, attackSeconds, releaseSeconds, overallGainDb}、`peakLimiter` {attackSeconds, decaySeconds, preGainDb}）建议写进 CONTRACTS.md；App 的 `AudioEffectParams` 按 SwitcherAudio.BusEffectChain 的三个 setter 定的。音频引擎目前不读 `effects`（W1-D 的 BusEffectChain 建好但没接状态），接线时按这套键读。
5. `OutputSettings.extra` 里 App 用的键：`display.number`（外部显示的显示器编号）、`ndi.groups`（NDI 分组；`ndi.conversion` 是 W2-D 定的）、`layout`（多画面布局名，只存不解释）。W3-C 若另定键名，App 的 `OutputExtras` 改一处即可。
6. ISO 的表示：一路 `kind = .record, source = .input(n)` 的输出（契约"ISO = 同一拍发多条 startRecord"）。底栏录制按钮只起停 `source == .program` 的那一路，ISO 各路的同拍起步归 W3-C；若 W3-C 想用别的表示，输出设置的 ISO 页改 `setISO` 一处。

## 5. 下一个会话需要知道的坑

1. **XcodeGen 按目录收文件**：新目录 `App/Sources/Settings/`、`App/Resources/*.lproj` 要 `make gen` 才进工程；`.lproj` 被当作 variant group，`Localizable.strings` 两种语言各一份。
2. **测试宿主固定 zh-Hans**（`AppController.init` 设 `L10n.languageOverride`）：写断言用中文原文没问题；正式 App 跟系统语言，偏好设置里改语言写 `AppleLanguages`，重开生效。
3. **`L("键")` 缺键返回键本身**，LocalizationTests 会抓；加文案先在 `Localizable.strings` 两个文件里各加一行（生成脚本在本会话的 scratchpad，没入库；直接手写两行也行，键排序）。
4. **SwiftUI 面板的测试驱动的是模型**（`*Model` 的方法），不是点控件；无障碍检查分两层（第 10 条），AppKit 的 NSSlider / NSTextField / NSSegmentedControl 要自己 `setAccessibilityLabel`，而且要同时设在 cell 上（cell 型控件的辅助功能元素是 cell，控件上的 label 不会自动传到 cell）。
5. **`Bus` 加了 `@retroactive Identifiable`**（调音台 sheet 用），若契约以后自己加 Identifiable 会撞，删 App 里那一行即可。
6. **NSHostingView 的 `sizingOptions = []`**：面板窗口自己定尺寸，不然 SwiftUI 会把窗口撑成内容的最小尺寸。
7. **`Package.resolved` 仍会被 xcodebuild 改**（W2-B2 坑 6），提交前 `git checkout -- Packages/SwitcherControl/Package.resolved`。
8. **外部显示窗口在测试宿主是普通窗口**（`fullScreen: !isTestHost`），真 App 是 borderless + 高 level；关掉 = `removeOutput`（`ExternalDisplayWindowController.onUserClose`），跟快照关的走 `closeFromState` 不回发。
9. **面板窗口换 session 全关**（`PanelCoordinator.bind`），多画面窗口保留只换显示来源；偏好设置的"应用格式"就是换 session，所以它自己的窗口也会关。
10. **无障碍检查为什么分两层**：NSHostingView 不把 SwiftUI 自己的辅助功能元素暴露给进程内的遍历——新式 `accessibilityChildren()` 和老式 `AXChildren` 属性都只给底下的 AppKit 视图
    （SwiftUI 的 Button / Text 根本不出现；Picker / TextField / Slider 只看得到无 label 的 `SwiftUIPopupButtonCell` / `_SystemTextFieldCell` / `CustomMarkedSliderCell`，label 在 SwiftUI 那一层）；
    探针：`AXUIElementCreateApplication(getpid())` 对本进程返回 −25208（kAXErrorNotImplemented，进程未被信任），所以真 VoiceOver 走的那条路在测试里走不通。
    于是运行期只查 AppKit 层（主窗口的按钮 / 搜索框 / 分段控件、宿主视图里我们自己放的 NSSlider），SwiftUI 层靠源码扫描（每个控件构造带文案）。要真验证得开 VoiceOver 人工过一遍。
11. **MIDI 热插拔在换过节目之后失效**（W2-C 的坑，`reports/issues/W3E-w2-control-midi-hotplug-after-restart.md`）：CoreMIDI 通知只送到进程里第一次建客户端时的 run loop，第一个 session 的 MIDI 线程停了之后再插的设备连不上；测试里先建虚拟源再起 session 绕过。
12. **`accessibilityIsIgnored` 不是所有对象都实现**（NSSplitViewSplitter 直接抛 unrecognized selector），遍历前要 `responds(to:)`。
