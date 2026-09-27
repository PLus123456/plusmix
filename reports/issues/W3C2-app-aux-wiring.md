# W3C2 → 合并 w3-outputs-3 的检查点（App 胶水）/ 之后的 App 会话：Aux 全分辨率要 App 接三根线，一条 App 测试跟着改

来源：W3-C2（prompt 65，分支 w3-outputs-3，报告 reports/w3-outputs-3.md §3 第 1 条、§5 第 1 条）。W3-C2 只准动 SwitcherOutputs 的 External / VirtualCamera，
App/ 不归它；下面是合并时要补的接线（App 胶水，约 15 行）和一条要跟着改的旧断言。**不接的话**：外部显示选"输入 n"时 Aux 窗口画"无信号"占位（没有帧槽可读）——
不再是 G4 时那个多画面缩略格子（G4 裁定：Aux 不再用格子）。

## 1. 接线（App/Sources/Engine/SwitcherSession.swift，建好 `inputs` 与 `aux` 之后，约第 96–107 行附近）

```swift
// W3-C2：Aux = 本包自己画输入帧。每个 Aux 窗口给那一路开一个 InputFrameTee 分支（与 ISO 共用每路 4 个的额度），窗口换输入 / 关掉时还回去
aux.external.auxFrames = AuxFrameTap(
    open: { [weak inputs] n in inputs?.openBranch(input: n) },
    close: { [weak inputs] n, slot in
        if let s = slot as? LockFreeFrameSlot { inputs?.releaseBranch(s, input: n) }
    })
// 占位与多画面缩略格子同一个来源、同一句文案
aux.external.inputStateProvider = { [weak inputs] n in inputs?.runtimeState(of: n) }
aux.external.noSignalText = L("input.noSignal")
```

- 顺序不用动：`SwitcherSession` 已经是先 `inputs.reconcile` 再 `aux.reconcile`（第 181 / 183 行），分支开在新 tee 上。
  某路换了来源（InputRuntime 重建那一路），窗口自己会还旧分支、在新 tee 上重开（`ExternalDisplayWindow.attachAux` 比较 `InputConfig.source`）。
- `import SwitcherExternal` 已有；`LockFreeFrameSlot` 要 `import SwitcherEngine`（SwitcherSession 已有）。

## 2. 要跟着改的旧断言（App/Tests/ExternalOutputAppTests.swift 第 3 步，约第 55–64 行）

现在的断言按 G4 的"Aux = 多画面第 2 格"写（`displayView.target == .multiview && sourceRect == inputCell(...)`），W3-C2 之后必红。改成：

```swift
// 3. Aux：输入 2 → AuxInputView 画输入 2 的全分辨率帧（W3-C2）；换源走 setOutputSettings
...
XCTAssertTrue(AppTest.waitUntil(3) { external.auxView.presenter.input == 2 && !external.auxView.isHidden })
XCTAssertTrue(external.displayView.isHidden, "Aux 不再用多画面纹理")
XCTAssertFalse(external.auxUnresolved)
XCTAssertTrue(AppTest.waitUntil(3) { external.auxView.presentedFrames > 10 }, "分支接上了，输入 2 的帧在画")
XCTAssertEqual(external.auxView.presenter.signal, .live)
```
（这是行为按裁定变了，不是放宽断言。）

## 3. 界面上的两处（归界面会话，W3-E2 之后的 App 会话）

- **"Aux = 原始画面"**：G4 裁定要求文案注明抠像 / 裁切 / 变换在 Aux 上不生效。外部输出菜单 / 外部显示设置页里"输入 n"那一项加一句说明
  （`ExternalDisplaySpec.describe` 在包里、只给名字，说明文字放 App 的本地化表）。
- **主屏上不盖住主界面**（W3-C 报告 §3 第 5 条）：包里已有 `ExternalDisplayManager.mainScreenLayering`（`.front` 默认 = 现状，`.behindInterface` = 层级 normal − 1，
  只影响带菜单栏的那块屏）。偏好设置加一个开关写它即可（UserDefaults 键 App 自己定；不进 `OutputSettings.display`，prompt 65 要求是包内选项）。

## 4. 与 W3-E2（w3-app-3）合并时要对一下的一处文案

