# W3-E3 App 收尾报告（prompt 68，分支 w3-app-4）

分支：桌面端开的 worktree 分支 `claude/w3-app-4-ndi-aux-meters-e69f00`；prompt 里叫 `w3-app-4`，本地另打同名引用（`git branch -f w3-app-4 HEAD`）给
`check-ownership.sh` 用（同 W3-E / W3-E2 的做法）。基于 main `67d0f6b`（G4 第二批续做合入 + 提案 017 落地之后；P4 没合入，不依赖）。
机器：MacBook Pro M5 Max，**macOS 27.0**（上一轮报告是 26.6.2，中间系统升过级），Xcode 27.0，接电源；内置屏 + LG ULTRAGEAR 外接屏（2560×1440）。
同一台机器上 P4 会话（p4-contracts-cleanup）在跑整套 `make test`，App 测试都挑它不在跑 App 测试的时候跑（§5 第 2 条）。

## 1. 做了什么

11 个提交（`git log main..w3-app-4`，最后一个是本报告）：前 5 个按交付各一个（缩略图 / 显示记账 / 电平表 / Aux 与层级与过渡键 / NDI），后面是自查补的两处
（NDI 页分组也改成草稿、状态行先看录制 / 推流）、一段用例和两张问题单。App/ 下 29 个文件 +1501 / −102 行，另 `project.yml` 2 行（越界，§4 第 1 条）。

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 NDI 发送接线 | `Engine/OutputRuntime.swift`、`Engine/SwitcherSession.swift`、`Engine/OutputStatusText.swift`、`Settings/OutputSettingsPanel.swift`、`UI/BottomBarView.swift`、`project.yml` | kind = ndi 且 enabled 的输出 = 一个 `NDISender`：源名 = 输出名，分组 = `extra["ndi.groups"]`，转换方式 = `extra["ndi.conversion"]`。**PGM / PVW / 多画面**：sender 自己当 PGM 帧的消费者、从 `RenderedFrame` 挑（PVW / 多画面帧渲染器按状态自动填）；**输入 n**（Aux）：该路帧槽开一个分支（与 ISO / Aux 窗口共用每路 4 个），ISO 同款 `ISOFrameTap` 每拍挑帧交给 `NDIInputFeed` → `sender.send(frame:tickTime:)`（`NDISender.consume` 对 `.input` 不动，W2-D 报告 §4 第 4 条问的形态）；那一路换了来源就把分支换到新 tee 上（所以输入表变了也调 `outputs.reconcile`，其余部分幂等）。音频：PGM / PVW / 多画面挂 Master，输入 n 挂该路 ISO 音轨（推子后、AFV 前；没音频的路不挂）。名字 / 分组 / 源定死在 sender 里，变了就停旧起新；转换方式 `setConversion` 运行时改。`start()`（NDIlib 初始化、建实例、Metal 转换器编译）/ `stop()`（等发送线程退出、销毁实例）都放后台线程，回主线程挂 / 摘；起停中快照又变了，做完按最新快照再对一次；起不来的记下当时的设置，设置变了才重试。**Stats.encoder** 那一项 = sender 的计数（`EncoderStatsSource` 加 `.ndi`，同一份快照算这一项、也当下一窗口起点）。NDI 页：每路加"发送"开关（setOutputEnabled）、源名 / 分组改成草稿（回车或"应用名字 / 分组"才发 renameOutput / setOutputSettings——原来分组框每个按键发一次，接线之后等于每个按键重建一次发送端）、状态行（只读 Stats.encoder）、选输入时的 Aux 说明；提示文案从"还没接线"改成实情。**状态行**的"编码跳帧 / 码率"原来取 encoder[] 里第一个在跑的项，NDI 排在前面时会显示它约 2 Gb/s 的原始码率：底栏按快照给出与 encoder 同序的输出类型，先找录制 / 推流，都没在跑才显示 NDI（`StatusLineFormatter` 加可选参数，不给 = 原行为） |
| 2 Aux 文案与主屏层级 | `UI/ExternalOutputMenu.swift`、`Settings/OutputSettingsPanel.swift`、`AppSettings.swift`、`Settings/PreferencesPanel.swift`、`AppController.swift`、`Engine/SwitcherSession.swift` | 外部输出菜单：每块屏的子菜单里，输入那一组前面一行 section header "Aux = 原始画面（抠像 / 裁切 / 变换不生效）"，每个输入项的提示也是这句；外部显示设置页 / NDI 页选了输入时来源下面显示同一句。偏好设置加"外部输出"一节："外部输出在主屏上不盖住主界面"→ UserDefaults 键 `externalOutputBehindInterface`（不进 OutputSettings）→ 新 session 建好就设 `ExternalDisplayManager.mainScreenLayering`，点"应用"时落到跑着的 session（包支持运行时改，不用重启） |
| 3 监视器 / 多画面窗口的 dropped 走 DisplayFrameLedger | `UI/MainWindowController.swift`、`UI/MultiviewWindowController.swift` | PGM 监视器与多画面窗口各夹一层 `DisplayFrameLedger`（显示视图对来源是弱引用，窗口控制器持有）。`displayStatsEntries`：dropped / undelivered 都从记账源来（提案 013 / 018 同一口径），不再用 noDrawable；主窗口 / 多画面窗口的遮挡变化 → `breakRun(countingUndelivered: true)`（被遮住 / 最小化 / 别的 Space 那段记 undelivered）；多画面窗口关着 = idle、两样都不记（`breakRun()`；最小化算开着，用显式 `closed` 标志区分，不看 isVisible）；没开过不报。换 session 时旧记账源的数并进 retired，累计值不回退（frames 用的 presentedFrames 本来就跨 session 累计） |
| 4 电平表 | 新 `Engine/AudioMeterFeed.swift`、`Engine/SwitcherSession.swift`、`UI/MixerPanelView.swift`、`UI/MainWindowController.swift` | session 持有 50 ms 的 `AudioMeterFeed`：每拍读一次 `AudioEngineStatus`（音频控制循环 50 ms 刷新的那一份），同一份拼成 `Stats.AudioCounters.Meters`（buses 按 Bus.allCases、inputs 键 = 编号、含 017 的 rmsDb、下限 −120）调 `renderer.setMeters(_:at: 快照时刻)`，再交给调音台条子 / 纯音频缩略图（调音台原来自己的 50 ms 定时器撤掉，三处同一拍同一份）。**撤了检查点在 Stats 1 Hz 消费者里的那条喂法**。同一份快照不重复喂；只在主线程调；session 停时显式 `setMeters(nil)`。`MeterBar`：实心条到 RMS、2 px 细线在峰值（L / R 取大，颜色按它所在的分段），三段色按设计方案 §7（< −18 绿、−18…−6 黄、≥ −6 红）；没有 RMS 的读数退回峰值实心条、不画线 |
| 5 缩略图名字出现两次 | `UI/InputStripView.swift`、`UI/InputCellView.swift` | **二选一选"缩略图切掉内框底部的名字条"**：标题条是输入条的主标签（编号 + 名字 + tally 色），留着；缩略图只要画面。`InputStripView.thumbnailRect(for:width:height:)` 与 `CompositorPasses.drawCellLabel` 同一个 Float 算式（贴内框底边，高 = 格高 × 14%，≥ 12 px，≤ 画面高 × 3.5%），再多切 2 px 给缩略图下采样的采样脚印；切完不是 16:9，显示视图按比例放（上下一点黑边，不拉伸）。1080p 默认布局切 36 + 2 px，19 路（8×4）18 + 2，3×3 38 + 2，720p 24 + 2 |
| 6 删 App 侧过渡键后备 | `Settings/OutputExtras.swift` | `displayNumber(of:)` 只读 `settings.display?.displayID`（包从 W3-C2、契约从 P3 起都不读 `extra["displayID"]`）；设置页改显示器前的 `migratingLegacyKeys()` 照旧（没经过 Show.load 的内存状态靠它搬） |
| 7 UISmoke 61 / 60 | — | 检查点已改（prompt 注明），本会话没动 |

