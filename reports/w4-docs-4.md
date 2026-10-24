# W4-C4 手册续做三：止血七路（115–121）+ G10 胶水改了的行为写进手册与集成文档（prompt 124，分支 w4-docs-4）

分支 `w4-docs-4`（worktree `.claude/worktrees/w4-docs-4`），从 main `2ec2c05`（G10 快进后的 1f9be64 + 用户 10-24 归档的审计报告）开。
机器：MacBook Pro M5 Max，macOS 27.0（Darwin 27.0.0），Python 3；同机有别的会话的 worktree，本会话不编译、不跑 App。
不 push、不 merge；交给 G11（prompt 127）。

提交（`git log --reverse main..w4-docs-4`）：
`923d71f` 快捷键 → `3536023` 兼容层 → `82bb7c5` 输入 → `2fe07c1` 输出 → `f17a84b` 概念 → `c4b3527` API → `9b2ab47` 测试文档 →
`8c4a168` 核对后的修正（对 main）→ **`e72ccaa` 跟 126** → **`db83c58` 跟 123** → `32b9e99` make manual → `f6a8a7b` 问题单 → 本报告。
加粗的两个只含 Markdown、整提交依赖未合入的分支（§3 第 1 条）。29 个文件（不含本报告），+436 / −212。

## 1. 做了什么

按合入后（main 2ec2c05）的**代码**写，中英两份同一节一起改；各会话报告、G9 §7.4、G10 §4.3、119 的同步单 W5P-w4-docs-manual-followups（16 处）都只当线索，
每句对着代码 / Localizable.strings 核过；界面原文一律照两份 strings 逐字引。

