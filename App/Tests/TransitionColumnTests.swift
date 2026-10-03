// W5-A（prompt 86）交付 2、3：转场列排版（docs/ui-study/03-目视检查.md §1.3 的布局表）与"最小步"（Q01 默认 B 的最小一步：T-bar 上方那行
// 改成只选不执行的类型菜单、时长加"自定义…"、提示从快捷键表反查、类型被改时那一行明显变化）；交付 6 的 C6（空通道的 Overlay 用 PVW 那一路）、
// V-05（高亮态标题一律白字）、V-08（时钟 12 小时制按语言的模板）。
// 量法沿用 03：x 从列左沿量；"可见边"取对齐矩形（自动布局按它排，推按钮 / 分段控件的对齐矩形就是画出来的边框）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class TransitionColumnTests: XCTestCase {
    /// 两路合成源，PGM 1 / PVW 2，Fade 30 拍。
    private func prepare() throws -> SwitcherSession {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        session.send(.setTransition(type: .fade, durationTicks: 30))
        guard AppTest.waitUntil(3, { session.state.program == 1 && session.state.preview == 2 && session.state.transition.type == .fade && session.state.transition.durationTicks == 30 }) else {
            throw XCTSkip("前提没就绪：\(session.state.transition)")
        }
        // 默认状态本来就是 Fade 30 拍，上面的条件可能在 setTransition 还没处理完时就成立：等命令日志里有它再返回（用例按日志序号数自己发的命令）
        _ = AppTest.waitUntil(2) { session.control.bus.recentEntries().contains { if case .setTransition(.fade, 30) = $0.command { return true } else { return false } } }
        AppTest.pump(seconds: 0.05)
        return session
    }

    /// 列内可见控件的左右边：按行列出（行名, 左, 右），x 从列左沿量。
    private func edges(_ panel: TransitionPanelView) -> [(String, CGFloat, CGFloat)] {
        var out: [(String, CGFloat, CGFloat)] = []
        func add(_ name: String, _ v: NSView) {
            let r = AppTest.alignmentFrame(v, in: panel)
            out.append((name, r.minX, r.maxX))
        }
        for (name, b) in [("Cut", panel.cutButton), ("Fade", panel.fadeButton), ("Wipe", panel.wipeButton), ("Zoom", panel.zoomButton),
                          ("Stinger", panel.stingerButton), ("FTB", panel.ftbButton)] { add(name, b) }
        add("时长", panel.durationControl)
        let o1 = AppTest.alignmentFrame(panel.overlayButtons[0], in: panel), o4 = AppTest.alignmentFrame(panel.overlayButtons[3], in: panel)
        out.append(("Overlay 1–4", o1.minX, o4.maxX))
        let t = AppTest.alignmentFrame(panel.tbarTypeButton, in: panel), p = AppTest.alignmentFrame(panel.paramsButton, in: panel)
        out.append(("T-bar 行", t.minX, p.maxX))
        let tbar = panel.convert(panel.tbar.handleFrame, from: panel.tbar)
        out.append(("T-bar 把手", tbar.minX, tbar.maxX))
        add("时钟", panel.clock)
        return out
    }

    func testUI_transitionColumnEdgesAligned() throws {
        _ = try prepare()
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let saved = window.frame
        defer { window.setFrame(saved, display: true) }
        let panel = wc.transitionPanel

        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        let rows = edges(panel)
        let header = AppTest.alignmentFrame(panel.overlayHeader, in: panel)
        print("转场列 1440×900（x 从列左沿量，列宽 \(panel.bounds.width)）：" + rows.map { "\($0.0) \(Int($0.1.rounded()))…\(Int($0.2.rounded()))" }.joined(separator: "；")
              + "；Overlay 组标题左 \(header.minX)")
        let left = rows[0].1, right = rows[0].2
        XCTAssertEqual(left, 8, accuracy: 1, "Cut 的左边 = 列内边距 8")
        XCTAssertEqual(right, panel.bounds.width - 8, accuracy: 1, "Cut 的右边 = 列宽 − 8")
        for (name, l, r) in rows {
            XCTAssertEqual(l, left, accuracy: 1, "\(name) 的左边应与 Cut 一致（\(l) vs \(left)）")
            XCTAssertEqual(r, right, accuracy: 1, "\(name) 的右边应与 Cut 一致（\(r) vs \(right)）")
        }
        XCTAssertEqual(header.minX, left, accuracy: 1, "组标题左对齐在 x = 8")
        // 两档控件：主操作 regular 24 pt / 13 pt 字，次要控件 small 20 pt / 11 pt 字
        let small = NSFont.systemFontSize(for: .small)
        for b in [panel.cutButton, panel.fadeButton, panel.wipeButton, panel.zoomButton, panel.stingerButton, panel.ftbButton] {
            XCTAssertEqual(b.controlSize, .regular, b.title)
            XCTAssertEqual(b.font?.pointSize ?? 0, NSFont.systemFontSize(for: .regular), accuracy: 0.1, b.title)
        }
        for c in [panel.durationControl, panel.paramsButton, panel.tbarTypeButton] + panel.overlayButtons as [NSControl] {
            XCTAssertEqual(c.controlSize, .small, "\(c)")
            XCTAssertEqual(c.font?.pointSize ?? 0, small, accuracy: 0.1, "small 控件配 small 字号：\(c)")
        }
        // 时钟：56 高、1 pt 分隔线色边框
        XCTAssertEqual(panel.clock.frame.height, 56, accuracy: 0.5)
        XCTAssertEqual(panel.clock.layer?.borderWidth, 1)
        XCTAssertEqual(panel.clock.layer?.borderColor, Theme.divider.cgColor)
        // 列最小高 ≤ 409（原来 483，比最小窗口能分到的 476 还高）
        let minHeight = panel.fittingSize.height
        print("转场列最小高 \(minHeight)")
        XCTAssertLessThanOrEqual(minHeight, 409, "列最小高")

        // 最小窗口：T-bar 行不再被压扁
        AppTest.setMainWindowSize(NSSize(width: 1100, height: 700))
        print("转场列 1100×700：列高 \(panel.bounds.height)，T-bar 高 \(panel.tbar.frame.height)")
        XCTAssertGreaterThanOrEqual(panel.tbar.frame.height, 60, "1100×700 时 T-bar ≥ 60")
        let small700 = edges(panel)
        for (name, l, r) in small700 {
            XCTAssertEqual(l, left, accuracy: 1, "1100×700 \(name) 左边")
            XCTAssertEqual(r, right, accuracy: 1, "1100×700 \(name) 右边")
        }
    }

    /// T-bar 上方那行是菜单：列五种类型、当前的打勾；选 = 只发 setTransition（不执行），快照 type 变、program / preview 不变。
    func testUI_tbarTypeMenuSelectsWithoutExecuting() throws {
        let session = try prepare()
        let panel = AppTest.controller.windowController.transitionPanel
        let menu = panel.tbarTypeMenu()
        let choices = menu.items.filter { $0.action != nil }
        XCTAssertEqual(choices.map(\.title), ["Cut", "Fade", "Wipe", "Zoom", "Stinger"])
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.title), ["Fade"], "当前类型打勾")
        let since = session.control.bus.recentEntries().last?.sequence ?? 0
        let wipe = try XCTUnwrap(choices.first { $0.title == "Wipe" })
        menu.performActionForItem(at: menu.index(of: wipe))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .wipe }, "选 Wipe 后快照的类型应是 wipe：\(session.state.transition)")
        AppTest.pump(seconds: 0.6)
        XCTAssertFalse(session.state.transition.isActive, "只选不执行")
        XCTAssertEqual(session.state.program, 1, "program 不变")
        XCTAssertEqual(session.state.preview, 2, "preview 不变")
        XCTAssertEqual(session.state.transition.durationTicks, 30, "时长不变")
        let sent = session.control.bus.recentEntries().filter { $0.sequence > since && $0.source == .ui }.map(\.command)
        XCTAssertEqual(sent, [.setTransition(type: .wipe, durationTicks: 30)], "只发一条 setTransition")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.tbarTypeText == "Wipe ▾" }, panel.tbarTypeText)
        XCTAssertEqual(panel.tbarTypeMenu().items.filter { $0.state == .on }.map(\.title), ["Wipe"])

        // 点那一行 = 在它正下方弹出类型菜单（左缘对齐；按屏幕坐标弹，见 ScreenMenu）；菜单没真弹出来（测试宿主不在前台）时跳过这一段
        let frames = AppTest.measurePoppedMenu(open: { panel.tbarTypeButton.performClick(nil) }, menu: { panel.activeMenu })
        if let menuFrame = frames.first {
            let button = panel.tbarTypeButton.window!.convertToScreen(panel.tbarTypeButton.convert(panel.tbarTypeButton.bounds, to: nil))
            print("T-bar 类型菜单（实测）\(menuFrame)；按钮 \(button)")
            XCTAssertLessThanOrEqual(menuFrame.maxY, button.minY + 1, "菜单在按钮下方")
            XCTAssertEqual(menuFrame.minX, button.minX, accuracy: 2, "左缘对齐按钮")
        } else {
            print("T-bar 类型菜单没真弹出来（测试宿主不在前台），位置这一段没量")
        }
        XCTAssertEqual(session.state.transition.type, .wipe, "弹开菜单没选 = 不改")

        // 回车（默认表 = 按已选转场）走的就是 Wipe
        AppTest.press("\r")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive && session.state.transition.type == .wipe })
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 2 && !session.state.transition.isActive })
        // 转场进行中类型菜单不可选（reducer 会拒）
        session.send(.autoTransition)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive })
        XCTAssertTrue(AppTest.waitUntil(1) { panel.tbarTypeMenu().items.filter { $0.action != nil }.allSatisfy { !$0.isEnabled } }, "转场中不可改类型")
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.transition.isActive })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 点 Fade（或菜单 切换 › Fade）会把"下一次转场"改成 Fade：T-bar 那一行要明显变化（高亮一阵），不能只换一个小字。
    func testUI_tbarTypeRowHighlightsWhenTypeChanges() throws {
        let session = try prepare()
        let panel = AppTest.controller.windowController.transitionPanel
        session.send(.setTransition(type: .wipe, durationTicks: 30))
        XCTAssertTrue(AppTest.waitUntil(2) { panel.tbarTypeText.contains("Wipe") })
        XCTAssertTrue(AppTest.waitUntil(3) { !panel.isTbarTypeHighlighted }, "高亮过一阵自己消失")
        panel.fadeButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .fade })
        XCTAssertTrue(AppTest.waitUntil(1) { panel.isTbarTypeHighlighted && panel.tbarTypeText.contains("Fade") }, "类型被 Fade 改掉时那一行高亮：\(panel.tbarTypeText)")
        XCTAssertEqual(panel.tbarTypeButton.bezelColor, Theme.accent)
        XCTAssertEqual(panel.tbarTypeButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.white, "高亮时白字")
        XCTAssertTrue(AppTest.waitUntil(4) { !panel.isTbarTypeHighlighted && !session.state.transition.isActive })
    }

    /// 时长分段加"自定义…"：时长不是预设时这一段选中、写实际值，菜单里"✓ 自定义：0.75 s"；自定义输入换拍按标称帧率。
    func testUI_transitionDurationCustomSegment() throws {
        let session = try prepare()
        let panel = AppTest.controller.windowController.transitionPanel
        let control = panel.durationControl
        XCTAssertEqual(control.segmentCount, 4)
        XCTAssertEqual(control.label(forSegment: 3), "…", "预设时最后一段是\"…\"（自定义），提示写全")
        XCTAssertEqual(control.toolTip(forSegment: 3), "自定义时长…")
        session.send(.setTransition(type: .fade, durationTicks: 45))   // API / 节目文件给的 45 拍 = 0.75 s
        XCTAssertTrue(AppTest.waitUntil(2) { control.selectedSegment == 3 }, "不是预设时选中\"自定义\"那一段：\(control.selectedSegment)")
        XCTAssertEqual(control.label(forSegment: 3), "0.75s", "那一段写实际值")
        let menu = panel.customDurationMenu()
        let current = try XCTUnwrap(menu.items.first { $0.state == .on }, menu.items.map(\.title).description)
        XCTAssertEqual(current.title, "自定义：0.75 s")
        XCTAssertNotNil(menu.items.first { $0.title == L("transition.duration.customEllipsis") && $0.action != nil }, "菜单里有\"自定义…\"")
        panel.applyCustomDuration(seconds: 1.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.durationTicks == 90 }, "1.5 s @ 60 = 90 拍：\(session.state.transition)")
        XCTAssertEqual(session.state.transition.type, .fade, "改时长不改类型")
        XCTAssertTrue(AppTest.waitUntil(1) { control.label(forSegment: 3) == "1.5s" && control.selectedSegment == 3 })
        panel.applyCustomDuration(seconds: 0)   // 不合法的不发
        AppTest.pump(seconds: 0.2)
        XCTAssertEqual(session.state.transition.durationTicks, 90)
        panel.selectDurationPresetForTesting(1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.durationTicks == 60 && control.selectedSegment == 1 })
        XCTAssertEqual(control.label(forSegment: 3), "…", "回到预设后那一段恢复成\"…\"")
        XCTAssertNil(panel.customDurationMenu().items.first { $0.state == .on }, "预设时菜单里没有打勾的自定义项")
    }

    /// 按钮提示从当前快捷键表反查（去掉写死的"回车"）；换表后跟着变。
    func testUI_transitionTooltipsFromHotkeyTable() throws {
        _ = try prepare()
        let controller = AppTest.controller
        let panel = controller.windowController.transitionPanel
        defer { try? controller.applyHotkeyTable(.default) }
        try controller.applyHotkeyTable(.default)
        XCTAssertTrue(panel.cutButton.toolTip?.contains("快捷键：空格") == true, panel.cutButton.toolTip ?? "nil")
        XCTAssertFalse(panel.fadeButton.toolTip?.contains("快捷键：回车") == true, "默认表里回车是\"按已选转场\"，不是 Fade：\(panel.fadeButton.toolTip ?? "nil")")
        XCTAssertTrue(panel.fadeButton.toolTip?.contains("没有快捷键") == true, panel.fadeButton.toolTip ?? "nil")
        XCTAssertTrue(panel.tbarTypeButton.toolTip?.contains("回车：按这里选的转场执行") == true, "回车按 T-bar 这一行选的转场执行：\(panel.tbarTypeButton.toolTip ?? "nil")")
        XCTAssertTrue(panel.ftbButton.toolTip?.contains("快捷键：F") == true, panel.ftbButton.toolTip ?? "nil")

        var table = HotkeyTable.default
        table.bindings.removeAll { $0.key == KeyCombo(key: "space") || $0.key == KeyCombo(key: "return") }
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "c", modifiers: [.shift]), action: .command(.cut)))
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "return"), action: .command(.fade(durationTicks: 30))))
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "1", modifiers: [.option]), action: .toggleOverlay(channel: 1)))
        try controller.applyHotkeyTable(table)
        XCTAssertTrue(panel.cutButton.toolTip?.contains("快捷键：⇧C") == true, "换表后提示跟着变：\(panel.cutButton.toolTip ?? "nil")")
        XCTAssertFalse(panel.cutButton.toolTip?.contains("空格") == true)
        XCTAssertTrue(panel.fadeButton.toolTip?.contains("快捷键：回车") == true, panel.fadeButton.toolTip ?? "nil")
        XCTAssertFalse(panel.tbarTypeButton.toolTip?.contains("回车：按这里选的转场执行") == true, "回车改绑 Fade 以后不再说回车按这里执行：\(panel.tbarTypeButton.toolTip ?? "nil")")
        XCTAssertTrue(panel.overlayButtons[0].toolTip?.contains("⌥1") == true, panel.overlayButtons[0].toolTip ?? "nil")
    }

    /// C6：Overlay 通道没指定输入时按下 = 用当前 PVW 那一路打开；再按 = 关，通道设置不清空；PVW 是黑场时不打开、底栏提示。
    func testUI_overlayEmptyChannelUsesPreview() throws {
        let session = try prepare()
        let wc = AppTest.controller.windowController
        let panel = wc.transitionPanel
        XCTAssertNil(session.state.overlays[2].input)
        panel.overlayButtons[2].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[2].on && session.state.overlays[2].input == 2 }, "空通道按下用 PVW（2）打开：\(session.state.overlays[2])")
        panel.overlayButtons[2].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.overlays[2].on })
        XCTAssertEqual(session.state.overlays[2].input, 2, "关的时候不清空通道设置")
        session.send(.setPreview(input: 1))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 1 })
        panel.overlayButtons[2].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[2].on && session.state.overlays[2].input == 2 }, "已指定输入的通道只开关，不换成 PVW")
        panel.overlayButtons[2].performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.overlays[2].on })
        // PVW 黑场：空通道按下不打开，底栏提示
        session.send(.setPreview(input: MixerState.noInput))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == MixerState.noInput })
        panel.overlayButtons[3].performClick(nil)
        AppTest.pump(seconds: 0.3)
        XCTAssertFalse(session.state.overlays[3].on, "没有输入可用时不打开（开了也画不出东西）")
        XCTAssertTrue(wc.bottomBar.displayedNotice.contains("Overlay 4"), "底栏提示：\(wc.bottomBar.displayedNotice)")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// V-05：高亮态（FTB / 录制 / 静音的红底，转场与 Overlay 的蓝底）标题一律白字；取消高亮回到系统配色。
    func testUI_highlightedTitlesAreWhite() throws {
        let session = try prepare()
        let wc = AppTest.controller.windowController
        func titleColor(_ b: NSButton) -> NSColor? { b.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor }
        session.send(.ftb(on: true))
        XCTAssertTrue(AppTest.waitUntil(2) { wc.transitionPanel.ftbButton.bezelColor == Theme.ftbActive })
        XCTAssertEqual(titleColor(wc.transitionPanel.ftbButton), .white, "FTB 开着：白字压红底")
        XCTAssertGreaterThanOrEqual(AppTest.contrastRatio(.white, Theme.ftbActive), 4.5)
        session.send(.ftb(on: false))
        XCTAssertTrue(AppTest.waitUntil(3) { wc.transitionPanel.ftbButton.bezelColor == nil })
        XCTAssertNotEqual(titleColor(wc.transitionPanel.ftbButton), .white, "关掉后回到系统配色")
        let cell = try XCTUnwrap(wc.inputStrip.cells[2])
        cell.muteButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { cell.muteButton.bezelColor == Theme.recording })
        XCTAssertEqual(titleColor(cell.muteButton), .white, "静音：白字")
        cell.muteButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { cell.muteButton.bezelColor == nil })
        // 录制按钮：Theme.setHighlighted 同一条路
        Theme.setHighlighted(wc.bottomBar.record.bodyButton, true, color: Theme.recording)
        XCTAssertEqual(titleColor(wc.bottomBar.record.bodyButton), .white)
        Theme.setHighlighted(wc.bottomBar.record.bodyButton, false, color: Theme.recording)
        XCTAssertNotEqual(titleColor(wc.bottomBar.record.bodyButton), .white)
    }

    /// V-08：时钟的 12 小时制用 hmma 模板按界面语言排（中文是"上午 12:13"的顺序，原来写死 "hh:mm a" 成了"12:13 上午"）。
    func testUI_clockTwelveHourUsesLocalizedTemplate() throws {
        _ = try prepare()
        let clock = AppTest.controller.windowController.transitionPanel.clock
        let expected = DateFormatter.dateFormat(fromTemplate: "hmma", options: 0, locale: L10n.locale)
        XCTAssertEqual(clock.twelveHourFormat, expected)
        XCTAssertEqual(L10n.locale.identifier, "zh-Hans", "测试宿主固定 zh-Hans，时钟跟界面语言")
        XCTAssertTrue(clock.twelveHourFormat.hasPrefix("a"), "中文 12 小时制上下午在前：\(clock.twelveHourFormat)")
    }
}