## 2. 每个测试：数值 / 阈值 / 通过否

### 2.1 prompt 点名的测试与本会话新增的用例

| 测试 | 数值 | 判据 | 通过 |
|---|---|---|---|
| NDI 发送本机回环收到 PGM：`NDISendAppTests.testNDI_sendLoopbackReceivesPGM_statsEncoderFromSender` | 输出设置 NDI 页加一路（PGM）→ sender 起来；发现列表里找到 `PLUSDEMACBOOK-PRO.LOCAL (Switcher 回环 …)`，加成 2 号 NDI 输入放 PVW：**读回 PVW 解出输入 1 的图案（ID 0）**，1.2 s 里 12 次采样回环帧号只增不减、走了 > 30；**回环落后 PGM 1–2 帧**（中位 1 帧，信息项）；Stats.encoder 里这一项 publishing、frames 160、skipped = dropped = 0、**码率 1989 Mb/s**（UYVY 原始码率 1920×1080×2×8×60 = 1991 Mb/s）；接收方 1；删输出 → sender 停 | 有 SDK（本机 /Library/NDI SDK for Apple）；没有 SDK 时 setUp 里 XCTSkip BLOCKED-SDK | ✅ |
| NDI 页的名字 / 源 / 开关生效：`testNDI_settingsPageNameSourceEnabledTakeEffect` | 改名 → 换成新名字的 sender、旧的停；源 = PVW → 新 sender 在送（> 30 帧，PVW 帧由渲染器自动填）；源 = 输入 2 → ISOFrameTap 转了 > 30 帧、输入 2 的 tee 多 1 个分支；**输入 2 换来源（setInputSource，InputRuntime 重建那一路）→ 分支跟到新 tee 上、sender 不重建、接着送**；转换方式改 cpu → 同一个 sender 运行时切；关 → sender 停、分支还回去（branchCount 0）、Stats 里 idle；再开 → 新 sender 按 cpu 起；命令日志里是 renameOutput / setOutputSettings / setOutputEnabled，没有删了重加 | — | ✅ |
| 主屏层级开关落到 `mainScreenLayering`：`AuxLayeringAppTests.testExternal_mainScreenLayeringPreferenceReachesManager` | 默认 `.front`；主屏上开一路 PGM 外部显示（level normal）；偏好设置开 → UserDefaults 键 true、跑着的 session `.behindInterface`、窗口 level = `behindInterfaceLevel`（normal − 1）、输出设置一字没变、`AppSettings.load` 读回；换 session 仍是 `.behindInterface`；关 → `.front`、level normal | — | ✅ |
| Aux 文案：`testAux_rawPictureNoteInExternalMenuAndSettingsPages` | 能选的项仍是 PGM / PVW / 多画面 / 输入 1 / 输入 2；说明行（不能点）在输入项前面；输入项提示 = 说明；PGM 等三项没有；设置页模型给的说明同一句；英文 "Aux = raw input picture (keying / crop / transform not applied)"，无中文 | — | ✅ |
| `displayStatsEntries` 的 dropped 与 ledger 同源：`DisplayLedgerAppTests.testDisplayStats_monitorAndMultiviewWindowDroppedFromLedger` | 卡主线程 300 ms：**记账源 dropped 0 → 18，Stats 项同步 +18**（2 → 20，前面 session 的数并在 retired 里），noDrawable 0 → 0（原来的近似一帧都记不到）；下一行 Stats 的 monitor.dropped 落在前后两次读之间；**遮住主窗口 1.2 s：undelivered 0 → 71、dropped 不变**；多画面窗口开着 presenting、数 = 它自己的记账源；关着 idle、1 s 里 undelivered 不涨；再开不补记 | 卡 300 ms ≥ 10、遮 1.2 s ≥ 40、遮住期间 dropped ≤ 2（本会话自定的合理区间） | ✅ |
| `setMeters` 50 ms 喂数的频率与线程：`MeterFeedTests.testMeters_rendererFedEvery50msOnMainThreadFromMixerStatus` | **3 s 喂 57–58 次（19.0–19.3 Hz）、不在主线程 0 次**；喂的 = 这一拍调音台拿到的 AudioEngineStatus 拼的（inputs[1].peak / rms 逐值相同、带 rmsDb、有 master 总线）；读回多画面纹理：1 号格子表条 RMS 段 = (51,199,64) 绿；**停喂 3.6 s 退回占位 (29,29,29)**（证明检查点 1 Hz 那条确实撤了，否则表会一直活着）；再喂 2 s 内活过来；换 session 时 `setMeters(nil)`、旧定时器停 | 15–21 Hz（本会话自定：50 ms、同一份快照不重复喂）；渲染线程零分配由渲染器用例保证（prompt 口径） | ✅ |
| MeterBar RMS + 峰值线：`testMeters_meterBarDrawsRMSBarAndPeakLine` | 几何：RMS −23 / 峰值 −20 → 条 0.617、线 0.667；无 RMS → 条 = 峰值、无线；静音无线。像素（ImageRenderer 画 10×120）：RMS −12 + 峰值 −3 → 30% 绿、75% 黄、87% 底色（RMS 与峰值之间空着）、95% 红线、98% 底色；无 RMS 时 87% 是黄的 | — | ✅ |
| 缩略图不再有两处名字（像素扫描）：`ThumbnailCropTests.testThumbnails_cropCellNameStrip_pixelScanFindsNoLabel` | 离线渲染 7 种布局 / 分辨率（默认 2 / 8 / 19 路、3×3、pgmPvw+2x2、4×4、720p）共 44 路：**缩略图区域里画面部分全是该路纯色、整块没有白字像素**；对照：名字条那几行每路都扫得到白字（> 20 个）；切掉的高度 = 名字条 + 2 px | 0 个名字条像素 | ✅ |
| `testThumbnails_cellsUseCroppedRectAndTitleBarKeepsName` | App 里两路合成源的缩略图 sourceRect = 切掉名字条的内框；标题条仍是"合成 n" | — | ✅ |
| `testOutputExtras_displayNumberReadsFormalFieldOnly` | 正式字段 7 → 7；只有过渡键 9 → nil（与包的 ExternalDisplaySpec 一致）；migratingLegacyKeys 之后 → 9 | — | ✅ |
| 状态行先看录制 / 推流：`StatusLineTests.testStatus_formatterFields`（加了一段） | NDI publishing 排第一、录制第二：给类型 → 显示录制的 2 / 6.00 Mb/s；不给类型或个数对不上 → 原行为（NDI 的 1990.00 Mb/s）；只有 NDI 在发 → 显示它；unavailable 不算在跑 → —；与 stats.jsonl 同一秒逐字比的那条照过 | — | ✅ |