| 交付 | 改了什么（页） | 依据的代码 |
|---|---|---|
| 1 快捷键 | 默认表 ⇧1–⇧0 的"已知问题 / 逐行重录"绕法删掉，改成"按键位认，美式 / 拼音一样"；老录键 `shift+!` 读进来归一成 `shift+1`、撞默认行留录下的那行停用另一行、两行老写法照旧冲突；hotkeys.json 写法一律"不加 ⇧ 的那个键"；**拼音下 `, . ; [ ] \` 和 `` ` `` 按不出来**（S3）照实写；统计窗 / 状态窗 / 多画面窗口在前也派发（119）；MIDI：Note 执行没选输入的 Stinger 有状态行提示（116）、CC 推杆推这种槽仍是硬切（快捷键 / shortcuts、故障排查 §7） | KeyCombo（ansiUnshiftedKeys、canonicalKey）、HotkeyTable.preferRecordedShiftRows、MIDIController.setFeedbackHandler、ControlRuntime、PanelCoordinator.forwardHotkeys；**探针**（铁律 10）：草稿区 30 行 `keyprobe`，CGEvent + `NSEvent(cgEvent:)` 不投递，本机输入源 `com.apple.inputmethod.SCIM.ITABC`：`, . ; [ ] \ `` ` `` 在无修饰 / ⌃ / ⌥ / ⌘ 下都给 `， 。 ； 【 】 、 ·`，`' / - =` 与字母数字正常 |
| 2 兼容层 | docs/integrations/vmix-compat.md、docs/api/vmix-compat.md：`Input=` 必须落到存在的输入，`0` / `-1` 落在黑场或已删、编号不存在一律 404 InputNotFound（列出所有带 Input 的函数、两种正文）；`Cut Input=0`（PVW 黑场）不再切黑场，不带 Input 的 Cut 仍切；**Fade / Wipe / Zoom 带 Input 在转场中不回 409、回 `OK … (no change)`**；毫秒参数 0–3 600 000，越界 / 非数 / 无穷 400 BadParameter（正文原样）、Cut 不读 Duration；XML 槽时长封顶 Int.max；31 个名字 501 那段不变 | InputReference.resolve、FunctionTranslator.durationTicks / durationMillisecondsRange、StatusXML、MixerReducer |
| 3 输入 | 速率 0.1–8：两处数字框钳位（10 → 8、0.05 → 0.1、0 / 负数 → 1、不是数不提交），API 400、越界老节目打不开；竖拍 / 方向矩阵 90 / 180 / 270 + 翻转自动转正、输入设置的旋转叠在之后，**任意角度原样出、界面上看不到提示**（lastError 只在无信号时显示，见问题单）；"添加输入"摘要对竖拍写编码尺寸（main）；片尾开循环接着进下一圈；定位 0–604 800 s、过尾 = 从头；设置窗 ▶ / ⏸ 认"播完"、"约 3 拍"；换来源停在旧帧等新来源第一帧、起不来 / 纯音频画黑、能起来没画面的旧帧一直定着；每路效果页没有限幅节、限幅格进"其他效果（原样保留）"；SDK 没编进来两种横幅的新小字；格子"转场"遇没选输入的 Stinger（输入 / inputs、故障排查 §7） | FileInput / FileDecoder / FileOrientation、AddInputModel.clampedFileRate、InputStripView、InputRuntime.replaceSource、InputSettingsPanel、EffectChainView、AddInputSheet、Contracts031 |
| 4 输出 | 录制撞名加 `-2 / -3`、永不覆盖（K01，几种撞名情形）；ISO 录着换来源接着录（D06）+ 两个边角（main 实情）；推流：鉴权停下写"失败"、红字分两句、编码详情"鉴权失败除外"、底栏悬停多一句、起不来 / 失败的不锁也能删、状态行码率不算失败的路；**最后错误**按 G10 胶水 ③ 的写法（连接失败 / 断线三种 / 起不来整句 / 建传输层失败，底层原样文字照实）；状态窗里起不来的也写"失败"；"显示日志…"导出最近 10 分钟系统日志；查询串参数名记在本机（最近 8 对）、Adobe"（没有密码）"；NDI：NV12 转 UYVY、**BGRA / UYVY 输入直送（图片、带 alpha 的视频、屏幕、NDI、DeckLink），BGRA 按 BGRX 不透明送**、比节目大的 NV12 裁左上、连续 10 帧送不出也 failed（原因在 last_error 与系统日志，App 的 NDI 页仍写"初始化失败"）、Aux 跟着换来源（输出 / outputs、故障排查 §3 / §4 / §5 / §9） | RecordingPaths.unique、InputRuntime / OutputRuntime（routeFailure、EncoderStatsSource）、OutputButtonSummary、OutputSettingsPanel、OutputStatusPanel、StatusLineFormatter、StreamOutput / StreamTransport / HaishinKitTransport、StreamAddress、DiagnosticBundle、NDISender、OutputStatusText |
| 5 概念 | §转场槽"例外"那句删掉（T-bar 拉回 0 也重拷，020 / 115）；AFV：T-bar 提交 / 转场中途 Cut 时声音在对调那一拍约 5 ms 短淡收口（120）；FTB 途中改时长声音跟画面（与 AFV 无关）；没选输入的 Stinger：格子"转场"（含右键）先弹选择、一条都不发，T-bar 灰掉 + 橙字，MIDI 提示，API / MIDI 推杆仍是"一推动就硬切、推到顶对调"；T-bar 行英文写短 "T1 · …"、没选输入只写 "Stinger"；打开 / 新建 / 恢复排队（D04）；LastSession 相对素材路径（D16）；状态行推流码率、推流按钮"失败"；每路没有限幅器、限幅页按总线分开的那句（概念 / concepts） | MixerReducer、AudioEngine（shortFade、ftbPending）、StateMachine、TransitionPanelView（updateTbarGuard、showStingerInputs）、InputCellView.transitionPressed、TransitionSlotText、AppController.enqueueSessionChange、ShowDocuments.autosave、CompositorPasses.stingerShowsNewUnder |
| 6 API | docs/api/README.md §5 加 `audio.effects{buses[…], inputs{…}}`（有音频引擎时四条含耳机、没有时空表、inputs 只列装了效果的、measured 只在装着 compressor 时）、NDI failed 的新含义；§6 加取消也重拷、AFV / FTB 的声音、定位 / 速率口径（400 原文、钳不拒、缺 rate 读 1、老节目不打开）、推流 last_error 其余几种、NDI 分路与 BGRX；examples.md 没有速率 / 定位例子，不用改 | Stats.swift、AudioEngine.statsEffects、CommandValidator、Input.swift / MixerState.validate、NDISender |
| 7 测试 | 公开版测试标准 §2.3 加"拍号按 PTS、漏帧单独报"（两组式子、`missingFrames` / `missingFrameCount` / `missingBetween`、fps 来源、av / wipe / zoom / stats 要给 `--fps`）与多文件 A4（锚、半秒、缺 click / 缺闪光算不过、看 passA4）；README 中英加读结果的三条、检查点表补 G9 / G10、用例数换 G10 的 | FrameprobeCLI usage、FrameAnalysis（programTick / programFps / missingTicks / avMulti）、TransitionCurve、gate3-report.py、gate4.sh |
| 8 收尾 | `make manual`；`make lint`；三个核对 agent 逐句对代码一轮（§2.2），结论我再对代码后改，查出的实现缺口写成三张问题单（§3 第 4 条） | — |

**依赖未合入分支的两个提交**（W4-C3 §5 第 3 条的做法；按分支头读代码：126 = `w5-app-closeout` 56394c3、123 = `p5-contracts-5` 74436b7）：

