# W3-C3 → 合并检查点（胶水）/ 下一个动 App/ 的会话：安装器失败原因改枚举后 App 要跟的几行；窗口标题与在跑录制器的 disk_free_mb 两处可选接线

归属会话 / 分支：App/（W3-E 系列；本批的合并检查点按胶水额度做即可：必需 33 行 + 可选 6 行，按增 + 删计）
发现于：W3-C3（`w3-outputs-4`，2026-09-27），prompt 69 交付 1 / 3；issue W3E2-w3-outputs-3-package-status-text-language 的收口
严重级：**合并阻塞**——不补必需的那几行，合入 `w3-outputs-4` 之后 App 编不过（xcodebuild 报 1 处：
`App/Sources/Engine/OutputStatusText.swift:22:56: error: argument type 'SystemExtensionInstaller.Failure' does not conform to expected type 'CVarArg'`，
测试 target 按代码看另有 2 处同类编译错误：LocalizationTests 的 `.failed("包给的诊断")`、VirtualCameraAppTests 的 `message.contains`；
没单独编，下面的 diff 打上后一起编过）。文案本身是 S3。

## 为什么变

prompt 69："包只给枚举 / 数字，文字由组装方查表"。`SystemExtensionInstaller.Status.failed(String)`（包拼好的中文句子，英文界面里原样露出）
改成 `.failed(SystemExtensionInstaller.Failure)`：

```swift
public struct Failure: Hashable, Sendable {
    public enum Reason: String, CaseIterable { case extensionNotFound, requirementsNotMet, canceled, superseded, other }
    public var reason: Reason        // 查表用
    public var domain: String        // NSError 的域 / 码：给日志
    public var code: Int
    public var detail: String        // 系统给的 localizedDescription（系统本地化），可原样附在后面
    public var isSigningBlocked: Bool { reason == .extensionNotFound || reason == .requirementsNotMet }
}
```

未签名 / ad-hoc 的宿主（本机测试宿主、没 Team ID 的 App）回的是 `OSSystemExtensionErrorDomain` 2 = missingEntitlement → `requirementsNotMet`
（探针与 `VirtualCameraTests.testInstaller_activateInUnsignedHost_failsWithSigningReason` 实测）。包里的 `describe` 系列全删了（App 早就不调）。

## 必需（不改编不过）：33 行（增 + 删）

下面的 diff 在 W3-C3 的 worktree 里临时打上验证过（没提交，App/ 不归 W3-C3）：`xcodebuild build` 通过，
`LocalizationTests` / `VirtualCameraAppTests` / `StatusLineTests` / `DiskProtectionAppTests` / `ISOAppTests` 的结果见 reports/w3-outputs-4.md §2。

1. `App/Sources/Engine/OutputStatusText.swift`：`.failed` 按原因查表，系统描述附在后面。
2. 两个 `Localizable.strings`：`aux.extension.failure.{extensionNotFound,requirementsNotMet,canceled,superseded,other,detail}` 共 6 个键。
3. `App/Tests/LocalizationTests.swift`：`.failed("包给的诊断")` 换成每个原因各两条（带 / 不带系统描述；不带的那条检查原因本身的英文里没有中文）。
4. `App/Tests/VirtualCameraAppTests.swift`：`guard case .failed(let message)` + 查中文字样 → `failure.isSigningBlocked` + 查表后的文案含"BLOCKED-签名"。

## 可选（不改也编得过、测试也过）：6 行

5. **窗口标题**：包里默认 ASCII "Switcher External Output"（`ExternalDisplayWindow.defaultWindowTitle`）；想要本地化就在
   `SwitcherSession` 设 `aux.external.windowTitle = L("aux.external.windowTitle")` + 两个键（Mission Control / 窗口菜单里看得见）。
