# P4 → 合并检查点 / W3-E3：App 的"过渡键被忽略"缩略图用例要跟着 P4 的 reducer 搬迁改（合入 P4 时必须同时打，13 行）

归属会话 / 分支：App/（W3-E3 = `w3-app-4`，prompt 68；或合并 P4 的检查点用 App/ 胶水额度）
发现于：P4（分支 `p4-contracts`，2026-09-27）跑 `make test-app`
严重级：S1（不打这个补丁，P4 合入后 App 测试必红一条；产品行为是对的）

## 现象

`MultiviewSettingsTests.testThumbnails_ignoreLegacyLayoutKeyLikeRenderer()` 红：
`XCTAssertEqual failed: (NormalizedRect(x: 0.00625, y: 0.342, width: 0.3236, height: 0.316)) is not equal to (NormalizedRect(x: 0.2552, y: 0.5074, width: 0.2406, height: 0.2333)) - 过渡键被忽略：缩略图仍按默认布局切，与渲染器一致`

## 原因（预期内的行为变化）

这条用例是 G4 第二批合入时按 W3-B2 的裁定改的：API 直接 `addOutput` 一个带 `extra["layout"] = "3x3"` 的多画面输出，断言"过渡键被忽略、缩略图仍按默认布局"。
P4（prompt 67 交付 3，W3-B2 报告 §4 第 4 条）让 reducer 对 addOutput / setOutputSettings / loadShow 进来的设置先跑 `migratingLegacyKeys()`：
旧键被搬进正式字段 `OutputSettings.multiview = 预设 "3x3"`，渲染器与缩略图都按 3x3 切——上面失败信息里的实际值就是 3x3 布局里输入 2 的格子，说明搬迁在 App 里端到端生效了。
用例要验的"缩略图与渲染器同一个来源"没变，变的是前提（旧键不再被丢掉）。

## 补丁（P4 会话在本机验证过：打上后 `-only-testing:SwitcherTests/MultiviewSettingsTests` 2 / 2 过，验证完已还原，P4 分支不含 App/ 改动）

```diff
diff --git a/App/Tests/MultiviewLayoutTests.swift b/App/Tests/MultiviewLayoutTests.swift
index b9f2d91..04f7d93 100644
--- a/App/Tests/MultiviewLayoutTests.swift
+++ b/App/Tests/MultiviewLayoutTests.swift
@@ -110,9 +110,10 @@ final class MultiviewSettingsTests: XCTestCase {
         AppTest.controller.panels.closeAll()
     }
 
-    /// 没经过 Show.load 的内存状态（API 直接 addOutput 一个带过渡键 extra["layout"] 的多画面输出）：W3-B2 起渲染器只读正式字段、过渡键一律忽略，
-    /// 缩略图与它同一个来源——带旧键的输出对布局没有影响，两边都按默认布局切格子（P3 报告 §4 第 1 条：后备保留一个版本后删除；G4 第二批合入时改的用例）。
-    func testThumbnails_ignoreLegacyLayoutKeyLikeRenderer() throws {
+    /// API 直接 addOutput 一个带过渡键 extra["layout"] 的多画面输出（没经过 Show.load）：P4 起状态机先按 Show.load 同一套规则把它搬进正式字段
+    /// （`OutputSettings.multiview` = 预设 "3x3"），渲染器与缩略图读的都是正式字段——两边一起按 3x3 切格子，旧键不再被静默丢成默认布局
+    /// （W3-B2 报告 §4 第 4 条；G4 第二批合入时这条曾改成"过渡键被忽略"，P4 之后前提变了）。
+    func testThumbnails_legacyLayoutKeyFromAPIMigratedLikeRenderer() throws {
         let session = try AppTest.freshSession()
         try AppTest.addSynthetics(session, count: 2)
         let wc = AppTest.controller.windowController
@@ -122,9 +123,13 @@ final class MultiviewSettingsTests: XCTestCase {
         session.send(.addOutput(config: OutputState(number: number, kind: .multiview, name: "legacy", enabled: false,
                                                     settings: OutputSettings(source: .multiview, extra: ["layout": .string("3x3")]))))
         XCTAssertTrue(AppTest.waitUntil(2) { session.state.output(number) != nil })
-        AppTest.pump(seconds: 0.5)
-        XCTAssertEqual(wc.inputStrip.cells[2]?.display.sourceRect, defaultRect, "过渡键被忽略：缩略图仍按默认布局切，与渲染器一致")
-        XCTAssertEqual(MultiviewLayout.placements(settings: nil, inputs: [1, 2], width: 1920, height: 1080).first { $0.source == .input(number: 2) }?.inner, defaultRect)
+        let settings = try XCTUnwrap(session.state.output(number)?.settings)
+        XCTAssertEqual(settings.multiview, MultiviewLayoutSettings(preset: "3x3"), "过渡键搬进正式字段")
+        XCTAssertNil(settings.extra["layout"], "旧键搬完清掉")
+        let migratedRect = try XCTUnwrap(MultiviewLayout.placements(settings: settings.multiview, inputs: [1, 2], width: 1920, height: 1080)
+            .first { $0.source == .input(number: 2) }?.inner)
+        XCTAssertNotEqual(migratedRect, defaultRect)
+        XCTAssertTrue(AppTest.waitUntil(2) { wc.inputStrip.cells[2]?.display.sourceRect == migratedRect }, "缩略图按搬进来的 3x3 切，与渲染器一致")
         session.send(.removeOutput(output: number))
         XCTAssertTrue(AppTest.waitUntil(2) { session.state.output(number) == nil && wc.inputStrip.cells[2]?.display.sourceRect == defaultRect })
     }
```

## 顺带（不急，W3-E3 删 `OutputExtras` 后备时一起）

- `App/Sources/Settings/OutputSettingsPanel.swift` 的 `setExternalDisplay` / `setExternalFallback` 里两处 `s = s.migratingLegacyKeys()` 与第 217 行注释"没经过 Show.load 的内存状态（API 直接 addOutput 的老写法）可能还带过渡键"：
  P4 之后状态机里的状态不会再有输出的过渡键，这两处调用成了多余（幂等、无害），注释的前提也不成立了。