W3-E2 的 `OutputStatusText.virtualCamera` 在 state = waitingExtension 时显示"找不到虚拟摄像头设备（扩展未安装 / 未激活）；已丢 %ld 帧"，帧数取 `Stats.display[]` 的 dropped。
W3-C2 复核后 **dropped = "被扩展丢弃"（连上之后丢的）**，扩展没装时丢的帧不再进 Stats（仍在 `VirtualCameraOutput.countersSnapshot.droppedNoDevice`），
所以合并后这句会一直是"已丢 0 帧"。两个分支的测试都不红（W3-E2 的 LocalizationTests 用的是自造的 entry、VirtualCameraAppTests 是拿同一行 Stats 对文案）。
建议合并时把 waitingExtension 那句的帧数去掉（"找不到虚拟摄像头设备（扩展未安装 / 未激活）"），不要为了这句把没设备的帧加回 dropped。
**若提案 018 已批并落地**（`Stats.DisplayEntry.undelivered`），这句改读 `e.undelivered` 就对了，不用删帧数。
另外 W3-C2 起多了 state = "failed"（设备在但起不来），W3-E2 的 `default: display(e)` 已经能显示（"失败 · n 帧"），`aux.displayState.failed` 两种语言都有。

## 5. 顺手可以做的（不做也不红）

- **监视器 / 多画面窗口的 dropped 也按"被覆盖的版本"算**：现在 `MainWindowController.displayStatsEntries` 填的是 `skipCounters.noDrawable`（P3 的近似）。
  包里的 `DisplayFrameLedger`（公开）就是外部显示窗口用的记账源，夹在渲染器和任何 `MetalDisplayView` 之间都行：
  ```swift
  let ledger = DisplayFrameLedger(upstream: renderer, view: programMonitor.display)
  programMonitor.display.source = ledger          // 视图对来源是弱引用：ledger 要由窗口控制器持有
  // Stats：dropped = ledger.droppedFrames；窗口收起 / 被遮住时调 ledger.breakRun()（外部显示窗口的做法见 ExternalDisplayWindow）
  ```
- **多画面窗口的 noDisplay**：P3 报告 §3 第 3 条的复核结论——它是可拖动的普通窗口、不绑显示器，没有"目标显示器不在"这回事；
  关着 = 不报这一项或报 "idle"，开着 = "presenting"，不需要 noDisplay。
- App 的 `OutputExtras.displayNumber(of:)` 还在读过渡键 `extra["displayID"]` 作后备（包里的 `ExternalDisplaySpec` 从 W3-C2 起已不读）；
  按 P3 报告 §4 第 1 条，W4 / G5 与 `MultiviewLayoutTable.parse(layout:)` 等一起删。`ExternalDisplaySpec.displayIDKey` 常量为它留着。

## 处理结果（W3-E3 / w3-app-4，2026-09-27，报告 `reports/w3-app-4.md`）

§1 / §2 / §4 由 G4 第二批合入的检查点做了（Aux 三根线、第 3 步断言、undelivered 文案）；§3 / §5 这次做完：
- §3"Aux = 原始画面"：外部输出菜单每块屏的子菜单里，输入那一组前面一行 section header（不能点），每个输入项的提示同一句；外部显示设置页 / NDI 页选了输入时来源下面显示同一句
  （键 `aux.rawPictureNote`，两种语言）。`AuxLayeringAppTests.testAux_rawPictureNoteInExternalMenuAndSettingsPages`。
- §3 主屏层级：偏好设置"外部输出在主屏上不盖住主界面"→ UserDefaults 键 `externalOutputBehindInterface`（不进 OutputSettings）→ 新 session 建好就设 `mainScreenLayering`，
  点"应用"落到跑着的 session。`testExternal_mainScreenLayeringPreferenceReachesManager`（窗口 level = behindInterfaceLevel、换 session 仍在、关掉恢复 normal）。
- §5 监视器 / 多画面窗口的 dropped：PGM 监视器与多画面窗口各夹一层 `DisplayFrameLedger`，dropped / undelivered 都从它来，遮挡变化断开连续呈现；多画面窗口关着报 idle、不记。
  `DisplayLedgerAppTests`（卡主线程 300 ms dropped +18、noDrawable 不变；遮住 1.2 s undelivered +71、dropped 不变）。
- §5 `OutputExtras.displayNumber(of:)` 只读正式字段，过渡键后备删了（`ExternalDisplaySpec.displayIDKey` 常量 App 里不再用）。