| 提交 | 依赖 | 只改了这些句子（中英各一份） |
|---|---|---|
| `e72ccaa` | 126 W5-Q | 输入"添加输入"文件信息的竖拍摘要（"1080×1920（编码 1920×1080）"）；故障排查 §7 越界速率老节目那一行（三条路都弹"输入 n（名字）的播放速率 x 超出 0.1–8……"）；概念"下次启动"读不出先提示；输出 ISO 一节"删掉这一路"（停在删除那一拍、提示随即被"录制 n 已停"盖掉、开关自动关成"未开"）与"ISO 音轨跟着编号走"；状态窗"效果链延迟"一行；音频设置窗常规页"效果链延迟" |
| `db83c58` | 123 P5-5 | API §6"输入编号 1–16"一条；概念词表"编号 1–16"；故障排查 §7 末尾"打开节目弹 `inputNumber(input: 17)`"一行（含改编号时连输出来源一起改） |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

文档会话没有测试 ID；交付 8 的判据与本会话自己加的核对如下（都本机实跑）。

### 2.1 lint 与生成物

| 项 | 结果 | 判据 | 通过 |
|---|---|---|---|
| `make lint BRANCH=w4-docs-4`（`f6a8a7b`，C locale） | 禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包通过；**check-ownership：29 个改动文件都在允许范围内**；check-help：`App/Resources/Help 与 docs/user 一致（18 个文件，847.2 KB）`；check-links：206 个 Markdown 的相对链接与锚点都能解析；check-rt-symbols 通过 | 全绿 | ✅ |
| 同上，`LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8` | 退出码 0 | 全绿 | ✅ |
| 依赖提交能否整提交 revert（草稿区临时 worktree，跑完删掉） | 只 revert `e72ccaa`、只 revert `db83c58`、两个都 revert（126 先）三种都 **0 冲突**；revert 后 `build-help.py` 一次、`--check` 一致，竖拍摘要 / 输入编号那两句按预期消失 | 0 冲突 | ✅ |
| 随包 HTML 结构抽查 | MIDI 一节两条列表项与后一段分开（第一版把后一句并进了 `<li>`，核对时发现、已修） | 目视 HTML | ✅ |

### 2.2 核对一轮（交付 8"开核对 agent 逐句对代码"）

三个只读 agent 并行：A 手册快捷键 / 输入 / 概念（约 115 句）、B 手册输出 / 故障排查（约 130 句）、C API / 兼容层 / 测试文档（约 90 句）。
三个 agent 一共报 29 处问题（A 7、B 9 + 范围外 2、C 11），我逐条对过代码，**28 处成立、已改**（都在 `8c4a168` 与两个依赖提交里）；1 处不改：
A 说"拼音下加 ⌃ / ⌥ / ⌘ 也一样"没有实测——本会话开工前那个探针正是量的这几种组合，保留原句。
成立的里面错得最重的几处（都是"按报告写、没对代码"那一类，W4-C3 §5 第 2 条的坑又踩了）：

- 没选输入的 Stinger 用 API / MIDI 推：我写成"推到顶就硬切"，渲染器其实是推过换底拍的位置（出厂 0 = 一推动）就整幅画新画面；
- 兼容层 Fade / Wipe / Zoom 带 Input 写了"规矩同 Cut"，其实转场中只有 Cut 回 409，Fade 那几个回 `OK … (no change)`；
- ISO 那一路被删（126）写成"状态变成失败"，其实快照 enabled 回 false、failed 表被清，界面写"未开"；
- 推流 last_error 写成"不带程序写法、可以直接给人看"，底层库的原样文字还在（问题单）；
- 换来源"起不来画黑"只覆盖了 start 当场抛错的，摄像头没插这类能起来没画面的，旧帧一直定着。

## 3. 没做的和原因

1. **依赖未合入分支的两个提交**：`e72ccaa`（126）、`db83c58`（123）。G11 按 prompt 127 把 123–126 都合了的话什么都不用做；哪一个不合，就 `git revert` 对应那一个、再 `make manual` 提交产物（Help 只在 `32b9e99` 里提交，revert 只碰 Markdown，§2.1 实测 0 冲突）。
   125（W1-D4，`w1-audio-4`）改的是 Cut / Auto 起点的替换淡变与 Auto 途中才开 AFV 跟剩下的曲线——手册本来就写"转场时交叉淡变（和画面同一拍开始、同样长）"，修完更贴这句，**没有句子要改、没有依赖它的提交**。