改了断言的旧用例（行为按交付变了，不是放宽）：`ThumbnailRateTests` / `MultiviewSettingsTests` 两条的 sourceRect（切名字条之后的几何，仍校验"按哪个布局切"）、
`ExternalOutputAppTests` 菜单标题（只比能选的项）、`PanelTests` 外部显示页"过渡键作后备"→"读不到"。

### 2.2 全量 `xcodebuild test`（SwitcherTests，81 个用例）

| 次 | 时间 | 环境 | 结果 | 说明 |
|---|---|---|---|---|
| 1 | 10:17–10:20 | P4 同时在跑 SwitcherOutputs 的包测试（编码 / ISO / 推流，硬件编码器与 GPU 都忙）；frameprobe 还没编 | 76 过、4 跳、**1 失败** | 失败 = `DiskProtectionAppTests.testS7_diskFullSwitchesToFallbackDirectory_recordingContinues`："整个过程 missed_render 不增" 0 → 1（40 Mbps 噪声录满小盘、切备用目录那 ~20 s 里渲染线程晚了一拍）。跳过：ISO A4 / 推流 10 s（BLOCKED-工具：本 worktree 还没编 frameprobe）、内置摄像头（BLOCKED-权限，TCC 未授权）、虚拟摄像头出口（BLOCKED-签名） |
| 2 | 10:57–11:01 | 机器空（P4 整轮跑完；它 10:57:36–55 在自己的 worktree 单跑 S7，与本轮开头 6 s 重叠，两边都过了）；frameprobe 已编（钉版本，Package.resolved 没变） | **79 过、2 跳、0 失败**（203 s） | 跳过：内置摄像头 BLOCKED-权限（解锁：系统设置给测试宿主摄像头权限）、虚拟摄像头出口 BLOCKED-签名（解锁：Team ID 签名 + /Applications + 允许扩展）。S7 两条都过 |

