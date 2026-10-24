// W5-A（prompt 86）交付 2、3：转场列排版（docs/ui-study/03-目视检查.md §1.3 的布局表）；交付 6 的 C6（空通道的 Overlay 用 PVW 那一路）、
// V-05（高亮态标题一律白字）、V-08（时钟 12 小时制按语言的模板）。
// W5-M（prompt 100）交付 1、2：转场列 = Cut ｜ 转场 1–4（主体 + ▾）｜ FTB（主体 + ▾）；▾ / 右键 = 只改配置不执行的菜单；主体 = 执行这个槽
// （useTransitionSlot(n, start: true)，Stinger 槽没选输入时先弹输入选择、不执行，X18）；"T-bar"组 = 弹出菜单（列四个槽，点了就做）+ 当前槽的时长分段
// + 横放的 T-bar（左 0 右 1，过 97% 松手提交后回弹，Q05 (a)）；排版沿用 86 的口径（所有可见边 8…列宽 − 8、两档控件），列最小高重量。
// 量法沿用 03：x 从列左沿量；"可见边"取对齐矩形（自动布局按它排，推按钮 / 分段控件的对齐矩形就是画出来的边框）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class TransitionColumnTests: XCTestCase {
    /// 两路合成源，PGM 1 / PVW 2，当前槽 = 转场 1（新节目的出厂四槽：1 Fade 0.5 s、2 Wipe 1 s、3 Zoom 1 s、4 Stinger 1 s 没选输入）。
    private func prepare() throws -> SwitcherSession {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        session.send(.useTransitionSlot(slot: 1, start: false))
        guard AppTest.waitUntil(3, { session.state.program == 1 && session.state.preview == 2 && session.state.transition.currentSlot == 1
            && session.state.transition.slots == TransitionSlot.factoryDefaults(for: session.state.format) }) else {
            throw XCTSkip("前提没就绪：\(session.state.transition)")
        }
        // 新节目本来就是转场 1：上面的条件可能在 useTransitionSlot 还没处理完时就成立——等命令日志里有它再返回（用例按日志序号数自己发的命令）
        _ = AppTest.waitUntil(2) { session.control.bus.recentEntries().contains { if case .useTransitionSlot(1, false) = $0.command { return true } else { return false } } }
        AppTest.pump(seconds: 0.05)
        return session
    }

    private var panel: TransitionPanelView { AppTest.controller.windowController.transitionPanel }

    /// 自上一次记下的序号以来 UI 发出的命令。
    private func uiCommands(_ session: SwitcherSession, since: UInt64) -> [Command] {
        session.control.bus.recentEntries().filter { $0.sequence > since && $0.source == .ui }.map(\.command)
    }

    private func lastSequence(_ session: SwitcherSession) -> UInt64 { session.control.bus.recentEntries().last?.sequence ?? 0 }

    /// 菜单里按标题找一项（含段标题以外的所有项）。
    private func item(_ menu: NSMenu, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "菜单里没有“\(title)”：\(menu.items.map(\.title))", file: file, line: line)
    }

    private func choose(_ menu: NSMenu, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let i = try item(menu, title, file: file, line: line)
        XCTAssertTrue(i.isEnabled, "“\(title)”应可选", file: file, line: line)
        menu.performActionForItem(at: menu.index(of: i))
    }

    /// 列内可见控件的左右边：按行列出（行名, 左, 右），x 从列左沿量。分体按钮量主体左边到 ▾ 右边。
    private func edges(_ panel: TransitionPanelView) -> [(String, CGFloat, CGFloat)] {
        var out: [(String, CGFloat, CGFloat)] = []
        func add(_ name: String, _ v: NSView) {
            let r = AppTest.alignmentFrame(v, in: panel)
            out.append((name, r.minX, r.maxX))
        }
        func addSplit(_ name: String, _ s: ColumnSplitButton) {
            let body = AppTest.alignmentFrame(s.bodyButton, in: panel), menu = AppTest.alignmentFrame(s.menuButton, in: panel)
            out.append((name, body.minX, menu.maxX))
        }
        add("Cut", panel.cutButton)
        for (i, s) in panel.slotButtons.enumerated() { addSplit("转场 \(i + 1)", s) }
        addSplit("FTB", panel.ftbSplit)
        let o1 = AppTest.alignmentFrame(panel.overlayButtons[0], in: panel), o4 = AppTest.alignmentFrame(panel.overlayButtons[3], in: panel)
        out.append(("Overlay 1–4", o1.minX, o4.maxX))
        add("T-bar 行", panel.tbarSlotButton)
        add("时长", panel.durationControl)
        add("T-bar", panel.tbar)
        let atZero = panel.convert(panel.tbar.handleFrame(at: 0), from: panel.tbar), atOne = panel.convert(panel.tbar.handleFrame(at: 1), from: panel.tbar)
        out.append(("T-bar 把手 0…1", atZero.minX, atOne.maxX))
        add("时钟", panel.clock)
        return out
    }

    // MARK: 排版（86 的口径在新列上）

    func testUI_transitionColumnEdgesAlignedWithSlots() throws {
        _ = try prepare()
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let saved = window.frame
        defer { window.setFrame(saved, display: true) }
        let panel = wc.transitionPanel
        XCTAssertEqual(panel.slotButtons.count, TransitionSlot.count, "转场 1–4 四个槽")

        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        let rows = edges(panel)
        let overlayHeader = AppTest.alignmentFrame(panel.overlayHeader, in: panel), tbarHeader = AppTest.alignmentFrame(panel.tbarHeader, in: panel)
        print("转场列 1440×900（x 从列左沿量，列宽 \(panel.bounds.width)）：" + rows.map { "\($0.0) \(Int($0.1.rounded()))…\(Int($0.2.rounded()))" }.joined(separator: "；")
              + "；组标题左 Overlay \(overlayHeader.minX) / T-bar \(tbarHeader.minX)")
        let left = rows[0].1, right = rows[0].2
        XCTAssertEqual(left, 8, accuracy: 1, "Cut 的左边 = 列内边距 8")
        XCTAssertEqual(right, panel.bounds.width - 8, accuracy: 1, "Cut 的右边 = 列宽 − 8")
        for (name, l, r) in rows {
            XCTAssertEqual(l, left, accuracy: 1, "\(name) 的左边应与 Cut 一致（\(l) vs \(left)）")
            XCTAssertEqual(r, right, accuracy: 1, "\(name) 的右边应与 Cut 一致（\(r) vs \(right)）")
        }
        XCTAssertEqual(overlayHeader.minX, left, accuracy: 1, "Overlay 组标题左对齐在 x = 8")
        XCTAssertEqual(tbarHeader.minX, left, accuracy: 1, "T-bar 组标题左对齐在 x = 8")
        // 两档控件：主操作 regular 24 pt / 13 pt 字（Cut、转场 1–4 与 FTB 的主体和 ▾），次要控件 small 20 pt / 11 pt 字
        let regular = NSFont.systemFontSize(for: .regular), small = NSFont.systemFontSize(for: .small)
        for b in [panel.cutButton, panel.ftbButton] + panel.slotButtons.map(\.bodyButton) {
            XCTAssertEqual(b.controlSize, .regular, b.title)
            XCTAssertEqual(b.font?.pointSize ?? 0, regular, accuracy: 0.1, b.title)
        }
        for s in panel.slotButtons + [panel.ftbSplit] {
            XCTAssertEqual(s.menuButton.controlSize, .regular, "▾ 与主体同一档")
            XCTAssertEqual(AppTest.alignmentFrame(s.menuButton, in: panel).height, AppTest.alignmentFrame(s.bodyButton, in: panel).height, accuracy: 0.5, "▾ 与主体同高")
            XCTAssertEqual(AppTest.alignmentFrame(s.bodyButton, in: panel).height, AppTest.alignmentFrame(panel.cutButton, in: panel).height, accuracy: 0.5, "与 Cut 同高")
        }
        for c in [panel.durationControl, panel.tbarSlotButton] + panel.overlayButtons as [NSControl] {
            XCTAssertEqual(c.controlSize, .small, "\(c)")
            XCTAssertEqual(c.font?.pointSize ?? 0, small, accuracy: 0.1, "small 控件配 small 字号：\(c)")
        }
        XCTAssertEqual(panel.tbarHeader.font?.pointSize ?? 0, small, accuracy: 0.1, "T-bar 组标题与 Overlay 组标题同字号")
        // 时钟：56 高、1 pt 分隔线色边框
        XCTAssertEqual(panel.clock.frame.height, 56, accuracy: 0.5)
        XCTAssertEqual(panel.clock.layer?.borderWidth, 1)
        XCTAssertEqual(panel.clock.layer?.borderColor, Theme.divider.cgColor)
        // T-bar 横放：宽 = 行宽，高固定；行程（把手中心从 0 到 1）够长
        XCTAssertGreaterThan(panel.tbar.frame.width, panel.tbar.frame.height * 3, "T-bar 横放")
        let travel = panel.tbar.handleFrame(at: 1).midX - panel.tbar.handleFrame(at: 0).midX
        // 列最小高 ≤ 409（86 的阈值；槽模型行数不变、T-bar 横放后不再要 60 高）
        let minHeight = panel.fittingSize.height
        print("转场列最小高 \(minHeight)；T-bar \(panel.tbar.frame.width)×\(panel.tbar.frame.height)，行程 \(travel) pt")
        XCTAssertLessThanOrEqual(minHeight, 409, "列最小高")
        XCTAssertGreaterThanOrEqual(travel, 60, "T-bar 行程 ≥ 60 pt（原来竖放时要求的最小行程）")

        // 最小窗口：列放得下、各行不被压扁、边仍对齐
        AppTest.setMainWindowSize(AppTest.minimumMainWindowSize)
        print("转场列 最小窗口 \(AppTest.minimumMainWindowSize)：列高 \(panel.bounds.height)（最小 \(minHeight)），T-bar \(panel.tbar.frame.width)×\(panel.tbar.frame.height)")
        XCTAssertGreaterThanOrEqual(panel.bounds.height, minHeight - 0.5, "最小窗口时列放得下")
        XCTAssertEqual(panel.tbar.frame.height, panel.tbar.fittingSize.height, accuracy: 0.5, "T-bar 不被压扁")
        for (name, l, r) in edges(panel) {
            XCTAssertEqual(l, left, accuracy: 1, "最小窗口 \(name) 左边")
            XCTAssertEqual(r, right, accuracy: 1, "最小窗口 \(name) 右边")
        }
    }

    // MARK: 转场 1–4：主体执行、▾ 只改配置

    /// 主体 = 执行这个槽：一条 useTransitionSlot(n, start: true)（一拍内选中并开始），按钮上的字 = 槽的效果与时长，执行中主体变蓝，
    /// 做完它成了当前槽（常亮标记 + T-bar 那一行写它）；转场进行中再点别的槽被状态机忽略。
    func testUI_transitionSlotBodyExecutesSlot() throws {
        let session = try prepare()
        let panel = self.panel
        XCTAssertEqual(panel.slotButtons.map(\.bodyButton.title), ["Fade 0.5s", "Wipe → 1s", "Zoom 1s", "Stinger 未设"], "按钮上的字 = 槽的效果与时长")
        XCTAssertEqual(panel.slotButtons.map(\.showsMarker), [true, false, false, false], "当前槽（转场 1）常亮标记")
        XCTAssertTrue(panel.tbarSlotText.hasPrefix("转场 1 · Fade 0.5 秒"), panel.tbarSlotText)
        let since = lastSequence(session)
        panel.slotButtons[2].bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive && session.state.transition.currentSlot == 3 }, "\(session.state.transition)")
        XCTAssertEqual(session.state.transition.type, .zoom)
        XCTAssertEqual(session.state.transition.durationTicks, 60)
        XCTAssertEqual(uiCommands(session, since: since), [.useTransitionSlot(slot: 3, start: true)], "一条命令选中并开始")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.slotButtons[2].bodyButton.bezelColor == Theme.accent }, "执行中主体变蓝")
        // 进行中点转场 1：状态机忽略，不打断这次 Zoom
        panel.slotButtons[0].bodyButton.performClick(nil)
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(session.state.transition.currentSlot, 3)
        XCTAssertEqual(session.state.transition.type, .zoom)
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.transition.isActive && session.state.program == 2 && session.state.preview == 1 }, "Zoom 做完对调")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.slotButtons.map(\.showsMarker) == [false, false, true, false] }, "转场 3 成了当前槽")
        XCTAssertNil(panel.slotButtons[2].bodyButton.bezelColor, "做完不再高亮")
        XCTAssertTrue(panel.tbarSlotText.hasPrefix("转场 3 · Zoom 1 秒"), panel.tbarSlotText)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        // 回车 = 执行当前槽（转场 3）
        AppTest.press("\r")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive && session.state.transition.type == .zoom })
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.transition.isActive && session.state.program == 1 })
    }

    /// ▾（或右键主体）= 菜单：效果单选（含 Cut、Wipe 五向平铺、Stinger：输入 ▸）、时长 0.5 / 1 / 2 秒 / 自定义…、参数…、用于 T-bar（不执行）、恢复出厂；
    /// 只改配置不执行，当前项打勾。改转场 2 为 Zoom 2 s：快照 slots[1] 变、PGM / PVW 不变、没开始转场、只发 setTransitionSlot。
    func testUI_transitionSlotMenuConfiguresWithoutExecuting() throws {
        let session = try prepare()
        let panel = self.panel
        let factory = TransitionSlot.factoryDefaults(for: session.state.format)
        var menu = panel.slotMenu(slot: 2)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(titles, ["效果", "Cut（无过渡：T-bar 推到顶才切）", "Fade", "Zoom", "Wipe 左 → 右", "Wipe 右 → 左", "Wipe 上 → 下", "Wipe 下 → 上", "Wipe 对角",
                                "Stinger（选输入…）", "—", "时长", "0.5 秒", "1 秒", "2 秒", "自定义…", "—",
                                "参数…（软边、Stinger 换底拍）", "用于 T-bar（不执行）", "恢复出厂"])
        XCTAssertTrue(menu.items[0].isSectionHeader && menu.items[11].isSectionHeader, "效果 / 时长是段标题")
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Wipe 左 → 右", "1 秒"], "当前项打勾")
        XCTAssertNotNil(try item(menu, "Stinger（选输入…）").submenu, "Stinger 带输入子菜单")
        XCTAssertFalse(try item(menu, "恢复出厂").isEnabled, "出厂值时恢复出厂灰着")
        // 右键主体 = 同一份菜单（打开前按当前状态重建）
        let context = try XCTUnwrap(panel.slotButtons[1].bodyButton.menu, "主体右键有菜单")
        context.delegate?.menuNeedsUpdate?(context)
        XCTAssertEqual(context.items.map { $0.isSeparatorItem ? "—" : $0.title }, titles, "右键与 ▾ 同一份菜单")

        let since = lastSequence(session)
        try choose(menu, "Zoom")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].type == .zoom }, "\(session.state.transition.slots[1])")
        menu = panel.slotMenu(slot: 2)
        try choose(menu, "2 秒")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].durationTicks == 120 }, "\(session.state.transition.slots[1])")
        var expected = factory[1]
        expected.type = .zoom
        expected.durationTicks = 120
        XCTAssertEqual(session.state.transition.slots[1], expected, "槽 2 = Zoom 2 s，Wipe / Stinger 参数原样")
        AppTest.pump(seconds: 0.3)
        XCTAssertFalse(session.state.transition.isActive, "只改配置、不执行")
        XCTAssertEqual(session.state.program, 1, "program 不变")
        XCTAssertEqual(session.state.preview, 2, "preview 不变")
        XCTAssertEqual(session.state.transition.currentSlot, 1, "当前槽不变")
        XCTAssertEqual(Array(session.state.transition.slots[2...]), Array(factory[2...]), "别的槽不变")
        XCTAssertEqual(uiCommands(session, since: since).map { CommandKind(of: $0) }, [.setTransitionSlot, .setTransitionSlot], "只发 setTransitionSlot")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.slotButtons[1].bodyButton.title == "Zoom 2s" }, "按钮上的字跟着变：\(panel.slotButtons[1].bodyButton.title)")
        menu = panel.slotMenu(slot: 2)
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Zoom", "2 秒"])
        XCTAssertTrue(try item(menu, "恢复出厂").isEnabled)

        // Wipe 方向一次点选 = 类型 + 方向；Stinger 输入从子菜单选
        try choose(menu, "Wipe 下 → 上")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].type == .wipe && session.state.transition.slots[1].wipe.direction == .bottomToTop })
        XCTAssertTrue(AppTest.waitUntil(1) { panel.slotButtons[1].bodyButton.title == "Wipe ↑ 2s" }, panel.slotButtons[1].bodyButton.title)
        menu = panel.slotMenu(slot: 2)
        let stingerInputs = try XCTUnwrap(try item(menu, "Stinger（选输入…）").submenu)
        stingerInputs.delegate?.menuNeedsUpdate?(stingerInputs)
        let input2 = try XCTUnwrap(stingerInputs.items.first { $0.title == "输入 2 合成 2" }, stingerInputs.items.map(\.title).description)
        stingerInputs.performActionForItem(at: stingerInputs.index(of: input2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1].type == .stinger && session.state.transition.slots[1].stinger.input == 2 },
                      "\(session.state.transition.slots[1])")
        menu = panel.slotMenu(slot: 2)
        XCTAssertNotNil(menu.items.first { $0.title == "Stinger：输入 2 合成 2" && $0.state == .on }, "选了输入的 Stinger 写出输入并打勾：\(menu.items.map(\.title))")

        // 用于 T-bar（不执行）= useTransitionSlot(2, start: false)：当前槽换成 2、仍不执行
        try choose(menu, "用于 T-bar（不执行）")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.currentSlot == 2 && session.state.transition.type == .stinger })
        AppTest.pump(seconds: 0.2)
        XCTAssertFalse(session.state.transition.isActive)
        XCTAssertEqual(session.state.program, 1)
        XCTAssertEqual(panel.slotMenu(slot: 2).items.first { $0.title == "用于 T-bar（不执行）" }?.state, .on, "当前槽打勾")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.slotButtons.map(\.showsMarker) == [false, true, false, false] })
        // 恢复出厂：槽 2 回到 Wipe 1 s；它是当前槽，当前那组同时按槽重拷
        try choose(panel.slotMenu(slot: 2), "恢复出厂")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[1] == factory[1] && session.state.transition.type == .wipe })
        AppTest.pump(seconds: 0.2)
        XCTAssertFalse(session.state.transition.isActive)
        XCTAssertEqual(session.state.program, 1)
        XCTAssertEqual(session.state.preview, 2)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)

        // 点 ▾ = 在整个分体按钮正下方弹出、左缘对齐（菜单没真弹出来——测试宿主不在前台——时跳过这一段）
        let frames = AppTest.measurePoppedMenu(open: { panel.slotButtons[1].menuButton.performClick(nil) }, menu: { panel.activeMenu })
        if let menuFrame = frames.first {
            let body = panel.slotButtons[1].bodyButton
            let anchor = body.window!.convertToScreen(body.convert(body.bounds, to: nil))
            print("转场 2 ▾ 菜单（实测）\(menuFrame)；主体 \(anchor)")
            XCTAssertLessThanOrEqual(menuFrame.maxY, anchor.minY + 1, "菜单在按钮下方")
            XCTAssertEqual(menuFrame.minX, anchor.minX, accuracy: 2, "左缘对齐主体")
        } else {
            print("转场 2 ▾ 菜单没真弹出来（测试宿主不在前台），位置这一段没量")
        }
        XCTAssertFalse(session.state.transition.isActive, "弹开菜单没选 = 什么都不做")
    }

    /// X18：Stinger 槽没选输入时点主体 = 弹出这个槽的输入选择（停在输入选择上）、不执行；选了输入以后点主体才执行。
    func testUI_stingerSlotWithoutInputOpensMenuInsteadOfExecuting() throws {
        let session = try prepare()
        let panel = self.panel
        XCTAssertEqual(panel.slotButtons[3].bodyButton.title, "Stinger 未设")
        XCTAssertTrue(panel.slotButtons[3].bodyButton.toolTip?.contains("还没选输入") == true, panel.slotButtons[3].bodyButton.toolTip ?? "nil")
        let since = lastSequence(session)
        _ = AppTest.measurePoppedMenu(open: { panel.slotButtons[3].bodyButton.performClick(nil) }, menu: { panel.activeMenu })
        let menu = try XCTUnwrap(panel.activeMenu, "点主体应弹出输入选择")
        XCTAssertEqual(menu.items.first?.title, "转场 4 · Stinger：先选一路输入，选好后再点一次才执行", "停在输入选择上：\(menu.items.map(\.title))")
        XCTAssertEqual(menu.items.filter { $0.action != nil }.map(\.title), ["输入 1 合成 1", "输入 2 合成 2"])
        AppTest.pump(seconds: 0.3)
        XCTAssertFalse(session.state.transition.isActive, "不执行（不然是一次延迟硬切）")
        XCTAssertEqual(session.state.program, 1)
        XCTAssertEqual(session.state.preview, 2)
        XCTAssertEqual(session.state.transition.currentSlot, 1)
        XCTAssertEqual(uiCommands(session, since: since), [], "一条命令都不发")
        // 从这个菜单选输入 2：只改槽 4 的配置
        menu.performActionForItem(at: menu.index(of: try item(menu, "输入 2 合成 2")))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[3].stinger.input == 2 }, "\(session.state.transition.slots[3])")
        AppTest.pump(seconds: 0.2)
        XCTAssertFalse(session.state.transition.isActive)
        XCTAssertTrue(AppTest.waitUntil(1) { panel.slotButtons[3].bodyButton.title == "Stinger 1s" }, panel.slotButtons[3].bodyButton.title)
        // 选了输入：点主体执行
        panel.slotButtons[3].bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive && session.state.transition.currentSlot == 4 && session.state.transition.type == .stinger })
        XCTAssertEqual(session.state.transition.stinger.input, 2)
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.transition.isActive && session.state.program == 2 })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: T-bar 跟当前槽

    /// Q07 (a)：T-bar 和回车跟当前槽。槽 3 的 ▾ 里"用于 T-bar（不执行）"之后推 T-bar 走 Zoom；T-bar 上方那行是弹出菜单，列四个槽，点了就做
    /// （2026-10-10 裁定：useTransitionSlot(n, start: true)），之后 T-bar 跟它。
    func testUI_tbarFollowsCurrentSlot() throws {
        let session = try prepare()
        let panel = self.panel
        try choose(panel.slotMenu(slot: 3), "用于 T-bar（不执行）")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.currentSlot == 3 && session.state.transition.type == .zoom })
        XCTAssertTrue(AppTest.waitUntil(1) { panel.tbarSlotText.hasPrefix("转场 3 · Zoom 1 秒") }, panel.tbarSlotText)
        panel.tbar.simulateDrag(to: 0.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.source == .tbar && abs(session.state.transition.progress - 0.5) < 0.001 }, "\(session.state.transition)")
        XCTAssertEqual(session.state.transition.type, .zoom, "T-bar 推的是当前槽的 Zoom")
        panel.tbar.simulateDrag(to: 1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && !session.state.transition.isActive }, "推到顶提交")
        XCTAssertEqual(session.state.transition.currentSlot, 3, "提交后当前槽不变")

        // T-bar 那一行的弹出菜单：四个槽、当前打勾；点"转场 2" = 执行转场 2
        let menu = panel.tbarSlotMenu()
        let slots = menu.items.filter { $0.action != nil }
        XCTAssertEqual(slots.map(\.title), ["转场 1 · Fade 0.5 秒", "转场 2 · Wipe → 1 秒", "转场 3 · Zoom 1 秒", "转场 4 · Stinger（未设）"])
        XCTAssertEqual(slots.filter { $0.state == .on }.map(\.title), ["转场 3 · Zoom 1 秒"])
        let since = lastSequence(session)
        menu.performActionForItem(at: menu.index(of: slots[1]))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive && session.state.transition.currentSlot == 2 && session.state.transition.type == .wipe })
        XCTAssertEqual(uiCommands(session, since: since), [.useTransitionSlot(slot: 2, start: true)], "点了就做")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.tbarSlotMenu().items.filter { $0.action != nil }.allSatisfy { !$0.isEnabled } }, "转场进行中四项都灰（状态机会忽略）")
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.transition.isActive && session.state.program == 1 })
        panel.tbar.simulateDrag(to: 0.3)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.source == .tbar && session.state.transition.type == .wipe }, "之后 T-bar 跟转场 2")
        panel.tbar.simulateDrag(to: 1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && !session.state.transition.isActive })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 当前槽被换掉（执行别的槽、▾ 里"用于 T-bar"、⌥n、API）时 T-bar 那一行明显变化（高亮一阵），提醒 T-bar 和回车已经换了转场。
    func testUI_tbarSlotRowHighlightsWhenCurrentSlotChanges() throws {
        let session = try prepare()
        let panel = self.panel
        session.send(.useTransitionSlot(slot: 2, start: false))
        XCTAssertTrue(AppTest.waitUntil(2) { panel.tbarSlotText.hasPrefix("转场 2") }, panel.tbarSlotText)
        XCTAssertTrue(AppTest.waitUntil(3) { !panel.isTbarSlotHighlighted }, "高亮过一阵自己消失")
        panel.slotButtons[0].bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.currentSlot == 1 })
        XCTAssertTrue(AppTest.waitUntil(1) { panel.isTbarSlotHighlighted && panel.tbarSlotText.hasPrefix("转场 1") }, "当前槽被换掉时那一行高亮：\(panel.tbarSlotText)")
        XCTAssertEqual(panel.tbarSlotButton.bezelColor, Theme.accent)
        XCTAssertEqual(panel.tbarSlotButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.white, "高亮时白字")
        XCTAssertTrue(AppTest.waitUntil(4) { !panel.isTbarSlotHighlighted && !session.state.transition.isActive })
    }

    // MARK: 时长：列里的分段 = 当前槽的时长；FTB 自己的时长

    /// Q37 (a)：列里的时长分段 = 当前槽的时长 + 自定义：选 1 s 改的是当前槽（setTransitionSlot），别的槽不动；不是预设时选中"自定义"那一段、写实际值。
    func testUI_transitionDurationSegmentIsCurrentSlot() throws {
        let session = try prepare()
        let panel = self.panel
        let control = panel.durationControl
        XCTAssertEqual(control.segmentCount, 4)
        XCTAssertEqual(control.selectedSegment, 0, "转场 1 = 0.5 s")
        XCTAssertEqual(control.label(forSegment: 3), "…", "预设时最后一段是\"…\"（自定义），提示写全")
        XCTAssertEqual(control.toolTip(forSegment: 3), "自定义时长…")
        let factory = TransitionSlot.factoryDefaults(for: session.state.format)
        let since = lastSequence(session)
        panel.selectDurationPresetForTesting(1)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[0].durationTicks == 60 && session.state.transition.durationTicks == 60 }, "\(session.state.transition)")
        XCTAssertEqual(uiCommands(session, since: since).map { CommandKind(of: $0) }, [.setTransitionSlot], "改的是当前槽")
        XCTAssertEqual(Array(session.state.transition.slots[1...]), Array(factory[1...]), "别的槽不变")
        XCTAssertTrue(AppTest.waitUntil(1) { panel.slotButtons[0].bodyButton.title == "Fade 1s" && control.selectedSegment == 1 })
        // 当前槽换成转场 3（Zoom 1 s）：分段跟着它
        session.send(.useTransitionSlot(slot: 3, start: false))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.currentSlot == 3 && control.selectedSegment == 1 })
        // 0.75 s（不是预设）：选中最后一段、写实际值，菜单里"✓ 自定义：0.75 秒"
        var slot3 = session.state.transition.slots[2]
        slot3.durationTicks = 45
        session.send(.setTransitionSlot(slot: 3, config: slot3))
        XCTAssertTrue(AppTest.waitUntil(2) { control.selectedSegment == 3 }, "不是预设时选中\"自定义\"那一段：\(control.selectedSegment)")
        XCTAssertEqual(control.label(forSegment: 3), "0.75s", "那一段写实际值")
        let current = try XCTUnwrap(panel.customDurationMenu().items.first { $0.state == .on })
        XCTAssertEqual(current.title, "自定义：0.75 秒")
        panel.applyCustomDuration(seconds: 1.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[2].durationTicks == 90 && session.state.transition.durationTicks == 90 }, "1.5 s @ 60 = 90 拍")
        XCTAssertEqual(session.state.transition.slots[2].type, .zoom, "改时长不改效果")
        panel.applyCustomDuration(seconds: 0)   // 不合法的不发
        AppTest.pump(seconds: 0.2)
        XCTAssertEqual(session.state.transition.slots[2].durationTicks, 90)
        // 转场进行中也能改（setTransitionSlot 进行中也收）：这一次按开始时的走完，做完那一拍起用新时长
        panel.slotButtons[2].bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive })
        panel.selectDurationPresetForTesting(0)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.slots[2].durationTicks == 30 })
        XCTAssertEqual(session.state.transition.durationTicks, 90, "进行中的这一次不变")
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.transition.isActive && session.state.transition.durationTicks == 30 }, "做完那一拍按当前槽重拷")
        XCTAssertEqual(control.label(forSegment: 3), "…", "回到预设后那一段恢复成\"…\"")
        XCTAssertNil(panel.customDurationMenu().items.first { $0.state == .on }, "预设时菜单里没有打勾的自定义项")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// C8 / Q08 (a)：FTB 的 ▾ / 右键 = 0.5 / 1 / 2 秒 / 自定义…（setFTBDuration，按节目帧率换拍），当前项打勾；不跟随转场时长。
    func testUI_ftbDurationMenuWritesTicks() throws {
        let session = try prepare()
        let panel = self.panel
        XCTAssertEqual(session.state.ftb.durationTicks, 30)
        var menu = panel.ftbMenu()
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, ["FTB 时长", "0.5 秒", "1 秒", "2 秒", "自定义…"])
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["0.5 秒"], "30 拍 @60 = 0.5 秒")
        let context = try XCTUnwrap(panel.ftbButton.menu, "FTB 主体右键有菜单")
        context.delegate?.menuNeedsUpdate?(context)
        XCTAssertEqual(context.items.map { $0.isSeparatorItem ? "—" : $0.title }, menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, "右键与 ▾ 同一份")
        let since = lastSequence(session)
        try choose(menu, "1 秒")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.ftb.durationTicks == 60 }, "\(session.state.ftb)")
        XCTAssertEqual(uiCommands(session, since: since), [.setFTBDuration(ticks: 60)])
        XCTAssertEqual(session.state.transition.slots, TransitionSlot.factoryDefaults(for: session.state.format), "不碰转场槽")
        XCTAssertFalse(session.state.ftb.on, "只改时长、不开 FTB")
        menu = panel.ftbMenu()
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["1 秒"])
        panel.applyCustomFTBDuration(seconds: 0.75)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.ftb.durationTicks == 45 }, "0.75 s @ 60 = 45 拍")
        menu = panel.ftbMenu()
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["自定义：0.75 秒"])
        XCTAssertTrue(panel.ftbButton.toolTip?.contains("0.75 秒") == true, "提示写出 FTB 时长：\(panel.ftbButton.toolTip ?? "nil")")
        panel.applyCustomFTBDuration(seconds: 0)   // 不合法的不发
        AppTest.pump(seconds: 0.2)
        XCTAssertEqual(session.state.ftb.durationTicks, 45)
        // FTB 开：按新时长（45 拍）渐黑
        panel.ftbButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.ftb.on })
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.ftb.level == 1 })
        panel.ftbButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.ftb.on && session.state.ftb.level == 0 })
        try choose(panel.ftbMenu(), "0.5 秒")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.ftb.durationTicks == 30 })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: T-bar 横放（Q05 (a)）

    /// 左 0 右 1；松手过 97% 提交（对调）后回弹到最左，没过就停在原位；真鼠标事件拖，量行程与手推精度（打印进报告）。
    func testUI_tbarHorizontalCommitsPast97PercentAndSpringsBack() throws {
        let session = try prepare()
        let tbar = panel.tbar
        let atZero = tbar.handleFrame(at: 0), atOne = tbar.handleFrame(at: 1)
        XCTAssertEqual(atZero.minX, 0, accuracy: 0.5, "0 在最左")
        XCTAssertEqual(atOne.maxX, tbar.bounds.width, accuracy: 0.5, "1 在最右")
        let travel = atOne.midX - atZero.midX
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            let p = tbar.convert(NSPoint(x: x, y: tbar.bounds.midY), to: nil)
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: tbar.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        /// 从把手现在的中心按下、拖到 progress 对应的位置（可以分几步）、松手。
        func drag(from start: Double, to target: Double, release: Bool = true) {
            let x0 = tbar.handleFrame(at: start).midX
            tbar.mouseDown(with: event(.leftMouseDown, x: x0))
            let x1 = tbar.handleFrame(at: target).midX
            for k in 1...10 { tbar.mouseDragged(with: event(.leftMouseDragged, x: x0 + (x1 - x0) * CGFloat(k) / 10)) }
            if release { tbar.mouseUp(with: event(.leftMouseUp, x: x1)) }
        }
        drag(from: 0, to: 0.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.source == .tbar && abs(session.state.transition.progress - 0.5) < 0.01 }, "\(session.state.transition)")
        XCTAssertEqual(session.state.program, 1, "没到顶不对调")
        XCTAssertEqual(tbar.progress, 0.5, accuracy: 0.01, "松手停在原位")
        drag(from: 0.5, to: 0.96)
        XCTAssertTrue(AppTest.waitUntil(2) { abs(session.state.transition.progress - 0.96) < 0.01 })
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(session.state.program, 1, "96% 松手不提交")
        XCTAssertEqual(tbar.progress, 0.96, accuracy: 0.01)
        drag(from: 0.96, to: 0.98)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 && !session.state.transition.isActive }, "过 97% 松手提交")
        XCTAssertTrue(AppTest.waitUntil(1) { tbar.progress == 0 }, "提交后回弹到最左：\(tbar.progress)")

        // 手推精度：按住把手往右挪 1 pt / 0.5 pt（Retina 一个像素），看推杆位置一步走多少
        let since = lastSequence(session)
        let x0 = tbar.handleFrame(at: 0).midX
        tbar.mouseDown(with: event(.leftMouseDown, x: x0))
        tbar.mouseDragged(with: event(.leftMouseDragged, x: x0 + 0.5))
        let half = tbar.progress
        tbar.mouseDragged(with: event(.leftMouseDragged, x: x0 + 1))
        let one = tbar.progress
        tbar.mouseDragged(with: event(.leftMouseDragged, x: x0))
        tbar.mouseUp(with: event(.leftMouseUp, x: x0))
        print("T-bar 横放：宽 \(tbar.bounds.width) pt、把手 \(atZero.width) pt、行程 \(travel) pt；挪 0.5 pt → \(half)，挪 1 pt → \(one)（1 pt ≈ \(100 / travel)%）")
        XCTAssertGreaterThan(one, 0, "挪 1 pt 推杆就动")
        XCTAssertEqual(one, 1 / Double(travel), accuracy: 0.002, "1 pt = 1 / 行程")
        XCTAssertGreaterThan(half, 0, "Retina 半个点（一个像素）也有分辨")
        XCTAssertFalse(uiCommands(session, since: since).contains(.tbar(progress: 1)), "小幅拖动不会提交")
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.transition.isActive || session.state.transition.progress == 0 })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 提示（从快捷键表反查）

    /// 按钮提示从当前快捷键表反查：转场 n 写 ⌥n、Cut 写空格、FTB 写 F；T-bar 那一行写"回车：执行这里的转场"；换表后跟着变。
    func testUI_transitionTooltipsFromHotkeyTable() throws {
        _ = try prepare()
        let controller = AppTest.controller
        let panel = self.panel
        defer { try? controller.applyHotkeyTable(.default) }
        try controller.applyHotkeyTable(.default)
        XCTAssertTrue(panel.cutButton.toolTip?.contains("快捷键：空格") == true, panel.cutButton.toolTip ?? "nil")
        for n in 1...4 {
            let tip = panel.slotButtons[n - 1].bodyButton.toolTip ?? "nil"
            XCTAssertTrue(tip.contains("快捷键：⌥\(n)"), "转场 \(n)：\(tip)")
            XCTAssertTrue(tip.hasPrefix("转场 \(n)"), tip)
        }
        XCTAssertTrue(panel.slotButtons[1].bodyButton.toolTip?.contains("Wipe 左 → 右 · 1 秒") == true, panel.slotButtons[1].bodyButton.toolTip ?? "nil")
        XCTAssertTrue(panel.tbarSlotButton.toolTip?.contains("回车：执行这里的转场") == true, panel.tbarSlotButton.toolTip ?? "nil")
        XCTAssertTrue(panel.ftbButton.toolTip?.contains("快捷键：F") == true, panel.ftbButton.toolTip ?? "nil")

        var table = HotkeyTable.default
        table.bindings.removeAll { $0.key == KeyCombo(key: "space") || $0.key == KeyCombo(key: "return") }
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "c", modifiers: [.shift]), action: .command(.cut)))
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "return"), action: .command(.fade(durationTicks: 30))))
        table.bindings.removeAll { $0.action == .transitionSlot(slot: 2) }
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "w", modifiers: [.control]), action: .transitionSlot(slot: 2)))
        try controller.applyHotkeyTable(table)
        XCTAssertTrue(panel.cutButton.toolTip?.contains("快捷键：⇧C") == true, "换表后提示跟着变：\(panel.cutButton.toolTip ?? "nil")")
        XCTAssertFalse(panel.cutButton.toolTip?.contains("空格") == true)
        XCTAssertTrue(panel.slotButtons[1].bodyButton.toolTip?.contains("快捷键：⌃W") == true, panel.slotButtons[1].bodyButton.toolTip ?? "nil")
        XCTAssertFalse(panel.slotButtons[1].bodyButton.toolTip?.contains("⌥2") == true)
        XCTAssertFalse(panel.tbarSlotButton.toolTip?.contains("回车：执行这里的转场") == true, "回车改绑 Fade 以后不再说回车执行这里：\(panel.tbarSlotButton.toolTip ?? "nil")")
    }

    // MARK: 86 留下的几条（槽模型下不变）

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
        // W5-H 起没有声音的输入静音灰着（D7）：加一路带音频的合成源来点
        session.send(.addInput(config: AppTest.syntheticConfig(number: 3, audio: true)))
        XCTAssertTrue(AppTest.waitUntil(5) { wc.inputStrip.cells[3]?.muteButton.isEnabled == true })
        let cell = try XCTUnwrap(wc.inputStrip.cells[3])
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

    // MARK: X12 残口：设置窗在前时按键也走快捷键表

    /// 设置窗（偏好 / 输出 / 快捷键 / MIDI 合成的那一扇）在前时，没被文本框吃掉的按键交给快捷键表（空格 = Cut）；快捷键页录键中按空格 = 录进去、不切。
    func testUI_settingsWindowForwardsHotkeys() throws {
        let session = try prepare()
        let controller = AppTest.controller
        let panels = controller.panels
        defer { panels.closeAll() }
        try controller.applyHotkeyTable(.default)
        panels.showSettings(page: .general)
        let window = try XCTUnwrap(panels.settingsWindow(showing: .general), "设置窗停在常规页")
        let handled = session.control.hotkeys.counters.handled
        AppTest.press(" ", in: window)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 }, "设置窗在前按空格 = Cut")
        XCTAssertEqual(session.control.hotkeys.counters.handled, handled + 1, "走的是快捷键表")
        // 快捷键页录键中：空格录进那一行，不切
        let hotkeys = panels.showHotkeyEditor()
        let row = try XCTUnwrap(hotkeys.model.rows.first)
        hotkeys.model.beginRecording(row.id)
        let hotkeyWindow = try XCTUnwrap(hotkeys.window)
        AppTest.press(" ", in: hotkeyWindow)
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(session.state.program, 2, "录键时不切")
        XCTAssertNil(hotkeys.model.recordingRow, "录完了")
        XCTAssertEqual(hotkeys.model.rows.first { $0.id == row.id }?.keyText, "space", "空格录进了那一行")
        XCTAssertEqual(session.control.hotkeys.counters.handled, handled + 1, "录键那一下没进快捷键表")
        hotkeys.model.resetToDefault()
        XCTAssertTrue(hotkeys.model.save())
    }
}