2. **截图**：prompt 写明 L3 时拍，没拍。
3. **规格 / 计划 / CHANGELOG / KNOWN_ISSUES**：不在本会话目录（KNOWN_ISSUES 是检查点的）。内部版 docs/spec/导播台测试标准.md §2.3 没有 121 的拍号那一条、多文件 A4 还写着"缺 click 判不过归 W1-A6"、没有缺闪光——公开版比内部版多了，写进问题单 W4C4-w1-testkit-…（第 2 节）给维护规格的会话。
4. **实现缺口**（手册已照实写；修了告诉文档会话改句子）——三张问题单：
   - `reports/issues/W4C4-w5-app-gaps-found-by-docs.md`（App，8 条，S3）：播放中输入的 lastError（方向矩阵 / 钳位提示）界面看不到；NDI 发送页所有 failed 都写"初始化失败"、不显示 last_error；推流 ▴ 悬停对鉴权停下的仍写"起不来"；"起不来"写两遍；状态窗把起不来的写成"失败"；中文 Stinger 选输入菜单"（选了才执行）"读着像选了就执行；（126 分支）ISO 被删的提示一闪被盖掉；TransitionPanelView 注释与渲染器不符、123 合入后 `inputNumber(input: 17)` 枚举原样弹出。
   - `reports/issues/W4C4-w2-stream-last-error-raw-texts.md`（推流包，S3）：`publish: requestTimedOut`、`connect 无状态`、`"\(error)"` 原样、publish 非成功码不带前缀与描述。
   - `reports/issues/W4C4-w1-testkit-frameprobe-usage-a4-missing-flash.md`（frameprobe 用法 + 内部版测试标准，S3）。
5. **prompt 交付 3 写的"任意角度原样出 + 格子第二行提示"**：main 上第二行只在无信号时显示，播放中的文件输入看不到这句；手册写"这一版界面上没有提示"，没照 prompt 字面写（问题单第 1 条）。
6. **docs/checklists/G10.md** 没动：人工清单归检查点；它的预期是 G10 照合入后的代码写的，本会话没发现与手册冲突的条目（没逐条核）。

## 4. 对契约的疑问

没改契约，也没写提案。两处看到的口径给 G11 / 用户知悉：

1. **NDI `failed` 的两种含义在 App 上分不出来**（118 + 123 的契约文字已写"连续送不出也算 failed"）：`last_error` 里有原因，但 App 的 NDI 页只写"初始化 / 建实例失败"——是 App 的事（问题单第 2 条），契约不用动。
2. **起不来的推流在 Stats 的 `last_error` 是整句界面提示**（"推流 3 起不来：…"，App 的 EncoderStatsSource 填的），headless 那边是 StreamOutput 自己的原因；三方读同一个 last_error，App 若按问题单第 4 条把 failed 表改成只存原因，Stats 里的这句也会跟着变（API 客户端若有人按它做字符串匹配会受影响——手册已写别这么做）。

## 5. 下一个会话需要知道的坑

1. **写手册要对代码**：本轮第一遍仍有 28 处被核对查出（§2.2），大半是把报告 / prompt 的说法当成了行为（"推到顶才硬切""状态变成失败""规矩同 Cut""格子第二行提示"）。核对 agent 的结论也要自己再对一遍代码（本轮有一条是 agent 不知道已有探针）。
2. **依赖提交只放 Markdown，产物最后统一 `make manual`**：随包 HTML 一整张表在一行里，两个依赖提交只要都改了同一张表（本轮故障排查 §7），各自带产物时 revert 必冲突；Markdown 里两组依赖句子之间也至少隔一行未改的行。
   **核对修正要放在依赖提交之前**：本轮第一版是"依赖提交 → 核对修正"交错，修正碰了依赖句子的相邻行，单独 revert 就冲突；最后用草稿区 worktree 算出三个状态、重排成"主题 → 核对修正 → 跟 126 → 跟 123 → make manual"，树与重排前逐字相同（重排前的头 `19a20ed` 只在 reflog 里，临时备份分支已删）。
3. **快捷键按得出按不出用探针验**（W4-C3 §5 第 4 条那个法子）：`CGEvent(keyboardEventSource: .privateState, virtualKey:, keyDown:)` 设 flags，`NSEvent(cgEvent:)` 看 `charactersIgnoringModifiers`，不投递事件；结果随当前输入源，报告里写清输入源 ID。
4. **输入的 lastError 只在无信号时上界面**：FileInput 的钳位 / 方向提示、各输入的"原因"在播放中都看不到；写"格子第二行写…"之前先看 InputStripView 传没传 detail。
5. **推流"起不来"的原因是整句**：OutputRuntime.failed 存的是 `notice.streamFailed` 整句，推流页 / 底栏悬停 / Stats last_error 各套一层，引原文时照实际拼出来的写（"起不来：推流 3 起不来：…"）。
6. **NDI 直送看像素格式不看输入类型**：带 alpha 的视频文件（FileDecoder 出 BGRA）、带 alpha 的 NDI 源、DeckLink（UYVY / BGRA）都直送；BGRA 一律 BGRX。
7. 本会话 cwd 会被工具重置回主仓库：每条命令先 `cd` 到 worktree；zsh 下 `grep --include=*.swift` 要加引号。