`DiskProtectionAppTests`（两条 S7）另外单跑 3 轮（11:02–11:04，P4 同时在跑 SwitcherOutputs 的 MediaMTX / A4 包测试）：**两条 × 3 轮 = 6 / 6 过**。P4 自己 10:44–10:48 的 App 全量（它的分支没有本会话的改动）也红在这一条，
所以它是本机负载下的旧偶发，不是本会话引入的；按铁律 9 没动它的断言。

第 2 次全量里顺手记的数：**A4（App）闪光极差 0.0 ms、click 极差 0.02 ms**（阈值 ≤ 16.67 ms）；**推流 10 s 到本机 MediaMTX 644 帧，丢 0、重复 0、解不出 0**；
NDI 回环落后 PGM 1–2 帧、Stats.encoder 码率 1987 Mb/s；多画面电平表喂数 19.3 Hz、0 次不在主线程；监视器卡 300 ms dropped +17、遮 1.2 s undelivered +71 / dropped +0；
外部窗口 59.8 fps、missed_render 0 → 0；显示解耦 PGM blit 53.0 fps、missed_render 全程 0（这次接着外接屏，挪到外接屏那段也测了）；缩略图 23.75 fps、PGM / PVW 60.0 fps；
UI 冒烟快照峰值 39 / s；本地化 707 条。

