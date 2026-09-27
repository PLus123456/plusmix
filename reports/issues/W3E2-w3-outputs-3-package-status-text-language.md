# W3E2 → W3-C2（w3-outputs-3）：SwitcherOutputs 里给人看的中文文案，App 已改成自己查表；包里剩下的请收口

提出：W3-E2（`w3-app-3`，2026-09-23，做 G4 问题单 `G4-w3-app2-localize-w3c-app-strings.md` 第 2 条时）。
归：W3-C2 / `w3-outputs-3`（`Packages/SwitcherOutputs/Sources/External/`、`VirtualCamera/`；ISO 那一处归 W3-C 的 `Sources/ISO/`，W3-C2 的归属行里没有，请检查点定）。
严重级：S3（界面上的英文模式里夹中文；功能不受影响）。

## 现状

App 从 W3-E2 起**不再调用**下面这几个返回中文的函数，改成按枚举在 App 侧查表（`App/Sources/Engine/OutputStatusText.swift`、`App/Sources/Settings/ISORoutes.swift` 的 `remainingText`）：

| 包里的函数 | App 侧的替代 |
|---|---|
| `SystemExtensionInstaller.describe(_:)` | `OutputStatusText.extensionStatus(_:)`（键 `aux.extension.*`） |
| `ExternalDisplayManager.describe(_:)` | `OutputStatusText.externalWindow(_:)`（键 `aux.external.*`） |
| `ExternalDisplaySpec.describe(_:inputs:)` | App 的 `OutputSource.title(in:)`（键 `source.*`） |
| `DiskEstimate.describe(seconds:)`（SwitcherISO） | `ISORoutes.remainingText(seconds:)`（键 `disk.remaining.*`） |

还剩三处会**原样**出现在界面上（App 没法查表，因为包给的是拼好的字符串）：

1. `SystemExtensionInstaller.status(for:)` 的 `.failed(String)`：`"App 里没有扩展（…）：需要带 Team ID 签名…；BLOCKED-签名"`、`"签名 / 权限 / 位置不满足（…）"`、`"请求被取消"`、`"请求被更新的请求替代"`。
   App 显示成 `L("aux.extension.failed", 原因)`，英文界面里原因是中文。
2. `ExternalDisplayWindow` 的 `window.title = "Switcher 外部输出"`（全屏窗口，平时看不见，Mission Control / 窗口菜单里看得见）。
3. `CMIOSinkStreamClient` 的错误描述（`"找不到虚拟摄像头设备（扩展没装或没激活）"` 等）——现在只进日志，没进界面；以后要进界面同理。

## 建议

- `.failed` 改成带一个枚举原因（`notFound` / `signature` / `canceled` / `superseded` / `other(NSError)`），诊断细节用系统本地化的 `localizedDescription`；App 按枚举查表。
  注意 `VirtualCameraAppTests.testVirtualCamera_extensionActivationInAdHocSignedApp_reportsBlocked` 断言失败文案里含"签名 / 权限 / BLOCKED-签名"——改枚举时 App 那条断言一起改（归 App，找 W3-E 系列或检查点）。
- 窗口标题给一个可注入的参数（默认英文 "Switcher External Output"），App 传本地化后的。
- 四个 `describe` 可以保留给 headless / 日志用，注释写明"日志用，界面文案在 App"。

## W3-C3（w3-outputs-4，2026-09-27）处理结果

包里不再有中文字面量（`VirtualCameraTests.SourceLanguageTests` 扫 External / VirtualCamera / ISO 与 CameraExtension/，0 处）：
1. `SystemExtensionInstaller.Status.failed(Failure)`：`Failure.reason` 是枚举（extensionNotFound / requirementsNotMet / canceled / superseded / other），
   另带系统给的 `domain` / `code` / `detail`（系统本地化的 localizedDescription）；`isSigningBlocked` = 前两种。`describe` / `developerModeHint` 删了。
2. 外部显示窗口标题：`ExternalDisplayWindow.windowTitle`（默认 ASCII "Switcher External Output"），`ExternalDisplayManager.windowTitle` 下发。
   `ExternalDisplayManager.describe` / `ExternalDisplaySpec.describe` 删了。Aux 占位默认文案 "No signal"（App 本来就传 input.noSignal）。
3. `CMIOSinkStreamClient.Error` 只有枚举（去掉中文 description）；`VirtualCameraOutput.Counters.lastError(String)` → `lastFailure(ConnectionFailure)`。
4. `DiskEstimate.describe` 删了。
App 侧要跟的几行（OutputStatusText 的 `.failed`、两条测试、新键）在 `reports/issues/W3C3-app-extension-failure-reason-and-disk-free.md`。