6. **在跑录制器的 disk_free_mb**（W3-C 报告 §4 第 4 条 / issue W3C-w1-outputs-recorder-freebytes-nonboot-volume，W1-E 的 `Recorder.freeBytes`
   还没修）：`OutputRuntime.swift` 的 `EncoderStatsSource.entries()` 里 `.recorder` 那一项改调 `DiskGuard.statsEntry(for:counters:previous:windowSeconds:)`——
   除 disk_free_mb 外与 `RecorderCounters.statsEntry` 逐字段相同；录制器自己读到 0（非启动卷）时由 DiskGuard 重新量。
   W3-C3 实测 50 MB 镜像：录制器读 0，这里 48.8 MB（`RecorderDiskTests`）。W1-E 修好之后这行也不必撤（读数不是 0 就原样用）。

## diff（在 67d0f6b + w3-outputs-4 上打的）

```diff
diff --git a/App/Resources/en.lproj/Localizable.strings b/App/Resources/en.lproj/Localizable.strings
index 95c566a..f607fb0 100644
--- a/App/Resources/en.lproj/Localizable.strings
+++ b/App/Resources/en.lproj/Localizable.strings
@@ -131,6 +131,12 @@
 "aux.displayState.stopped" = "stopped";
 "aux.displayState.waitingExtension" = "waiting for extension";
 "aux.extension.failed" = "failed: %@";
+"aux.extension.failure.canceled" = "request canceled";
+"aux.extension.failure.detail" = "%@ (%@)";
+"aux.extension.failure.extensionNotFound" = "the extension is not in the app; it must be signed with a Team ID and embedded in Contents/Library/SystemExtensions (BLOCKED: signing)";
+"aux.extension.failure.other" = "other error";
+"aux.extension.failure.requirementsNotMet" = "code signing, entitlement or location requirements not met; sign with a Team ID and run from /Applications (BLOCKED: signing)";
+"aux.extension.failure.superseded" = "request superseded by a newer one";
 "aux.extension.installed" = "installed (%@)";
 "aux.extension.installedNoVersion" = "installed";
 "aux.extension.needsReboot" = "takes effect after restart";
@@ -142,6 +148,7 @@
 "aux.external.fallbackToMain" = "Display %u is missing, using the main display";
 "aux.external.showing" = "Showing (display %u)";
 "aux.external.waitingForDisplay" = "Waiting for display %u";
+"aux.external.windowTitle" = "Switcher External Output";
 "aux.virtualCamera.disabled" = "not enabled";
 "aux.virtualCamera.idle" = "not started";
 "aux.virtualCamera.publishing" = "Connected, %ld frames sent";
diff --git a/App/Resources/zh-Hans.lproj/Localizable.strings b/App/Resources/zh-Hans.lproj/Localizable.strings
index b4b97f2..436b972 100644
--- a/App/Resources/zh-Hans.lproj/Localizable.strings
+++ b/App/Resources/zh-Hans.lproj/Localizable.strings
@@ -131,6 +131,12 @@
 "aux.displayState.stopped" = "已停止";
 "aux.displayState.waitingExtension" = "等扩展";
 "aux.extension.failed" = "失败：%@";
+"aux.extension.failure.canceled" = "请求被取消";
+"aux.extension.failure.detail" = "%@（%@）";
+"aux.extension.failure.extensionNotFound" = "App 里没有扩展，要带 Team ID 签名并嵌入 Contents/Library/SystemExtensions（BLOCKED-签名）";
+"aux.extension.failure.other" = "其他错误";
+"aux.extension.failure.requirementsNotMet" = "签名 / 权限 / 位置不满足，要带 Team ID 签名、从 /Applications 运行（BLOCKED-签名）";
+"aux.extension.failure.superseded" = "请求被更新的请求替代";
 "aux.extension.installed" = "已安装（%@）";
 "aux.extension.installedNoVersion" = "已安装";
 "aux.extension.needsReboot" = "重启后生效";
@@ -142,6 +148,7 @@
 "aux.external.fallbackToMain" = "显示器 %u 不在，暂用主显示器";
 "aux.external.showing" = "显示中（显示器 %u）";
 "aux.external.waitingForDisplay" = "等待显示器 %u 接上";
+"aux.external.windowTitle" = "Switcher 外部输出";
 "aux.virtualCamera.disabled" = "未启用";
 "aux.virtualCamera.idle" = "未启动";
 "aux.virtualCamera.publishing" = "已连接，送出 %ld 帧";
diff --git a/App/Sources/Engine/OutputRuntime.swift b/App/Sources/Engine/OutputRuntime.swift
index 684be03..f65e092 100644
--- a/App/Sources/Engine/OutputRuntime.swift
+++ b/App/Sources/Engine/OutputRuntime.swift
@@ -576,7 +576,8 @@ final class EncoderStatsSource: @unchecked Sendable {
                 switch list[i].source {
                 case .recorder(let r):
                     let c = r.counters
-                    out.append(c.statsEntry(previous: list[i].previousRecorder, windowSeconds: window, state: r.state.statsName))
+                    // disk_free_mb：录制器自己读到 0（非启动卷，Recorder.freeBytes 的问题单）时由 DiskGuard 重新量（W3-C3）
+                    out.append(DiskGuard.statsEntry(for: r, counters: c, previous: list[i].previousRecorder, windowSeconds: window))
                     list[i].previousRecorder = c
                 case .stream(let s):
                     let c = s.counters
diff --git a/App/Sources/Engine/OutputStatusText.swift b/App/Sources/Engine/OutputStatusText.swift
index e5712b0..37eb991 100644
--- a/App/Sources/Engine/OutputStatusText.swift
+++ b/App/Sources/Engine/OutputStatusText.swift
@@ -1,6 +1,6 @@
 // 显示类输出与系统扩展的状态文案（W3-E2；G4 问题单 G4-w3-app2-localize-w3c-app-strings 第 2 条、提案 013）：
 // - SwitcherOutputs 里的 `SystemExtensionInstaller.describe` / `ExternalDisplayManager.describe` / `ExternalDisplaySpec.describe` 返回中文，
-//   包不该管语言：App 按枚举查表（`.failed(String)` 带的原因是包给的诊断文字，原样附在后面）。
+//   包不该管语言：App 按枚举查表（W3-C3 起包里的 describe 都删了；`.failed` 带的是枚举原因 + 系统给的描述，原因查表、描述附在后面）。
 // - 帧数与状态只读 `Stats.display[]`（铁律 4：菜单、状态行、设置页、API、测试读同一个结构），不再直接读
 //   `VirtualCameraOutput.countersSnapshot` / `MetalDisplayView.presentedFrames`。
 import SwitcherContracts
@@ -19,10 +19,16 @@ enum OutputStatusText {
         case .installed(let v): v.isEmpty ? L("aux.extension.installedNoVersion") : L("aux.extension.installed", v)
         case .uninstalled: L("aux.extension.uninstalled")
         case .needsReboot: L("aux.extension.needsReboot")
-        case .failed(let m): L("aux.extension.failed", m)
+        case .failed(let f): L("aux.extension.failed", failureReason(f))
         }
     }
 
+    /// 扩展请求失败的原因（W3-C3：包只给枚举原因 + 系统给的描述）：原因查表，系统描述（系统本地化）附在后面。
+    static func failureReason(_ f: SystemExtensionInstaller.Failure) -> String {
+        let reason = L("aux.extension.failure.\(f.reason.rawValue)")
+        return f.detail.isEmpty ? reason : L("aux.extension.failure.detail", reason, f.detail)
+    }
+
     /// 外部显示窗口的状态（状态变化时的提示用；持续的帧数看 `display(_:)`）。
     static func externalWindow(_ s: ExternalDisplayWindow.Status) -> String {
         switch s {
diff --git a/App/Sources/Engine/SwitcherSession.swift b/App/Sources/Engine/SwitcherSession.swift
index 85fef8f..a81db77 100644
--- a/App/Sources/Engine/SwitcherSession.swift
+++ b/App/Sources/Engine/SwitcherSession.swift
@@ -102,6 +102,7 @@ final class SwitcherSession {
             close: { [weak inputs] n, slot in if let s = slot as? LockFreeFrameSlot { inputs?.releaseBranch(s, input: n) } })
         aux.external.inputStateProvider = { [weak inputs] n in inputs?.runtimeState(of: n) }
         aux.external.noSignalText = L("input.noSignal")
+        aux.external.windowTitle = L("aux.external.windowTitle")   // W3-C3：包里的默认标题是 ASCII
         control = ControlRuntime(stateMachine: stateMachine, engine: engine, api: settings.apiConfiguration, hotkeyTable: hotkeyTable, midiTable: midiTable,
                                  compat: settings.compatConfiguration)
         lastSnapshot = stateMachine.publisher.latest
diff --git a/App/Tests/LocalizationTests.swift b/App/Tests/LocalizationTests.swift
index c98889b..393fa95 100644
--- a/App/Tests/LocalizationTests.swift
+++ b/App/Tests/LocalizationTests.swift
@@ -48,7 +48,11 @@ final class LocalizationTests: XCTestCase {
     /// 每个枚举值 / Stats.display 的每个 state 都有两种语言的文案，英文里没有中文（W3-E2 交付第 1 条，G4 问题单第 2 条）。
     func testL10n_packageStatusesLookedUpInApp() {
         let installer: [SystemExtensionInstaller.Status] = [.unknown, .notInstalled, .requesting, .needsUserApproval, .installed(version: "1.0"),
-                                                            .installed(version: ""), .uninstalled, .needsReboot, .failed("包给的诊断")]
+                                                            .installed(version: ""), .uninstalled, .needsReboot]
+            + SystemExtensionInstaller.Failure.Reason.allCases.flatMap { reason -> [SystemExtensionInstaller.Status] in
+                // W3-C3：失败 = 枚举原因（查表）+ 系统给的描述（原样附在后面）；不带描述的那条检查原因本身的英文
+                [.failed(.init(reason: reason, domain: "x", code: 1, detail: "包给的诊断")), .failed(.init(reason: reason, domain: "x", code: 1, detail: ""))]
+            }
         let windows: [ExternalDisplayWindow.Status] = [.showing(displayID: 2), .waitingForDisplay(displayID: 3), .fallbackToMain(displayID: 4)]
         func texts() -> [String] {
             installer.map(OutputStatusText.extensionStatus) + windows.map(OutputStatusText.externalWindow)
diff --git a/App/Tests/VirtualCameraAppTests.swift b/App/Tests/VirtualCameraAppTests.swift
index 416b695..efc3538 100644
--- a/App/Tests/VirtualCameraAppTests.swift
+++ b/App/Tests/VirtualCameraAppTests.swift
@@ -61,8 +61,9 @@ final class VirtualCameraAppTests: XCTestCase {
         if case .needsUserApproval = installer.status {
             throw XCTSkip("系统要求用户批准：这台机器有可用的签名，人工在系统设置里允许后再验证 QuickTime / FaceTime")
         }
-        guard case .failed(let message) = installer.status else { return XCTFail() }
-        XCTAssertTrue(message.contains("BLOCKED-签名") || message.contains("签名") || message.contains("权限"), message)
+        guard case .failed(let failure) = installer.status else { return XCTFail() }
+        XCTAssertTrue(failure.isSigningBlocked, "\(failure)")   // W3-C3：包给枚举原因，文字 App 查表
+        XCTAssertTrue(OutputStatusText.extensionStatus(installer.status).contains("BLOCKED-签名"), OutputStatusText.extensionStatus(installer.status))
         XCTAssertTrue((session.lastNotice ?? "").contains("虚拟摄像头扩展"), session.lastNotice ?? "")
         // 输出设置 › 虚拟摄像头页用的是同一个安装器（W3-C 的 SystemExtensionInstaller，扩展 ID 来自 VirtualCameraConstants），
         // 不再另有一个猜 bundle ID 的查询器：状态文案跟着它走
```

## 处理结果（G4 续做合入会话，2026-09-27）

必需 33 行与可选 6 行**都打了**（胶水提交 e380db5，App 胶水额度 42 / 50）。`git apply --3way` 时三个文件各一处相邻行冲突（两个 Localizable.strings 与 `SwitcherSession.swift`：W3-E3 在同一位置加了 `aux.rawPictureNote` / `mainScreenLayering`），两边都留。
App 全量结果在 reports/G4-notes.md §13。
