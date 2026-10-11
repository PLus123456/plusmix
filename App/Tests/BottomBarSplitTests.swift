// W5-F（prompt 92）底栏三段式：每个输出都是"⚙ ｜ 主体 ｜ ▴"（docs/ui-study/01-菜单逻辑.md §1 规则 1–4、§3.5；01a E2 / E3 / E9 / G1 / K1–K3 / L1 / L2 / M1–M4；
// 04 Q03 / Q45 / Q59）。顺序：左组 添加输入 ▴ ｜ ⚙ 录制 ▴ ｜ ⚙ 外部显示 ｜ ⚙ 推流 ▴ ｜ ⚙ 多画面；右组 叠加。单独的"ISO…"按钮去掉（K2），ISO 页从录制 ⚙ 进。
// ⚙ / ▴ 的菜单都走 BottomBarPopup（W5-A 的朝上帮助函数，换算到屏幕坐标再弹）；按钮一律 refusesFirstResponder（C9）。状态行独立成窗口最底一行（E9）。
// 量菜单的位置沿用 BottomBarPopupTests 的量法（CGWindowList 取本进程弹出菜单窗口；没真弹出来时退到按定位点算的位置）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherExternal
@testable import Switcher

@MainActor
final class BottomBarSplitTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            AppTest.dismissConfirmations()
            AppTest.controller.panels.closeAll()
        }
        super.tearDown()
    }

    // MARK: 工具

    /// 菜单里能点的项（有动作的），按标题找。
    private func item(_ menu: NSMenu, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title && $0.action != nil }, "菜单里没有“\(title)”：\(menu.items.map(\.title))", file: file, line: line)
    }

    private func perform(_ menu: NSMenu, _ item: NSMenuItem) {
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// 按钮在屏幕上的位置（Cocoa 坐标）。
    private func screenFrame(_ view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // MARK: 1. 分体控件、顺序、朝上弹（E1 / E2 / E3 / K2 / C9）

    func testUI_bottomBarButtonsAreSplitAndPopupsOpenUpward() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let wc = controller.windowController
        let bar = wc.bottomBar
        let window = try XCTUnwrap(wc.window)
        AppTest.pump(seconds: 0.2)

        // 顺序（E2）：左组五个从左到右，右组叠加在最右
        let left = bar.leftGroup
        XCTAssertTrue(left.count == 5 && left[0] === bar.addInput && left[1] === bar.record && left[2] === bar.external
                      && left[3] === bar.stream && left[4] === bar.multiview, "左组顺序：添加输入 / 录制 / 外部显示 / 推流 / 多画面")
        let xs = left.map { AppTest.alignmentFrame($0, in: bar).minX }
        XCTAssertEqual(xs, xs.sorted(), "左组从左到右排：\(xs)")
        let overlay = AppTest.alignmentFrame(bar.overlayButton, in: bar)
        XCTAssertGreaterThan(overlay.minX, left.map { AppTest.alignmentFrame($0, in: bar).maxX }.max() ?? 0, "叠加在右组")
        // W5-L（98）：右组 = 叠加 ｜ 统计 ｜ 锁（锁在最右）；整组贴右边
        let stats = AppTest.alignmentFrame(bar.statsButton, in: bar), lock = AppTest.alignmentFrame(bar.lockButton, in: bar)
        XCTAssertTrue(overlay.maxX <= stats.minX && stats.maxX <= lock.minX, "右组从左到右：叠加 / 统计 / 锁")
        XCTAssertLessThanOrEqual(bar.bounds.maxX - lock.maxX, 16, "右组贴右边")

        // 三段各自可隐藏：添加输入 = 主体 + ▴；录制 / 推流 = ⚙ + 主体 + ▴；外部显示 / 多画面 = ⚙ + 主体
        func segments(_ b: SplitBarButton) -> [Bool] { [b.showsGear, b.showsBody, b.showsMenu] }
        XCTAssertEqual(segments(bar.addInput), [false, true, true], "添加输入 ▴")
        XCTAssertEqual(segments(bar.record), [true, true, true], "⚙ 录制 ▴")
        XCTAssertEqual(segments(bar.external), [true, true, false], "⚙ 外部显示")
        XCTAssertEqual(segments(bar.stream), [true, true, true], "⚙ 推流 ▴")
        XCTAssertEqual(segments(bar.multiview), [true, true, false], "⚙ 多画面")
        XCTAssertEqual(bar.addInput.bodyButton.title, "添加输入…")
        XCTAssertEqual(bar.record.bodyButton.title, "录制")
        XCTAssertEqual(bar.external.bodyButton.title, "外部显示", "统一叫外部显示（M4）")
        XCTAssertEqual(bar.stream.bodyButton.title, "推流")
        XCTAssertEqual(bar.multiview.bodyButton.title, "多画面")
        // 隐藏的那一段不占位：可见的几段挨着排，不留洞
        for b in left {
            let visible = b.allButtons.filter { !$0.isHidden }.map { AppTest.alignmentFrame($0, in: b) }.sorted { $0.minX < $1.minX }
            for (a, c) in zip(visible, visible.dropFirst()) { XCTAssertLessThanOrEqual(c.minX - a.maxX, 4, "\(b.bodyButton.title) 段与段之间不留洞") }
        }

        // K2：没有单独的"ISO…"按钮
        XCTAssertEqual(AppTest.descendants(of: bar, as: NSButton.self) { $0.title.contains("ISO") }.map(\.title), [], "单独的 ISO 按钮去掉了")

        // C9：底栏所有按钮拒绝焦点（空格 / 回车永远走快捷键表）
        let buttons = AppTest.descendants(of: bar, as: NSButton.self)
        XCTAssertGreaterThanOrEqual(buttons.count, 13, "5 个分体（13 段）+ 叠加")
        for b in buttons {
            XCTAssertTrue(b.refusesFirstResponder, "\(b.title.isEmpty ? (b.accessibilityLabel() ?? "?") : b.title) 应 refusesFirstResponder")
            XCTAssertFalse(b.acceptsFirstResponder, "\(b.title) 不收焦点")
        }
        // ⚙ / ▴ 只有图标：要有辅助功能名字与提示
        for b in left {
            if b.showsGear {
                XCTAssertEqual(b.gearButton.accessibilityLabel(), L("bottom.gear.a11y", b.name), "⚙ 的辅助功能名")
                XCTAssertNotNil(b.gearButton.toolTip)
            }
            if b.showsMenu {
                XCTAssertEqual(b.menuButton.accessibilityLabel(), L("bottom.menu.a11y", b.name), "▴ 的辅助功能名")
                XCTAssertNotNil(b.menuButton.toolTip)
            }
        }
        // 空格仍落到快捷键表（窗口 keyDown）：PVW = 2 → 空格 = Cut
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        bar.record.bodyButton.performClick(nil)   // 点过按钮之后焦点也不留在按钮上
        XCTAssertNil(ConfirmationCenter.shared.pending(), "开始录制不问")
        XCTAssertFalse(window.firstResponder is NSButton, "点按钮后焦点不在按钮上：\(String(describing: window.firstResponder))")
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 }, "空格 = Cut（没被按钮吃掉）")
        controller.settings.confirmBeforeStop = false
        defer { controller.settings.confirmBeforeStop = true }
        bar.record.bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.outputs.allSatisfy { !$0.enabled } && session.outputs.recorders.isEmpty })

        // 弹出物：每个 ⚙ / ▴ 的菜单朝上开、整块在窗口里、不用子菜单（E1）。1440×900 与最小窗口两种尺寸
        let saved = window.frame
        defer { window.setFrame(saved, display: true) }
        let popups: [(String, NSButton)] = [("添加输入 ▴", bar.addInput.menuButton), ("录制 ⚙", bar.record.gearButton), ("录制 ▴", bar.record.menuButton),
                                           ("外部显示 ⚙", bar.external.gearButton), ("推流 ▴", bar.stream.menuButton)]
        for size in [NSSize(width: 1440, height: 900), NSSize(width: 1100, height: 700)] {
            let frame = AppTest.setMainWindowSize(size)
            for (name, anchor) in popups {
                let label = "[\(Int(size.width))×\(Int(size.height))] \(name)"
                let real = AppTest.measurePoppedMenu(open: { anchor.performClick(nil) }, menu: { wc.activeBottomMenu })
                let menu = try XCTUnwrap(wc.activeBottomMenu, "\(label) 应弹出菜单")
                XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil }, "\(label) 底栏菜单不用子菜单")
                let measured = real.max { $0.height < $1.height }
                let menuFrame = measured ?? BottomBarPopup.menuFrameInScreen(for: menu, from: anchor)
                let reference = measured != nil ? (AppTest.windowServerFrame(of: window) ?? frame) : frame
                let buttonTop = reference.minY + anchor.convert(anchor.bounds, to: nil).maxY
                print("\(label) 菜单 \(measured == nil ? "（按定位点算）" : "（实测）") \(menuFrame)；窗口 \(reference)；按钮上沿 \(buttonTop)")
                XCTAssertGreaterThanOrEqual(menuFrame.minY, buttonTop - 1, "\(label) 朝上开：底边不低于按钮上沿")
                XCTAssertTrue(reference.insetBy(dx: -0.5, dy: -0.5).contains(menuFrame), "\(label) 菜单 \(menuFrame) 整块在窗口 \(reference) 里")
                wc.activeBottomMenu?.cancelTracking()
            }
        }
        window.setFrame(saved, display: true)

        // ⚙ 直达设置页：推流 ⚙ = 输出设置 › 推流；多画面 ⚙ = 多画面布局；录制 ⚙ 菜单 = 录制设置… / ISO 分路录制…
        bar.stream.gearButton.performClick(nil)
        XCTAssertEqual(controller.panels.outputSettingsWindow?.model.tab, .stream, "推流 ⚙ → 推流页")
        bar.multiview.gearButton.performClick(nil)
        XCTAssertEqual(controller.panels.outputSettingsWindow?.model.tab, .multiview, "多画面 ⚙ → 多画面布局页")
        let gear = bar.recordGearMenu()
        XCTAssertEqual(gear.items.map(\.title), ["录制设置…", "ISO 分路录制…"], "录制 ⚙ 的菜单（K1 / K2）")
        perform(gear, try item(gear, "ISO 分路录制…"))
        XCTAssertEqual(controller.panels.outputSettingsWindow?.model.tab, .iso, "ISO 页从录制 ⚙ 进")
        perform(gear, try item(gear, "录制设置…"))
        XCTAssertEqual(controller.panels.outputSettingsWindow?.model.tab, .record)
        XCTAssertTrue(controller.panels.outputSettingsWindow?.window?.isVisible == true)
    }

    // MARK: 2. 推流 ⚙ / ▴（L1 / L2；G6 追加 ① ②）

    func testUI_streamMenuListsDestinationsWithState() throws {
        // 纯函数部分：两个目的地，一个在推（带码率）、一个起不来 → 两项状态正确、勾按"在推"打
        let state = MixerState(outputs: [
            OutputState(number: 2, kind: .stream, name: "主平台", enabled: true),
            OutputState(number: 3, kind: .stream, name: "备用", enabled: true),
            OutputState(number: 4, kind: .stream, name: "推流 3", enabled: false),
        ])
        let rows = StreamMenuRow.rows(state: state, encoder: [Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 6_020_000, frames: 900, state: "publishing"),
                                                               Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 0, state: "failed")],
                                      failure: { $0 == 3 ? "地址的协议 foo 不认" : nil })
        XCTAssertEqual(rows.map(\.title), ["主平台 · 推流中 · 6.02 Mb/s", "备用 · 起不来", "推流 3 · 未开"])
        XCTAssertEqual(rows.map(\.check), [.on, .mixed, .off], "勾 = 在推；开着但没推起来 = 横杠；没开 = 空")
        XCTAssertEqual(rows.map(\.click), [.stop, .retry, .start], "点 = 只起停这一路；起不来的那一路 = 单路重试")
        XCTAssertTrue(rows[1].toolTip?.contains("地址的协议 foo 不认") == true, "起不来的原因写在提示里")

        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        let bar = wc.bottomBar
        var notices: [String] = []
        let token = session.observeNotices { notices.append($0) }
        defer { token.invalidate() }

        // L1：没有目的地时主体不灰；点了打开推流页并把焦点放在"添加目的地"
        XCTAssertFalse(session.state.outputs.contains { $0.kind == .stream })
        XCTAssertTrue(bar.stream.bodyButton.isEnabled, "没有目的地时主体不灰（L1）")
        bar.stream.bodyButton.performClick(nil)
        let page = try XCTUnwrap(controller.panels.outputSettingsWindow, "点了打开输出设置")
        XCTAssertEqual(page.model.tab, .stream)
        XCTAssertEqual(page.model.addDestinationFocusRequests, 1, "要求把焦点放在“添加目的地”")
        XCTAssertTrue(AppTest.waitUntil(3) { (page.window?.firstResponder as? NSTextView).flatMap { ($0.delegate as? NSTextField)?.placeholderString } == L("outputSettings.stream.urlPrompt") },
                      "焦点在“添加目的地”的地址框：\(String(describing: page.window?.firstResponder))")
        let empty = bar.streamMenu()
        XCTAssertFalse(try item(empty, "全部开始").isEnabled, "没有目的地：全部开始灰")
        XCTAssertFalse(try item(empty, "全部停止").isEnabled)
        controller.panels.closeAll()

        // 端到端：主平台推到本机 MediaMTX（在推；scripts/mediamtx.yml 只开了 s1–s3 这几个路径、不带推流码），备用的地址不认（起不来，地址里带账号密码）
        try MediaMTXHarness.requireAvailable()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5f-stream-\(UUID().uuidString)", isDirectory: true)
        let mtx = try MediaMTXHarness(rtmpPort: 24937, srtPort: 28897, apiPort: 29997, recordDir: dir)
        defer { mtx.stop(); try? FileManager.default.removeItem(at: dir) }
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        session.send(.addOutput(config: OutputState(number: 2, kind: .stream, name: "主平台", enabled: false,
                                                    settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                                             stream: StreamSettings(url: mtx.rtmpURL("s2"))))))
        session.send(.addOutput(config: AppTest.streamOutput(number: 3, url: "foo://alice:hunter2@example.com/live", name: "备用")))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.filter { $0.kind == .stream }.count == 2 })
        let start = bar.streamMenu()
        XCTAssertTrue(try item(start, "全部开始").isEnabled)
        XCTAssertFalse(try item(start, "全部停止").isEnabled, "都没开：全部停止灰")
        perform(start, try item(start, "全部开始"))
        XCTAssertNil(ConfirmationCenter.shared.pending(), "开始不问")
        XCTAssertTrue(AppTest.waitUntil(15) { bar.encoderEntry(forOutput: 2)?.state == "publishing" && session.outputs.failureReason(output: 3) != nil },
                      "主平台在推、备用起不来：\(String(describing: bar.encoderEntry(forOutput: 2)))，\(session.outputs.failed)")
        XCTAssertTrue(AppTest.waitUntil(5) { (bar.encoderEntry(forOutput: 2)?.bitrate ?? 0) > 0 && bar.encoderEntry(forOutput: 3)?.state == "failed" })
        let healthy = try XCTUnwrap(session.outputs.streams[2])

        let menu = bar.streamMenu()
        XCTAssertEqual(Array(menu.items.prefix(2)).map(\.title), ["全部开始", "全部停止"])
        let main = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("主平台 · ") }, menu.items.map(\.title).description)
        let backup = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("备用 · ") }, menu.items.map(\.title).description)
        XCTAssertTrue(main.title.hasPrefix("主平台 · 推流中 · ") && (main.title.hasSuffix("Mb/s") || main.title.hasSuffix("kb/s")), "名字 · 状态 · 码率：\(main.title)")
        XCTAssertEqual(main.state, .on, "在推 = 勾")
        XCTAssertEqual(backup.title, "备用 · 起不来")
        XCTAssertEqual(backup.state, .mixed)
        XCTAssertTrue(try item(menu, "全部停止").isEnabled)
        XCTAssertTrue(menu.items.contains { $0.title == "推流设置…" } && menu.items.contains { $0.title == "推流状态…" }, menu.items.map(\.title).description)
        // G6 追加 ①：菜单 / 提示里不出现地址里的账号密码
        let texts = menu.items.flatMap { [$0.title, $0.toolTip ?? ""] } + [bar.stream.bodyButton.toolTip ?? "", bar.stream.bodyButton.title]
        XCTAssertFalse(texts.contains { $0.contains("hunter2") || $0.contains("alice") }, "地址里的账号密码不能显示：\(texts)")
        XCTAssertTrue(backup.toolTip?.contains("<redacted>") == true || backup.toolTip?.contains("example.com") == true, "提示里的地址打码显示：\(backup.toolTip ?? "")")

        // 点起不来的那一项 = 单路重试：正常在推的不停、不重建、不问
        let failuresBefore = notices.filter { $0.contains("推流 3") }.count
        perform(menu, backup)
        AppTest.pump(seconds: 0.5)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "重试不问")
        XCTAssertTrue(session.outputs.streams[2] === healthy, "主平台没被停、没被重建")
        XCTAssertEqual(session.state.output(3)?.enabled, true)
        XCTAssertGreaterThan(notices.filter { $0.contains("推流 3") }.count, failuresBefore, "备用重试过（又报了一次原因）：\(notices)")

        // G6 追加 ②：有一路一直起不来时，正常在推的那几路也能停——点在推的那一项 = 只停它（先问）
        let menu2 = bar.streamMenu()
        perform(menu2, try XCTUnwrap(menu2.items.first { $0.title.hasPrefix("主平台 · ") }))
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.stopStream), "停在推的这一路先问")
        XCTAssertEqual(ask.request.title, "确定停止推流（1 路）？")
        XCTAssertTrue(ask.request.message.contains("主平台"), ask.request.message)
        XCTAssertFalse(ask.request.message.contains("备用"), "只停这一路：\(ask.request.message)")
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(2)?.enabled == false && session.outputs.streams[2] == nil }, "主平台停了")
        XCTAssertEqual(session.state.output(3)?.enabled, true, "备用没动")
        // 停了的那一项：点 = 只开它
        let menu3 = bar.streamMenu()
        let stopped = try XCTUnwrap(menu3.items.first { $0.title.hasPrefix("主平台 · ") })
        XCTAssertEqual(stopped.state, .off)
        perform(menu3, stopped)
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(2)?.enabled == true && session.outputs.streams[2] != nil }, "单路开始")
        // 全部停止：连起不来的那一路一起停（先问，两路）
        let menu4 = bar.streamMenu()
        perform(menu4, try item(menu4, "全部停止"))
        let all = try XCTUnwrap(AppTest.waitForConfirmation(.stopStream))
        XCTAssertEqual(all.request.title, "确定停止推流（2 路）？")
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.outputs.filter { $0.kind == .stream }.allSatisfy { !$0.enabled } && session.outputs.streams.isEmpty },
                      "全部停止 = 全部目的地都停（含起不来的）")
        XCTAssertNil(session.outputs.failureReason(output: 3), "停用了就不算起不来")

        // 同一份菜单挂在菜单栏"输出 › 推流 ▸"；⚙ = 推流页、"推流设置… / 推流状态…"也指向推流页（101 之前）
        let outputMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "输出" }?.submenu)
        AppTest.delegate.menuNeedsUpdate(outputMenu)
        let streamItem = try XCTUnwrap(outputMenu.items.first { $0.title == "推流" && $0.submenu != nil }, "菜单栏 输出 › 推流 ▸：\(outputMenu.items.map(\.title))")
        XCTAssertEqual(streamItem.submenu?.items.map(\.title), bar.streamMenu().items.map(\.title), "和底栏 ▴ 同一份菜单")
        let menu5 = bar.streamMenu()
        perform(menu5, try item(menu5, "推流状态…"))
        XCTAssertEqual(controller.panels.outputSettingsWindow?.model.tab, .stream)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 3. 录制 ▴：每路一行，点 = 只停这一路（K1 / K3）

    func testUI_recordMenuStopsSingleRoute() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        let controller = AppTest.controller
        let bar = controller.windowController.bottomBar
        for n in [2, 3] {
            let iso = ISORoutes.makeISOOutput(for: try XCTUnwrap(session.state.input(n)), in: session.state, defaultDirectory: controller.documents.recordDirectory)
            session.send(.addOutput(config: iso))
            XCTAssertTrue(AppTest.waitUntil(2) { ISORoutes.isoRecord(in: session.state, input: n) != nil })
        }
        let records = ISORoutes.allRecords(in: session.state)
        XCTAssertEqual(records.map(\.name), ["录制", "ISO 2", "ISO 3"])

        // 主体照旧：PGM + ISO 同一拍一起起
        bar.record.bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(10) { records.allSatisfy { r in session.outputs.recorders[r.number] != nil && bar.encoderEntry(forOutput: r.number)?.state == "recording" } },
                      "三路都在录：\(records.map { bar.encoderEntry(forOutput: $0.number)?.state ?? "-" })")
        let menu = bar.recordMenu()
        let rows = menu.items.filter { $0.title.contains(" · ") }
        XCTAssertEqual(rows.map(\.title), ["录制 · 录制中", "ISO 2 · 录制中", "ISO 3 · 录制中"], "每个录制输出一行：名字 · 状态（Stats.encoder 按 output 对号）")
        XCTAssertTrue(rows.allSatisfy { $0.state == .on && $0.isEnabled })
        XCTAssertEqual(menu.items.last?.title, "全部停止", "末尾“全部停止”")
        XCTAssertFalse(menu.items.contains { $0.title.contains("开始") }, "不给中途单独开始：\(menu.items.map(\.title))")

        // 点 ISO 2 = 只停这一路（先问，写明是哪一路）
        let iso2 = try XCTUnwrap(ISORoutes.isoRecord(in: session.state, input: 2))
        perform(menu, try item(menu, "ISO 2 · 录制中"))
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.stopRecord), "停这一路先问")
        XCTAssertEqual(ask.request.title, "确定停止录制（1 路）？")
        XCTAssertTrue(ask.request.message.contains("ISO 2"), ask.request.message)
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(iso2.number)?.enabled == false && session.outputs.recorders[iso2.number] == nil && session.outputs.lastResults[iso2.number] != nil },
                      "ISO 2 停并封口")
        for r in records where r.number != iso2.number {
            XCTAssertEqual(session.state.output(r.number)?.enabled, true, "\(r.name) 照录")
            XCTAssertNotNil(session.outputs.recorders[r.number], "\(r.name) 的录制器没被停")
        }
        // 停了的那一行：灰、没有勾（不给中途单独开始）；主体按钮写"录制中（2 路）"
        XCTAssertTrue(AppTest.waitUntil(3) { bar.recordMenu().items.first { $0.title.hasPrefix("ISO 2 · ") }?.isEnabled == false })
        let menu2 = bar.recordMenu()
        let stoppedRow = try XCTUnwrap(menu2.items.first { $0.title.hasPrefix("ISO 2 · ") })
        XCTAssertEqual(stoppedRow.title, "ISO 2 · 未开")
        XCTAssertEqual(stoppedRow.state, .off)
        XCTAssertTrue(AppTest.waitUntil(3) { bar.record.bodyButton.title == "● 录制中（2 路）" }, bar.record.bodyButton.title)

        // 全部停止：剩下的两路一起停（先问）
        perform(menu2, try item(menu2, "全部停止"))
        let all = try XCTUnwrap(AppTest.waitForConfirmation(.stopRecord))
        XCTAssertEqual(all.request.title, "确定停止录制（2 路）？")
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(15) { records.allSatisfy { session.state.output($0.number)?.enabled == false } && session.outputs.recorders.isEmpty })
        XCTAssertFalse(try item(bar.recordMenu(), "全部停止").isEnabled, "都停了：全部停止灰")
        XCTAssertTrue(AppTest.waitUntil(3) { bar.record.bodyButton.title == "录制" })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 4. 外部显示：⚙ = 路由菜单（每块屏单选），主体 = 全部开 / 关、保留配置（M1–M4）

    func testUI_externalDisplayBodyTogglesAllKeepingConfig() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let controller = AppTest.controller
        let wc = controller.windowController
        let bar = wc.bottomBar
        defer {
            for o in session.state.outputs where o.kind == .externalDisplay { session.send(.removeOutput(output: o.number)) }
            AppTest.waitUntil(3) { session.aux.external.windows.isEmpty }
        }
        let displays = ExternalDisplays.all()
        let mainDisplay = try XCTUnwrap(displays.first { $0.isMain } ?? displays.first, "没有显示器")
        let externalOutputs = { session.state.outputs.filter { $0.kind == .externalDisplay } }
        XCTAssertEqual(externalOutputs().count, 0)
        XCTAssertNil(bar.external.bodyButton.bezelColor, "都没开：不高亮")

        // 一路都没配：第一次点 = 在第一块非主屏上开 PGM；没有第二块屏 = 弹路由菜单
        if let second = displays.first(where: { !$0.isMain }) {
            bar.external.bodyButton.performClick(nil)
            XCTAssertTrue(AppTest.waitUntil(3) { externalOutputs().count == 1 }, "第一次点在非主屏上开一路")
            let first = try XCTUnwrap(externalOutputs().first)
            XCTAssertEqual(ExternalDisplaySpec(settings: first.settings).displayID, second.id, "第一块非主屏")
            XCTAssertEqual(first.settings.source, .program, "送 PGM")
            XCTAssertTrue(first.enabled)
        } else {
            let real = AppTest.measurePoppedMenu(open: { bar.external.bodyButton.performClick(nil) }, menu: { wc.activeBottomMenu })
            XCTAssertNotNil(wc.activeBottomMenu, "只有一块屏：弹路由菜单（\(real.count) 个菜单窗口）")
            XCTAssertEqual(externalOutputs().count, 0, "没有第二块屏时不自己加")
        }

        // 路由菜单（M2）：主屏那一段单选——最上"关闭"（有配置时），下面是来源；没有输出时点来源 = addOutput
        func section(of display: DisplayInfo) throws -> [NSMenuItem] {
            let menu = try XCTUnwrap(wc.externalOutputMenu())
            return try XCTUnwrap(AppTest.menuSections(menu).first { $0.first?.title.hasPrefix(display.name) == true }, "\(display.name) 那一段")
        }
        func pick(_ title: String, on display: DisplayInfo) throws {
            let menu = try XCTUnwrap(wc.externalOutputMenu())
            let sec = try XCTUnwrap(AppTest.menuSections(menu).first { $0.first?.title.hasPrefix(display.name) == true })
            let item = try XCTUnwrap(sec.first { $0.title.hasPrefix(title) && $0.action != nil }, "\(title)：\(sec.map(\.title))")
            perform(menu, item)
        }
        XCTAssertNil(try section(of: mainDisplay).first { $0.title == "关闭" }, "这块屏没有配置时不列“关闭”（菜单高度预算，见报告）")
        try pick("PVW", on: mainDisplay)
        XCTAssertTrue(AppTest.waitUntil(3) { externalOutputs().contains { ExternalDisplaySpec(settings: $0.settings).displayID == mainDisplay.id && $0.enabled } })
        let onMain = try XCTUnwrap(externalOutputs().first { ExternalDisplaySpec(settings: $0.settings).displayID == mainDisplay.id })
        XCTAssertEqual(onMain.settings.source, .preview)
        var sec = try section(of: mainDisplay)
        XCTAssertEqual(sec.first { $0.title == "PVW" }?.state, .on, "勾 = 正在输出的来源")
        XCTAssertEqual(sec.first { $0.title == "关闭" }?.state, .off)
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[onMain.number] != nil })
        let windowBefore = session.aux.external.windows[onMain.number]

        // 已有输出时换来源 = setOutputSettings（同一个输出、窗不重开、同一块屏不叠第二路）
        try pick("PGM", on: mainDisplay)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(onMain.number)?.settings.source == .program }, "换源 = setOutputSettings")
        XCTAssertEqual(externalOutputs().filter { ExternalDisplaySpec(settings: $0.settings).displayID == mainDisplay.id }.count, 1, "同一块屏不叠第二路")
        AppTest.pump(seconds: 0.3)
        XCTAssertTrue(session.aux.external.windows[onMain.number] === windowBefore, "窗不重开")
        sec = try section(of: mainDisplay)
        XCTAssertEqual(sec.filter { $0.state == .on }.map(\.title), ["PGM"], "单选：只有 PGM 打勾")

        // "关闭" = 这块屏不出画面、配置留着；关着的来源标"（已关）"
        try pick("关闭", on: mainDisplay)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(onMain.number)?.enabled == false }, "关闭 = setOutputEnabled(false)")
        XCTAssertNotNil(session.state.output(onMain.number), "配置留着")
        sec = try section(of: mainDisplay)
        XCTAssertEqual(sec.first { $0.title == "关闭" }?.state, .on)
        XCTAssertTrue(sec.contains { $0.title == "PGM（已关）" }, "关着的来源标（已关）：\(sec.map(\.title))")
        try pick("PGM", on: mainDisplay)   // 再选回来 = 打开同一路
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(onMain.number)?.enabled == true })

        // 主体 = 全部外部显示一起关、配置保留；再点 = 全部按原配置打开（同一批输出编号）
        let configured = externalOutputs()
        XCTAssertTrue(AppTest.waitUntil(2) { bar.external.bodyButton.bezelColor != nil }, "开着：高亮")
        bar.external.bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { externalOutputs().allSatisfy { !$0.enabled } }, "主体 = 全部关")
        XCTAssertEqual(externalOutputs().map(\.number), configured.map(\.number), "配置都在")
        XCTAssertEqual(externalOutputs().map(\.settings), configured.map(\.settings), "来源 / 显示器不变")
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows.isEmpty }, "窗口都收起")
        XCTAssertTrue(AppTest.waitUntil(2) { bar.external.bodyButton.bezelColor == nil }, "关着：不高亮")
        bar.external.bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { externalOutputs().allSatisfy(\.enabled) }, "再点 = 全部开")
        XCTAssertEqual(externalOutputs().map(\.number), configured.map(\.number), "没有新增输出")
        XCTAssertTrue(AppTest.waitUntil(3) { configured.allSatisfy { session.aux.external.windows[$0.number] != nil } })

        // M3：菜单末尾"外部显示设置… / NDI® 发送设置…"
        let menu = try XCTUnwrap(wc.externalOutputMenu())
        let tail = try XCTUnwrap(AppTest.menuSections(menu).last)
        XCTAssertEqual(tail.map(\.title), ["外部显示设置…", "NDI® 发送设置…"])
        perform(menu, try item(menu, "外部显示设置…"))
        XCTAssertEqual(controller.panels.outputSettingsWindow?.model.tab, .external)
        perform(menu, try item(menu, "NDI® 发送设置…"))
        XCTAssertEqual(controller.panels.outputSettingsWindow?.model.tab, .ndi)

        // M4：全 App 统一叫"外部显示"（底栏、菜单、设置页、strings），不再有"外部输出"
        XCTAssertEqual(menu.title, "外部显示")
        let zh = try XCTUnwrap(L10n.table(language: "zh-Hans"))
        XCTAssertEqual(zh.filter { $0.value.contains("外部输出") }.keys.sorted(), [], "zh-Hans 文案里还有“外部输出”")
        let en = try XCTUnwrap(L10n.table(language: "en"))
        XCTAssertEqual(en.filter { $0.value.range(of: "external output", options: .caseInsensitive) != nil }.keys.sorted(), [], "en 文案统一叫 External Display")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 5. 添加输入 ▴：八种类型直达 + 最近添加的来源一键再加（G1 / Q59）

    func testUI_addInputMenuRecentReAddsWithFreeNumber() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        let bar = wc.bottomBar
        let window = try XCTUnwrap(wc.window)
        controller.addInputHistory.reset()
        defer { controller.addInputHistory.reset() }
        let fixture = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov")

        // ▴：八种类型直达（和添加面板左栏同一顺序）+ 最近添加的来源（还没有）
        var menu = try XCTUnwrap(wc.addInputMenu())
        let kinds = AddInputModel.Kind.displayOrder.map { $0.title + "…" }   // W5-K：左栏分组后的顺序（合成测试源在最后）
        XCTAssertEqual(Array(menu.items.filter { $0.action != nil }.prefix(8)).map(\.title), kinds, "八种类型直达")
        XCTAssertFalse(menu.items.contains { $0.isSectionHeader && $0.title == L("addInputMenu.recent") }, "没有最近添加的来源时不列这一段")

        // 主体 = 打开添加面板（第一次停在摄像头 / 采集卡，W5-K / G2）；切到合成测试源加一路 30 fps
        bar.addInput.bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        var sheet = try XCTUnwrap(window.attachedSheet?.windowController as? AddInputSheetController)
        XCTAssertEqual(sheet.model.kind, .camera)
        sheet.selectKindForTesting(.synthetic)
        sheet.form.model.syntheticFrameRate = .fps30
        sheet.confirmForTesting()
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.input(1) != nil && window.attachedSheet == nil })

        // ▴ 里点"视频文件…" = 面板直接停在视频文件页；加一路文件输入（2 号）
        menu = try XCTUnwrap(wc.addInputMenu())
        perform(menu, try item(menu, AddInputModel.Kind.file.title + "…"))
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        sheet = try XCTUnwrap(window.attachedSheet?.windowController as? AddInputSheetController)
        XCTAssertEqual(sheet.model.kind, .file, "类型直达")
        sheet.form.model.filePath = fixture.path
        sheet.confirmForTesting()
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.input(2)?.kind == .file && window.attachedSheet == nil })

        // 主体 = 停在上次的类型（视频文件）
        bar.addInput.bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        sheet = try XCTUnwrap(window.attachedSheet?.windowController as? AddInputSheetController)
        XCTAssertEqual(sheet.model.kind, .file, "主体停在上次的类型")
        sheet.cancelForTesting()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet == nil })

        // 最近添加的来源：新的在前
        menu = try XCTUnwrap(wc.addInputMenu())
        let header = try XCTUnwrap(menu.items.firstIndex { $0.isSectionHeader && $0.title == L("addInputMenu.recent") }, "最近添加的来源一段：\(menu.items.map(\.title))")
        let recent = menu.items[(header + 1)...].filter { $0.action != nil }
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent[0].title.contains("pattern.mov"), "最新的在前：\(recent.map(\.title))")
        XCTAssertTrue(recent[1].title.contains(AddInputModel.Kind.synthetic.title), recent.map(\.title).description)

        // 删掉 1 号 → 再加合成源：编号取空号（1），来源照抄，名字自动取
        session.send(.removeInput(input: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1) == nil })
        menu = try XCTUnwrap(wc.addInputMenu())
        let again = try XCTUnwrap(menu.items.first { $0.title == recent[1].title && $0.action != nil })
        perform(menu, again)
        XCTAssertNil(window.attachedSheet, "一键再加，不弹面板")
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.input(1) != nil }, "编号取空号 1：\(session.state.inputs.map(\.number))")
        guard case .synthetic(let s)? = session.state.input(1)?.source else { return XCTFail("来源照抄：\(String(describing: session.state.input(1)))") }
        XCTAssertEqual(s.frameRate, .fps30)
        XCTAssertEqual(session.state.input(1)?.name, L("addInput.defaultName.synthetic", 1, "30"), "名字自动取")
        // 再点一次 = 下一个空号（3）
        menu = try XCTUnwrap(wc.addInputMenu())
        perform(menu, try XCTUnwrap(menu.items.first { $0.title == recent[1].title && $0.action != nil }))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.input(3) != nil }, "\(session.state.inputs.map(\.number))")

        // 菜单栏"输入 › 按类型添加 ▸"用同一份菜单
        let inputMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "输入" }?.submenu)
        AppTest.delegate.menuNeedsUpdate(inputMenu)
        let byType = try XCTUnwrap(inputMenu.items.first { $0.title == L("menu.input.addByType") && $0.submenu != nil }, inputMenu.items.map(\.title).description)
        XCTAssertEqual(byType.submenu?.items.map(\.title), try XCTUnwrap(wc.addInputMenu()).items.map(\.title))
        XCTAssertEqual(inputMenu.items.first?.keyEquivalent, "i", "⌘I 保留在“添加输入…”上")

        // 最多 5 项、同一个来源只留最新的一次
        for rate in [FrameRate.fps24, .fps25, .fps50, .fps60, .fps30] {
            controller.addInputHistory.noteAdded(InputConfig(number: 9, name: "x", source: .synthetic(settings: SyntheticSourceSettings(frameRate: rate))))
        }
        XCTAssertEqual(controller.addInputHistory.recentSources.count, 5, "最多 5 项")
        XCTAssertEqual(Set(controller.addInputHistory.recentSources.map { "\($0)" }).count, 5, "不重复")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 6. 状态行独立成窗口最底一行（E9 / Q45 / V-22）

    func testUI_statusLineIsFullWidthBottomRow() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let wc = AppTest.controller.windowController
        let bar = wc.bottomBar
        let window = try XCTUnwrap(wc.window)
        let content = try XCTUnwrap(window.contentView)
        let saved = window.frame
        defer { window.setFrame(saved, display: true) }
        XCTAssertTrue(AppTest.waitUntil(5) { bar.lastStatusLine != nil }, "要有一行 Stats")

        for size in [NSSize(width: 1440, height: 900), NSSize(width: 1100, height: 700)] {
            AppTest.setMainWindowSize(size)
            let label = "[\(Int(size.width))×\(Int(size.height))]"
            let row = content.convert(bar.statusBar.bounds, from: bar.statusBar)
            // 最底一行、全宽（不翻转的内容视图：y = 0 是下沿）
            XCTAssertEqual(row.minY, 0, accuracy: 0.5, "\(label) 状态行贴窗口下沿")
            XCTAssertEqual(row.minX, 0, accuracy: 0.5, "\(label) 全宽：左")
            XCTAssertEqual(row.width, content.bounds.width, accuracy: 0.5, "\(label) 全宽：右")
            // 按钮都在状态行上面，不共一行
            for b in bar.leftGroup.map({ $0 as NSView }) + [bar.overlayButton, bar.statsButton, bar.lockButton] {
                let f = content.convert(b.alignmentRect(forFrame: b.frame), from: b.superview)
                XCTAssertGreaterThanOrEqual(f.minY, row.maxY, "\(label) 按钮在状态行上面")
            }
            // 左右留白对称、文字上下居中
            let left = bar.statusBar.convert(bar.statusLabel.frame, from: bar.statusLabel.superview)
            let right = bar.statusBar.convert(bar.noticeLabel.frame, from: bar.noticeLabel.superview)
            XCTAssertEqual(left.minX, bar.statusBar.bounds.maxX - right.maxX, accuracy: 0.5, "\(label) 左右留白对称")
            XCTAssertEqual(left.midY, bar.statusBar.bounds.midY, accuracy: 1, "\(label) 上下居中")
            XCTAssertEqual(right.midY, bar.statusBar.bounds.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(right.minX, left.maxX, "\(label) 右端的字不压左边的状态")
        }

        // 格式写短（E9）：1080p60 / 1080p59.94；非 16:9 写全宽高
        XCTAssertEqual(StatusLineFormatter.formatText(.hd1080p60), "1080p60")
        XCTAssertEqual(StatusLineFormatter.formatText(.hd1080p5994), "1080p59.94")
        XCTAssertEqual(StatusLineFormatter.formatText(.uhd2160p30), "2160p30")
        XCTAssertEqual(StatusLineFormatter.formatText(ProgramFormat(width: 1080, height: 1920, frameRate: .fps30)), "1080×1920p30")
        let shown = try XCTUnwrap(bar.lastStatusLine)
        XCTAssertTrue(shown.text.hasPrefix("节目 1080p60  ·  "), shown.text)
        XCTAssertEqual(bar.statusLabel.stringValue, shown.text, "左边就是 Stats 算出来的那一行（右端的本机信息不进 Stats、不进这一行）")

        // 统一语言（V-22）：中文界面里字段名都是中文（GPU / CPU 是通用缩写）；英文界面里没有中文
        let a = Stats(ts: 100, tick: Tick(600), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
                      audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 10, gpuPct: 20)
        XCTAssertEqual(StatusLineFormatter.fields(current: a, previous: nil, format: .hd1080p5994).map(\.label), ["节目", "帧率", "渲染", "GPU", "CPU", "丢帧", "编码跳帧", "码率", "磁盘"])
        L10n.languageOverride = "en"
        let enLabels = StatusLineFormatter.fields(current: a, previous: nil, format: .hd1080p5994).map(\.label)
        L10n.languageOverride = "zh-Hans"
        XCTAssertEqual(enLabels, ["Program", "FPS", "Render", "GPU", "CPU", "Dropped", "Enc. skipped", "Bitrate", "Disk"])

        // 右端：平时是本机信息（机型 · 内存，不进 Stats）；有提示时显示提示，过几秒回到本机信息
        let machine = StatusBarView.machineInfo
        XCTAssertTrue(machine.contains(" · ") && machine.hasSuffix("GB"), "机型 · 内存：\(machine)")
        XCTAssertEqual(bar.noticeLabel.stringValue, machine)
        let statsJSON = String(decoding: try JSONEncoder().encode(shown.stats), as: UTF8.self)
        XCTAssertFalse(statsJSON.contains(machine), "本机信息不进 Stats")
        bar.showNotice("测试提示")
        XCTAssertEqual(bar.displayedNotice, "测试提示")
        XCTAssertEqual(bar.noticeLabel.stringValue, "测试提示")
        XCTAssertTrue(AppTest.waitUntil(BottomBarView.noticeSeconds + 2) { bar.noticeLabel.stringValue == machine }, "提示过了回到本机信息")
        XCTAssertEqual(bar.displayedNotice, "", "提示过期")

        // G6 追加 ③：调音台 340，分隔条 1 pt 不算在调音台里
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth, accuracy: 0.5, "调音台 340（原来 339）")
        wc.toggleMixerPanel()
        AppTest.pump(seconds: 0.1)
        wc.toggleMixerPanel()
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth, accuracy: 0.5, "收起再展开也是 340")
    }

    // MARK: C9 的实测：系统"键盘导航"开着时（测试宿主读的是系统设置，进程里改不了；关着就跳过）

    func testUI_spaceNotEatenByBottomBarButtonsWithKeyboardNavigation() throws {
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        let bar = wc.bottomBar
        guard bar.record.bodyButton.canBecomeKeyView || NSApp.isFullKeyboardAccessEnabled else {
            throw XCTSkip("BLOCKED-系统设置：系统“键盘导航”关着（AppleKeyboardUIMode 未设）；打开它再跑这一条（探针结论见 reports/w5-app-bottom-bar.md §5）")
        }
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        let window = try XCTUnwrap(wc.window)
        // Tab 走一圈：焦点永远不落在底栏的按钮上
        window.makeFirstResponder(nil)
        let barButtons = AppTest.descendants(of: bar, as: NSButton.self)
        for _ in 0..<40 {
            window.selectNextKeyView(nil)
            XCTAssertFalse(barButtons.contains { $0 === window.firstResponder }, "Tab 不该停在底栏按钮上：\(String(describing: window.firstResponder))")
        }
        window.makeFirstResponder(nil)
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 }, "空格 = Cut")
    }
}