### 2.3 lint

`make lint BRANCH=w3-app-4`：禁词 / 版本号 / Package.swift 约束、依赖方向（8 个包）全绿；**归属只有 `project.yml` 一条越界**（§4 第 1 条），其余改动都在 App/（29 个文件）、
reports/issues/（3 张）与本报告；归属那步红了 make 就停，后面的 `scripts/check-rt-symbols.sh` 手动跑了一遍：绿（CSwitcherAudioRT 没动）。

## 3. 没做的和原因

1. **NDI 接收方数量**（`NDISendCounters.connections`）没进界面：它不在 Stats 里（铁律 4：界面只读 Stats），要显示就得契约加字段（§4 第 2 条）。
2. 源是输入 n 的 NDI 发送，**那一路的分支用完了**（与 ISO / Aux 共用每路 4 个）时 sender 照跑、没画面，只在状态行提示一次；那一路之后空出分支也不会自己补上，要关开一次。
   没做自动重试：要么轮询、要么让 InputRuntime 在还分支时发通知，都是新机制，边角情况（同一路 4 个分支全占满）先不做。
3. `project.yml` 的产品依赖是必须的（§4 第 1 条），没法只在 App/ 里做。

## 4. 对契约的疑问

1. **`project.yml` 越界 2 行**：App 目标原来不链接 `SwitcherNDISend` 产品，不加 `- package: SwitcherOutputs / product: SwitcherNDISend` 就 import 不到 `NDISender`
   （Xcode 只编被链接的产品，同一个包的其他 library 不会顺带暴露给 App——W2-B2 报告 §4 第 1 条同一个原因）。没有别的办法，所以直接改了，`make lint BRANCH=w3-app-4` 只剩这一条。
   **请用户裁定**：给 W3-E3 行加 `project.yml`（备注"只加 App 对本仓库包产品的依赖"，同 W2-B2 / W3-C / G4 先例），或由合并它的检查点认领。
2. **`Stats.EncoderEntry` 没有输出编号、也没有 NDI 的接收方数**：App 找某个输出的那一项靠"与 outputs 里带编码器的输出同序"（`OutputRuntime.encoderEntry`，底栏 / NDI 页共用），
   输出表在两次采样之间变了会错一拍；NDI 页想显示"几个接收方"也没有字段。建议将来给 EncoderEntry 加 `output`（与 DisplayEntry 同口径）和 NDI 的 `connections`，要不要做、归谁请用户定（不急）。
3. NDI 起不来（SDK 在但 `NDIlib_initialize` / `send_create` 失败）时 Stats 里这一项是 `unavailable`（sender 自己标的）——契约的 NDI state 只有 publishing / idle / unavailable，没有 failed。
   "SDK 不在"与"SDK 在但起不来"在 Stats 里分不开；界面的提示行里有具体原因。要不要加 `failed` 请契约会话定。

## 5. 下一个会话需要知道的坑

1. **NDI 发送的 start / stop 在后台线程**：`OutputRuntime.ndiSenders[n]` 刚加进去时 phase = starting、sender 还没 running；测试 / 代码要等 `sender.isRunning`。
   停也是异步的：`setOutputEnabled(false)` 之后要等 `ndiSenders[n] == nil`。起停中快照又变了不用管，做完会按最新快照再对一次。
2. **两个会话同时跑 App 测试会互相踩**（W3-E2 报告 §5 第 2 条）：测试宿主共用 UserDefaults suite 与 `/tmp/switcher-tests/`。跑之前查 `pgrep -fl "xcodebuild .*test"`，
   **查到了就等**（本会话第 2 次全量开跑前查到了 P4 在单跑 S7，没拦住，重叠了 6 s，两边碰巧都过）。
3. **`testS7_diskFullSwitchesToFallbackDirectory_recordingContinues` 在机器忙时偶发 missed_render +1**（本会话第 1 次全量、P4 的 App 全量各红一次；之后本会话 4 次——第 2 次全量 + 单跑 3 轮——都过，P4 单跑 2 次也过），
   与本会话的改动无关（P4 分支没有它们）；要稳可以请用户定是不是给这条的 missed_render 断言留余量（阈值归用户）。
4. **App 测试的 NDI 回环在测试宿主里直接发现得到本机源**（本机这几次都没弹本地网络权限提示；为什么不弹没查，换机器 / 换签名后若发现不到源，先看系统设置里的本地网络权限），
   NDI 源名是 `机器名 (输出名)`；测试用带 pid 的唯一名字，网络上别的机器也能看到这些测试源，跑完就停。
5. 表的 50 ms 定时器在 session 里（`meterFeed`），调音台不再自己起定时器；`MixerPanelView.audio` 这个属性删了，接线看 `MainWindowController.bind` 里的 `meterToken`。
6. 多画面窗口的"关着"用 `MultiviewWindowController.closed` 判（`isOpen`），不要用 `isVisible`：最小化的窗口 isVisible 也是 false，遮挡通知与最小化通知的先后不定。
7. 读多画面纹理找表条要避开刻度线：表高 1/5…4/5 各有一道 50% 白的刻度（本会话第一次采样就采在 20% 那道线上）。
8. macOS 升到了 27.0（26A428）；Xcode 27.0 编 / 测都照常；本 worktree 用钉版本的 Package.resolved 编 frameprobe 49 s，起得来。
9. 输出设置 › 虚拟摄像头页的"来源"下拉是摆设：`VirtualCameraOutput` 恒发 PGM（本会话读代码时发现，没改，问题单 `reports/issues/W3E3-virtual-camera-source-picker-ignored.md`）。
10. App 里不再用 `ExternalDisplaySpec.displayIDKey`（包里为 App 的后备留着的常量），包会话可以一起删。
