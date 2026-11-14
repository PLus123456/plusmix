// W5-H（prompt 94）输入条与格子：格子两行按钮（转场 / Cut 守"转场进行中"、循环只改结束动作不重建）、分类筛选、拖文件直接加一路、
// 空节目的"＋ 添加输入"占位格、图片文件改了自动换上；另：格子右键菜单补齐（D8）、缩略图小 / 中 / 大三档（D11）、添加面板图片多选（G14）、
// 缩略图框按裁切后的比例（V-23）、输入条右端调音台开关与 ⌘F（D2 / D3）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherInputs
@testable import Switcher

@MainActor
final class InputStripTests: XCTestCase {
    private var wc: MainWindowController { AppTest.controller.windowController }
    private var strip: InputStripView { wc.inputStrip }

    // MARK: 1. 格子两行按钮 + 转场进行中置灰（D4 / D6 / D7 / Q26 / Q39，90 报告 §5 第 1 条）

    func testUI_inputCellButtonsRespectTransitionGuard() throws {
        let session = try AppTest.freshSession()
        defer { AppTest.dismissConfirmations() }
        try AppTest.addSynthetics(session, count: 3)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        session.send(.setTransition(type: .fade, durationTicks: 120))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 && session.state.preview == 2 && session.state.transition.durationTicks == 120 })
        AppTest.pump(seconds: 0.1)
        let cells = try (1...3).map { try XCTUnwrap(strip.cells[$0]) }

        // 两行常显（Q26 (a)）：第一行 × ｜ 转场 ｜ Cut ｜ ⏮ ｜ ▶/⏸ ｜ 🔁（W5-N 起后三颗是图标、只对文件输入亮）；第二行 1–4 ｜ 静音 ｜ ⚙；
        // 都在格子里、同一行同一高度、第一行在上
        for cell in cells {
            XCTAssertEqual(cell.firstRowButtons.map(\.title), ["×", "转场", "Cut", "", "", ""])
            XCTAssertEqual(cell.playbackButtons.map { $0.accessibilityLabel() ?? "" },
                           ["输入 \(cell.number) 回到开头", "输入 \(cell.number) 暂停", "输入 \(cell.number) 循环"])
            XCTAssertEqual(cell.secondRowButtons.map(\.title), ["1", "2", "3", "4", "静音", ""])
            XCTAssertTrue(cell.secondRowButtons.last === cell.gearButton)
            XCTAssertEqual(cell.gearButton.accessibilityLabel(), "输入 \(cell.number) 的设置")
            XCTAssertEqual(cell.gearButton.toolTip, "输入设置（也可右键）")
            XCTAssertEqual(cell.removeButton.accessibilityLabel(), "删除输入 \(cell.number)")
            let row1 = cell.firstRowButtons.map { AppTest.alignmentFrame($0, in: cell) }
            let row2 = cell.secondRowButtons.map { AppTest.alignmentFrame($0, in: cell) }
            guard !row1.isEmpty, !row2.isEmpty else { XCTFail("格子 \(cell.number) 没有两行按钮"); continue }
            for f in row1 + row2 { XCTAssertTrue(cell.bounds.insetBy(dx: -0.5, dy: -0.5).contains(f), "按钮 \(f) 出了格子 \(cell.bounds)") }
            for f in row1 { XCTAssertEqual(f.midY, row1[0].midY, accuracy: 0.5) }
            for f in row2 { XCTAssertEqual(f.midY, row2[0].midY, accuracy: 0.5) }
            for (a, b) in zip(row1, row1.dropFirst()) { XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "第一行从左到右不重叠") }
            for (a, b) in zip(row2, row2.dropFirst()) { XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "第二行从左到右不重叠") }
            XCTAssertTrue(cell.isFlipped ? row1[0].maxY <= row2[0].minY : row1[0].minY >= row2[0].maxY, "第一行在第二行上面")
            for b in cell.firstRowButtons + cell.secondRowButtons { XCTAssertTrue(b.refusesFirstResponder, "\(b.title) 不抢焦点（空格仍是 Cut）") }
        }
        // PGM 上那一路：转场 / Cut 没意义，灰着并说明；其余两路可点，提示写当前转场（Q39；W5-M 起 = 当前槽，这里 Fade 2 秒不在任何槽里，只写效果与时长）
        XCTAssertFalse(cells[0].transitionButton.isEnabled)
        XCTAssertFalse(cells[0].cutButton.isEnabled)
        XCTAssertEqual(cells[0].transitionButton.toolTip, "已经在 PGM 上")
        XCTAssertTrue(cells[1].transitionButton.isEnabled && cells[1].cutButton.isEnabled)
        XCTAssertEqual(cells[2].transitionButton.toolTip, "按当前转场送上 PGM（Fade 2 秒）")
        XCTAssertEqual(cells[2].cutButton.toolTip, "直切到 PGM（不经过 PVW）")

        // 3 号点"转场" = setPreview(3) + autoTransition（按当前类型 / 时长），两条都来源 ui、按顺序
        let bus = session.control.bus
        var mark = bus.lastSequence
        cells[2].transitionButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive && session.state.preview == 3 }, "转场应开始、PVW = 3：\(session.state.transition)")
        AppTest.pump(seconds: 0.1)
        let sent = bus.recentEntries().filter { $0.sequence > mark }
        XCTAssertEqual(sent.map(\.command), [.setPreview(input: 3), .autoTransition])
        XCTAssertEqual(Set(sent.map(\.source)), [.ui])

        // 转场进行中：所有格子的"转场 / Cut"置灰、提示写原因；点了（含绕过置灰直接发动作）也不发命令；Shift 点缩略图也不发、状态行说一句
        XCTAssertTrue(AppTest.waitUntil(1) { cells.allSatisfy { !$0.transitionButton.isEnabled && !$0.cutButton.isEnabled } }, "转场进行中两颗按钮应全灰")
        XCTAssertEqual(cells[1].cutButton.toolTip, "转场进行中：等这次转场做完再切")
        let commandsBefore = session.commandsSent
        mark = bus.lastSequence
        for cell in cells {
            cell.transitionButton.performClick(nil)
            cell.cutButton.performClick(nil)
            NSApp.sendAction(cell.transitionButton.action!, to: cell.transitionButton.target, from: cell.transitionButton)
            NSApp.sendAction(cell.cutButton.action!, to: cell.cutButton.target, from: cell.cutButton)
        }
        click(cells[1], shift: true)
        click(cells[1], shift: false)
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(session.commandsSent, commandsBefore, "转场进行中格子上的转场 / Cut / 点缩略图都不发命令")
        XCTAssertEqual(bus.recentEntries().filter { $0.sequence > mark && $0.source == .ui }.map(\.command), [])
        XCTAssertEqual(wc.bottomBar.displayedNotice, "转场进行中：等这次转场做完再改 PVW / PGM")
        // 右键菜单里同样的三项也灰着
        let menu = cells[1].contextMenu()
        for title in ["送到 PVW", "Cut 到 PGM", "按当前转场送上 PGM（Fade 2 秒）"] {
            XCTAssertEqual(menu.items.first { $0.title == title }?.isEnabled, false, "转场进行中右键“\(title)”应灰")
        }

        // 做完：PGM = 3、PVW = 原来的 PGM 1；按钮回来（3 号在 PGM 上那两颗仍灰）；1 号"Cut" = setProgram(1)，直切、不动 PVW
        XCTAssertTrue(AppTest.waitUntil(4) { !session.state.transition.isActive && session.state.program == 3 && session.state.preview == 1 })
        XCTAssertTrue(AppTest.waitUntil(1) { cells[0].cutButton.isEnabled && cells[1].transitionButton.isEnabled && !cells[2].cutButton.isEnabled })
        XCTAssertEqual(cells[2].cutButton.toolTip, "已经在 PGM 上")
        mark = bus.lastSequence
        cells[1].cutButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 })
        XCTAssertEqual(bus.recentEntries().filter { $0.sequence > mark }.map(\.command), [.setProgram(input: 2)])
        XCTAssertEqual(session.state.preview, 1, "Cut 不经过 PVW")
        // ×（Q06 (a)，条件确认沿用 87）：哪儿都没用的 3 号直接删、不问；PVW 上的 1 号先问
        cells[2].removeButton.performClick(nil)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "不在 PGM / PVW / 叠加上的直接删")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(3) == nil })
        cells[0].removeButton.performClick(nil)
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.removeInput), "PVW 上的那一路先确认")
        XCTAssertTrue(ask.request.message.contains("PVW"), ask.request.message)
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.2)
        XCTAssertNotNil(session.state.input(1))
    }

    // MARK: 2. 循环只改结束动作，不重建这一路（D5 的循环部分）

    func testUI_inputCellLoopToggleDoesNotRebuildInput() throws {
        let fixture = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("没有 Tests/Fixtures/pattern.mov") }
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "pattern", source: .file(path: fixture.path, endAction: .loop, rate: 1))))
        session.send(.addInput(config: AppTest.syntheticConfig(number: 2)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live, "文件输入应 live")
        let cell1 = try XCTUnwrap(strip.cells[1]), cell2 = try XCTUnwrap(strip.cells[2])
        // 只对文件输入亮：合成源的"循环"灰着并说明
        XCTAssertTrue(cell1.loopButton.isEnabled)
        XCTAssertEqual(cell1.loopButton.bezelColor, Theme.accent, "循环开着 = 高亮")
        XCTAssertFalse(cell2.loopButton.isEnabled)
        XCTAssertEqual(cell2.loopButton.toolTip, "只对视频 / 音频文件输入")
        let entry = try XCTUnwrap(session.inputs.entries[1])
        let file = try XCTUnwrap(entry.input as? FileInput)
        let identity = ObjectIdentifier(file), slot = ObjectIdentifier(entry.slot)
        var f1: UInt32?
        XCTAssertTrue(AppTest.waitUntil(5) { f1 = AppTest.readback(session)?.decodePattern().frameNumber; return f1 != nil }, "PGM 上应解出帧号")
        let position1 = file.positionSeconds

        cell1.loopButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) {
            if case .file(_, .holdLastFrame, _)? = session.state.input(1)?.source { return true } else { return false }
        }, "关循环 = setInputSource 只把结束动作改成停在最后一帧：\(String(describing: session.state.input(1)?.source))")
        AppTest.pump(seconds: 0.5)
        let after = try XCTUnwrap(session.inputs.entries[1])
        XCTAssertEqual(ObjectIdentifier(after.input as AnyObject), identity, "同一路的输入对象不换")
        XCTAssertEqual(ObjectIdentifier(after.slot), slot, "帧槽不换（引擎没注销 / 重注册）")
        XCTAssertEqual(file.endAction, .holdLastFrame, "结束动作改到运行中的那个对象上")
        if case .file(let path, _, let rate) = after.config.source { XCTAssertEqual(path, fixture.path); XCTAssertEqual(rate, 1) } else { XCTFail("\(after.config.source)") }
        XCTAssertNil(cell1.loopButton.bezelColor, "循环关着 = 不高亮")
        let f2 = try XCTUnwrap(AppTest.readback(session)?.decodePattern().frameNumber)
        let delta = Int(f2) - Int(f1!)
        print("循环开关：帧号 \(f1!) → \(f2)（Δ \(delta)），位置 \(position1) → \(file.positionSeconds) s")
        XCTAssertTrue((20...120).contains(delta), "帧号应接着走（没从头播）：\(f1!) → \(f2)")
        XCTAssertGreaterThan(file.positionSeconds, position1, "播放位置接着走")

        cell1.loopButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { file.endAction == .loop && cell1.loopButton.bezelColor == Theme.accent })
        XCTAssertEqual(ObjectIdentifier(session.inputs.entries[1]!.input as AnyObject), identity, "再开回来也不重建")
        // 换文件（路径变了）照旧重建：规则只放过"只有结束动作变了"
        session.send(.setInputSource(input: 1, source: .file(path: fixture.path + "-missing.mov", endAction: .loop, rate: 1)))
        XCTAssertTrue(AppTest.waitUntil(3) { session.inputs.entries[1].map { ObjectIdentifier($0.input as AnyObject) != identity } ?? false }, "路径变了要重建")
    }

    // MARK: 3. 分类标签：点 = 只显示这一类，与搜索叠加；右键改名；颜色在 InputConfig.color（W5-O 起，提案 023 四）、名字在 Show.layout（D1 / Q14）

    func testUI_categoryFilterHidesOtherInputs() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 4)
        AppTest.pump(seconds: 0.1)
        // 输入条左端：全部 + 六色（Finder 标签同一套），默认选"全部"
        XCTAssertEqual(strip.categoryBar.tagButtons.map { $0.accessibilityLabel() ?? "" }, ["全部", "红色", "橙色", "黄色", "绿色", "蓝色", "紫色"])
        XCTAssertEqual(strip.selectedCategory, nil)
        // 格子右键"分类 ▸"：无 + 六色；选了打勾、格子标题条上有色点
        func pick(_ number: Int, _ title: String) throws {
            let cell = try XCTUnwrap(strip.cells[number])
            let submenu = try XCTUnwrap(cell.contextMenu().items.first { $0.title == "分类" }?.submenu)
            XCTAssertEqual(submenu.items.map(\.title), ["无", "红色", "橙色", "黄色", "绿色", "蓝色", "紫色"])
            let item = try XCTUnwrap(submenu.items.first { $0.title == title })
            _ = item.target?.perform(item.action, with: item)
        }
        try pick(1, "红色")
        try pick(3, "红色")
        try pick(2, "蓝色")
        XCTAssertEqual(strip.cells[1]?.categoryColor, .red)
        XCTAssertEqual(strip.cells[2]?.categoryColor, .blue)
        XCTAssertNil(strip.cells[4]?.categoryColor)
        XCTAssertEqual(try XCTUnwrap(strip.cells[1]).contextMenu().items.first { $0.title == "分类" }?.submenu?.items.first { $0.state == .on }?.title, "红色")
        // 颜色存在各路 InputConfig.color（setInputColor；原来存 Show.layout 的 "inputCategories"，W5-O 切过来）
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.inputs.map(\.color) == [.red, .blue, .red, nil] }, "\(session.state.inputs.map(\.color))")
        XCTAssertTrue(AppTest.waitUntil(2) { AppTest.controller.isDocumentEdited }, "改分类算未保存的改动（它是节目内容）")

        // 点红色 = 只剩红的；和搜索叠加；点蓝色换类；点"全部"回来；再点一次已选的那一类也回到全部
        strip.categoryBar.button(for: .red).performClick(nil)
        XCTAssertEqual(strip.selectedCategory, .red)
        XCTAssertEqual(strip.visibleNumbers, [1, 3])
        strip.searchField.stringValue = "3"
        strip.searchField.performClick(nil)
        XCTAssertEqual(strip.visibleNumbers, [3], "分类与搜索叠加")
        strip.searchField.stringValue = ""
        strip.searchField.performClick(nil)
        XCTAssertEqual(strip.visibleNumbers, [1, 3])
        strip.categoryBar.button(for: .blue).performClick(nil)
        XCTAssertEqual(strip.visibleNumbers, [2])
        strip.categoryBar.button(for: nil).performClick(nil)
        XCTAssertEqual(strip.visibleNumbers, [1, 2, 3, 4])
        strip.categoryBar.button(for: .red).performClick(nil)
        strip.categoryBar.button(for: .red).performClick(nil)
        XCTAssertEqual(strip.selectedCategory, nil, "再点一次已选的 = 回到全部")
        XCTAssertEqual(strip.visibleNumbers, [1, 2, 3, 4])

        // 右键标签改名：标签上写名字，"分类 ▸"里也写名字；存 "inputCategoryNames" = { 颜色: 名字 }
        let tagMenu = try XCTUnwrap(strip.categoryBar.menu(for: .red))
        XCTAssertEqual(tagMenu.items.map(\.title), ["改名…"])
        wc.renameCategory(.red, to: "机位")
        XCTAssertEqual(strip.categoryBar.button(for: .red).title, "机位")
        XCTAssertEqual(strip.categoryBar.button(for: .red).accessibilityLabel(), "红色 · 机位")
        XCTAssertEqual(session.layout.values[InputCategories.Keys.names], .object(["red": .string("机位")]))
        XCTAssertEqual(try XCTUnwrap(strip.cells[2]).contextMenu().items.first { $0.title == "分类" }?.submenu?.items.map(\.title),
                       ["无", "机位", "橙色", "黄色", "绿色", "蓝色", "紫色"])
        XCTAssertEqual(try XCTUnwrap(strip.categoryBar.menu(for: .red)).items.map(\.title), ["改名…", "清除名字"])

        // 存盘 → 重新打开：分类和名字都回来
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/分类-\(UUID().uuidString).switcher.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(AppTest.controller.write(session.makeShow(), to: url))
        let done = AppTest.expectationBox()
        Task { await AppTest.controller.openShow(url: url); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(15) { done.value && AppTest.controller.session?.isRunning == true && AppTest.controller.session !== session })
        let reopened = try XCTUnwrap(AppTest.controller.session)
        XCTAssertTrue(AppTest.waitUntil(5) { (1...4).allSatisfy { reopened.inputs.runtimeState(of: $0) == .live } })
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(strip.cells[1]?.categoryColor, .red)
        XCTAssertEqual(strip.cells[3]?.categoryColor, .red)
        XCTAssertEqual(strip.categoryBar.button(for: .red).title, "机位")
        strip.categoryBar.button(for: .red).performClick(nil)
        XCTAssertEqual(strip.visibleNumbers, [1, 3])
        // 删掉一路：它的分类跟着清（编号以后被别的输入用上时不继承）
        reopened.send(.removeInput(input: 3))
        XCTAssertTrue(AppTest.waitUntil(2) { reopened.state.input(3) == nil })
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(reopened.state.inputs.map(\.color), [.red, .blue, nil], "删掉的那一路颜色跟着它的配置没了")
        XCTAssertEqual(strip.visibleNumbers, [1])
        strip.categoryBar.button(for: nil).performClick(nil)
    }

    // MARK: 4. 视频 / 图片文件拖到输入条：编号取空号、名字用文件名、不弹面板（G13）

    func testUI_dropVideoFileAddsInputWithFreeNumber() throws {
        let fixture = try AppTest.repoRoot().appendingPathComponent("Tests/Fixtures/pattern.mov")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("没有 Tests/Fixtures/pattern.mov") }
        let session = try AppTest.freshSession()
        for n in [1, 2, 4] { session.send(.addInput(config: AppTest.syntheticConfig(number: n))) }
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.map(\.number) == [1, 2, 4] })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("台标.png")
        try InputWiringTests.writeSolidPNG(to: png, width: 320, height: 180, red: 10, green: 200, blue: 30)
        let text = dir.appendingPathComponent("说明.txt")
        try Data("不是视频".utf8).write(to: text)

        // 只有不认识的文件：不接（光标不变成"+"）
        let rejected = DropInfo(urls: [text], window: wc.window)
        XCTAssertEqual(strip.draggingEntered(rejected), [], "文本文件不接")
        // 视频 + 图片 + 文本：接（copy），放下 = 视频进 3 号、图片进 5 号（空号依次取），文本跳过、状态行说一句；不弹添加面板
        let drop = DropInfo(urls: [fixture, png, text], window: wc.window)
        XCTAssertEqual(strip.draggingEntered(drop), .copy)
        XCTAssertTrue(strip.isDropTargetHighlighted, "拖进来时输入条高亮")
        XCTAssertTrue(strip.performDragOperation(drop))
        strip.draggingEnded(drop)
        XCTAssertFalse(strip.isDropTargetHighlighted)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.inputs.map(\.number) == [1, 2, 3, 4, 5] }, "\(session.state.inputs.map(\.number))")
        XCTAssertEqual(session.state.input(3)?.name, "pattern.mov")
        XCTAssertEqual(session.state.input(3)?.source, .file(path: fixture.path, endAction: .loop, rate: 1))
        XCTAssertEqual(session.state.input(5)?.name, "台标.png")
        XCTAssertEqual(session.state.input(5)?.source, .image(path: png.path))
        XCTAssertNil(wc.window?.attachedSheet, "拖放不弹添加面板")
        XCTAssertEqual(wc.bottomBar.displayedNotice, "跳过 1 个不是视频 / 图片的文件：说明.txt")
        XCTAssertEqual(AppTest.waitLive(session, input: 3, timeout: 5), .live)
        XCTAssertEqual(AppTest.waitLive(session, input: 5, timeout: 5), .live)
        XCTAssertEqual(AppTest.controller.addInputHistory.recentSources.first, .image(path: png.path), "拖进来的也记进最近添加")

        // 拖到占位格上同一回事（占位格自己也接拖放）
        let again = DropInfo(urls: [png], window: wc.window)
        XCTAssertEqual(strip.addPlaceholder.draggingEntered(again), .copy)
        XCTAssertTrue(strip.addPlaceholder.performDragOperation(again))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(6)?.source == .image(path: png.path) })
    }

    // MARK: 5. 空节目：输入条只有一格虚线"＋ 添加输入"，下面一行小字（D10 / V-09）

    func testUI_emptyShowShowsAddPlaceholder() throws {
        let session = try AppTest.freshSession()
        AppTest.pump(seconds: 0.1)
        XCTAssertTrue(strip.cells.isEmpty)
        let placeholder = strip.addPlaceholder
        XCTAssertEqual(strip.arrangedItems.map { $0 === placeholder }, [true], "空节目时占位格是唯一一格")
        XCTAssertFalse(placeholder.isHidden)
        XCTAssertEqual(placeholder.titleText, "＋ 添加输入")
        XCTAssertEqual(placeholder.hintText, "也可以把视频 / 图片文件拖到这里")
        XCTAssertFalse(placeholder.isHintHidden)
        XCTAssertEqual(placeholder.toolTip, "添加输入（⌘I）")
        XCTAssertEqual(placeholder.accessibilityLabel(), "添加输入")
        XCTAssertTrue(placeholder.hasDashedBorder)
        let frame = AppTest.alignmentFrame(placeholder, in: strip)
        XCTAssertTrue(strip.bounds.contains(frame), "占位格在输入条里看得见：\(frame) / \(strip.bounds)")
        XCTAssertEqual(placeholder.frame.width, Theme.thumbnailWidth(for: .medium), accuracy: 0.5, "和格子一样宽")
        // 点 = 开添加面板（和底栏"添加输入"主体同一个入口：停在上次的类型）
        placeholder.performClick()
        let sheet = try XCTUnwrap(AppTest.waitUntil(2) { self.wc.window?.attachedSheet != nil } ? wc.window?.attachedSheet?.windowController as? AddInputSheetController : nil,
                                  "点占位格应弹添加面板")
        sheet.cancelForTesting()
        XCTAssertTrue(AppTest.waitUntil(2) { self.wc.window?.attachedSheet == nil })
        // 有输入之后：占位格排在最后，小字收起
        try AppTest.addSynthetics(session, count: 2)
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(strip.arrangedItems.count, 3)
        XCTAssertTrue(strip.arrangedItems.last === placeholder, "占位格在最后")
        XCTAssertTrue(placeholder.isHintHidden, "有输入时不再写拖放的小字")
        // 分类筛选 / 搜索把格子全筛掉了：占位格仍在（加输入不受筛选影响）
        strip.searchField.stringValue = "不存在的名字"
        strip.searchField.performClick(nil)
        XCTAssertEqual(strip.visibleNumbers, [])
        XCTAssertFalse(placeholder.isHidden)
        strip.searchField.stringValue = ""
        strip.searchField.performClick(nil)
    }

    // MARK: 6. 图片文件在外面被改了：下一拍换上，这一路不重建（G14）

    func testUI_imageInputReloadsWhenFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("字幕.png")
        try InputWiringTests.writeSolidPNG(to: png, width: 1280, height: 720, red: 200, green: 30, blue: 30)
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 1, name: "字幕", source: .image(path: png.path))))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        func centerIs(_ r: Int, _ g: Int, _ b: Int) -> Bool {
            guard let rb = AppTest.readback(session) else { return false }
            let p = rb.pixel(x: rb.width / 2, y: rb.height / 2)
            return abs(p.r - r) <= 12 && abs(p.g - g) <= 12 && abs(p.b - b) <= 12
        }
        XCTAssertTrue(AppTest.waitUntil(5) { centerIs(200, 30, 30) }, "先是红的")
        let entry = try XCTUnwrap(session.inputs.entries[1])
        let identity = ObjectIdentifier(entry.input as AnyObject), slot = ObjectIdentifier(entry.slot)

        // ① 编辑器常见的"写临时文件再改名盖过去"（原子替换）
        let staging = dir.appendingPathComponent("字幕.tmp.png")
        try InputWiringTests.writeSolidPNG(to: staging, width: 1280, height: 720, red: 20, green: 40, blue: 220)
        var started = Date()
        _ = try FileManager.default.replaceItemAt(png, withItemAt: staging)
        XCTAssertTrue(AppTest.waitUntil(2) { centerIs(20, 40, 220) }, "原子替换后应换上蓝的")
        print("图片改了自动换上：原子替换 \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        // ② 原地覆盖写（截断再写）
        let greenFile = dir.appendingPathComponent("green.png")
        try InputWiringTests.writeSolidPNG(to: greenFile, width: 1280, height: 720, red: 30, green: 190, blue: 40)
        let bytes = try Data(contentsOf: greenFile)
        started = Date()
        let handle = try FileHandle(forWritingTo: png)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: bytes)
        try handle.close()
        XCTAssertTrue(AppTest.waitUntil(2) { centerIs(30, 190, 40) }, "原地覆盖后应换上绿的")
        print("图片改了自动换上：原地覆盖 \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // 同一路、同一个输入对象、同一个帧槽（没有注销 / 重注册，PGM 不闪黑）；快照里的来源没变
        let after = try XCTUnwrap(session.inputs.entries[1])
        XCTAssertEqual(ObjectIdentifier(after.input as AnyObject), identity, "路径不变：同一个输入对象重新读文件，不重建")
        XCTAssertEqual(ObjectIdentifier(after.slot), slot)
        XCTAssertEqual(session.state.input(1)?.source, .image(path: png.path))
        XCTAssertEqual(session.inputs.runtimeState(of: 1), .live)
        // 删掉这一路：不再监视（再改文件不会碰已经不在的输入）
        session.send(.removeInput(input: 1))
        XCTAssertTrue(AppTest.waitUntil(2) { session.inputs.entries[1] == nil })
        XCTAssertEqual(session.inputs.watchedImagePaths, [], "删掉的那一路不再监视")
    }

    // MARK: 补 D8：格子右键菜单补齐

    func testUI_inputCellContextMenuComplete() throws {
        let session = try AppTest.freshSession()
        defer { AppTest.dismissConfirmations(); AppTest.controller.panels.closeAll() }
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 && session.state.preview == 2 })
        AppTest.pump(seconds: 0.1)
        let cell = try XCTUnwrap(strip.cells[2])
        let menu = cell.contextMenu()
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "─" : $0.title },
                       ["送到 PVW", "Cut 到 PGM", "按当前转场送上 PGM（转场 1 · Fade 0.5 秒）", "Overlay", "分类", "静音", "─",
                        "设置…", "换来源…", "重命名…", "─", "删除输入 2"])
        XCTAssertEqual(menu.items.first { $0.title == "换来源…" }?.toolTip, "直接打开输入设置的“来源”一节；换来源会重建这一路（文件从头播）")
        XCTAssertEqual(menu.items.first { $0.title == "静音" }?.isEnabled, false, "无声合成源：静音灰")
        XCTAssertEqual(menu.items.first { $0.title == "静音" }?.toolTip, "这一路没有声音（合成源没开音频）")
        XCTAssertEqual(cell.muteButton.isEnabled, false)
        XCTAssertEqual(cell.muteButton.toolTip, "这一路没有声音（合成源没开音频）")
        let overlay = try XCTUnwrap(menu.items.first { $0.title == "Overlay" }?.submenu)
        XCTAssertEqual(overlay.items.map(\.title), ["Overlay 1", "Overlay 2", "Overlay 3", "Overlay 4"])
        func fire(_ item: NSMenuItem?) throws {
            let item = try XCTUnwrap(item)
            XCTAssertTrue(item.isEnabled, item.title)
            _ = item.target?.perform(item.action, with: item)
        }
        // Overlay 2 ▸：同格子上的 2 号小按钮（这一路开在通道 2 上，再点关）
        try fire(overlay.items[1])
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[1].on && session.state.overlays[1].input == 2 })
        XCTAssertEqual(cell.contextMenu().items.first { $0.title == "Overlay" }?.submenu?.items[1].state, .on)
        try fire(cell.contextMenu().items.first { $0.title == "Overlay" }?.submenu?.items[1])
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.overlays[1].on })
        // 送到 PVW / Cut 到 PGM / 按当前转场送上 PGM
        let cell1 = try XCTUnwrap(strip.cells[1])
        XCTAssertEqual(cell1.contextMenu().items.first { $0.title == "Cut 到 PGM" }?.isEnabled, false, "已在 PGM 上")
        try fire(cell1.contextMenu().items.first { $0.title == "送到 PVW" })
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 1 })
        try fire(cell.contextMenu().items.first { $0.title == "Cut 到 PGM" })
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 })
        session.send(.setTransition(type: .cut, durationTicks: 30))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .cut })
        AppTest.pump(seconds: 0.05)
        let quick = cell1.contextMenu().items.first { $0.title.hasPrefix("按当前转场送上 PGM") }
        XCTAssertEqual(quick?.title, "按当前转场送上 PGM（Cut）", "当前那组是 API 给的 Cut（不在槽里）：只写 Cut")
        try fire(quick)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 })
        // 换来源… = 输入设置窗、直接停在"来源"一节；设置… = 同一扇窗
        try fire(cell.contextMenu().items.first { $0.title == "换来源…" })
        let window = try XCTUnwrap(AppTest.controller.panels.showInputSettings(input: 2))
        XCTAssertEqual(window.model.section, .source)
        // 删除…：前面有分隔线、在最后
        let items = cell.contextMenu().items
        XCTAssertTrue(items[items.count - 2].isSeparatorItem)
        XCTAssertEqual(items.last?.title, "删除输入 2")
    }

    // MARK: 补 D11：缩略图小 / 中 / 大三档，存本机；输入条最小高跟着变

    /// W6-A 改口径（prompt 144 交付 6 / 10）：加了第四档"紧凑"（竖的小格，宽 72、只有标题条 + 缩略图，按钮进右键菜单），菜单四项；
    /// 新排布里输入条 = 下边一行（按规则算），"换回中档贴回格子的高 197"改成"等于规则算出来的下边一行高"。
    func testUI_thumbnailSizeThreeStepsPersist() throws {
        let session = try AppTest.freshSession()
        defer { wc.setThumbnailSize(.medium); AppTest.setMainWindowSize(NSSize(width: 1440, height: 900)) }
        try AppTest.addSynthetics(session, count: 2)
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        let menu = strip.thumbnailSizeMenu()
        XCTAssertEqual(menu.items.map(\.title), ["小", "中", "大", "紧凑"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .on, .off, .off], "默认中")
        var widths: [CGFloat] = [], minimums: [CGFloat] = []
        for (i, size) in [ThumbnailSize.small, .medium, .large, .compact].enumerated() {
            let item = strip.thumbnailSizeMenu().items[i]
            _ = item.target?.perform(item.action, with: item)
            AppTest.pump(seconds: 0.1)
            XCTAssertEqual(AppTest.controller.stripPreferences.thumbnailSize, size, "存本机")
            XCTAssertEqual(AppTest.controller.defaults.string(forKey: InputStripPreferences.Keys.thumbnailSize), size.rawValue)
            let cell = try XCTUnwrap(strip.cells[1])
            XCTAssertEqual(cell.frame.width, Theme.thumbnailWidth(for: size), accuracy: 0.5)
            XCTAssertEqual(strip.addPlaceholder.frame.width, cell.frame.width, accuracy: 0.5, "占位格跟格子一样大")
            XCTAssertGreaterThanOrEqual(strip.frame.height, strip.minimumHeight - 0.5, "输入条不低于新的最小高")
            if size == .compact {
                // 紧凑：横屏也能选；小格上不常显按钮，缩略图和监看同一个形状
                XCTAssertTrue(cell.isCompact)
                XCTAssertEqual(cell.display.frame.height, cell.display.frame.width * CGFloat(session.format.height) / CGFloat(session.format.width), accuracy: 1)
                let title = strip.convert(cell.bounds, from: cell)
                XCTAssertTrue(strip.visibleRect.contains(title), "紧凑：格子 \(title) 在输入条 \(strip.visibleRect) 里")
                continue
            }
            widths.append(cell.frame.width)
            minimums.append(strip.minimumHeight)
            // 格子最下一行按钮在输入条的可见区里
            let gear = strip.convert(cell.gearButton.bounds, from: cell.gearButton)
            XCTAssertTrue(strip.visibleRect.contains(gear), "\(size)：齿轮 \(gear) 在输入条 \(strip.visibleRect) 里")
        }
        print("缩略图三档：宽 \(widths)，输入条最小高 \(minimums)")
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(minimums, minimums.sorted())
        wc.setThumbnailSize(.large)
        AppTest.pump(seconds: 0.1)
        // 大档：缩到最小窗口时输入条照样放得下，上半区仍放得下转场列（当前这一档）
        AppTest.setMainWindowSize(AppTest.minimumMainWindowSize)
        XCTAssertGreaterThanOrEqual(strip.frame.height, strip.minimumHeight - 0.5, "大档在最小窗口：输入条 \(strip.frame.height) ≥ \(strip.minimumHeight)")
        XCTAssertGreaterThanOrEqual(wc.transitionPanel.frame.height, wc.transitionPanel.fittingSize.height - 1)
        // 大档换回中档：输入条 = 规则算出来的下边一行（原来是贴回格子的高 197），最小窗口还是 W5-G 定的内容区 668
        wc.setThumbnailSize(.medium)
        AppTest.pump(seconds: 0.1)
        let ref = RefLayout.layout(AppTest.minimumMainWindowSize.width, AppTest.minimumMainWindowSize.height, mixer: true, 1920, 1080, AppTest.measuredK())
        XCTAssertEqual(strip.frame.height, ref.rowH, accuracy: 1, "换回中档：输入条 = 下边一行")
        XCTAssertEqual(wc.window?.contentMinSize.height ?? 0, MainWindowController.minimumContentSize.height, accuracy: 0.5)
        wc.setThumbnailSize(.large)
        // 菜单栏兜底：窗口 › 输入缩略图 ▸ 同一份
        let windowMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.title == "窗口" }?.submenu)
        let sizes = try XCTUnwrap(windowMenu.items.first { $0.title == "输入缩略图" }?.submenu)
        AppTest.delegate.menuNeedsUpdate(sizes)
        XCTAssertEqual(sizes.items.map(\.title), ["小", "中", "大", "紧凑"])
        XCTAssertEqual(sizes.items.map(\.state), [.off, .off, .on, .off])
    }

    /// 输入条被拖高之后把窗口缩到最小：输入条先退回最小高，上半区仍放得下转场列（原来差额全给上半区，转场列会被压扁）。
    /// W6-A 改口径：新排布里拖的是上下之间的分隔条（自绘，MainLayoutView.topDivider），缩到最小窗口时上半区放得下当前这一档、输入条不低于一行格子；
    /// 原来的 NSSplitView 拖法在旧排布下照过（下半段）。
    func testUI_stripGivesBackHeightWhenWindowShrinks() throws {
        let session = try AppTest.freshSession()
        defer { AppTest.setMainWindowSize(NSSize(width: 1440, height: 900)); wc.setThumbnailSize(.medium); wc.setArrangement(.adaptive) }
        try AppTest.addSynthetics(session, count: 2)
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        let before = strip.frame.height   // 新排布 1440×900 配 16:9：下边一行按规则 397
        AppTest.drag(wc.layoutView.topDivider, by: NSPoint(x: 0, y: 100))
        XCTAssertEqual(strip.frame.height, before + 100, accuracy: 1, "新排布：往上拖 100，输入条拖高到 \(before + 100)")
        AppTest.setMainWindowSize(AppTest.minimumMainWindowSize)
        print("新排布 拖高后缩到最小窗口：输入条 \(strip.frame.height)（最小 \(strip.minimumHeight)），上半区 \(wc.transitionPanel.frame.height)（\(wc.transitionPanel.tier.title)）")
        XCTAssertGreaterThanOrEqual(wc.transitionPanel.frame.height, wc.transitionPanel.fittingSize.height - 0.5, "新排布：上半区放得下转场列（当前这一档）")
        XCTAssertGreaterThanOrEqual(strip.frame.height, strip.minimumHeight - 0.5, "新排布：输入条不低于最小高")
        AppTest.drag(wc.layoutView.topDivider, by: NSPoint(x: 0, y: -3000))   // 拖回到底：按规则排

        // 旧排布：原来的拖法
        wc.setArrangement(.legacy)
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        let split = try XCTUnwrap(strip.superview as? NSSplitView)
        split.setPosition(split.frame.height - 300 - split.dividerThickness, ofDividerAt: 0)
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(strip.frame.height, 300, accuracy: 1, "拖到 300 高")
        AppTest.setMainWindowSize(AppTest.minimumMainWindowSize)
        print("拖高后缩到最小窗口：输入条 \(strip.frame.height)（最小 \(strip.minimumHeight)），上半区 \(wc.transitionPanel.frame.height)")
        XCTAssertGreaterThanOrEqual(wc.transitionPanel.frame.height, wc.transitionPanel.fittingSize.height - 0.5, "上半区放得下转场列")
        XCTAssertGreaterThanOrEqual(strip.frame.height, strip.minimumHeight - 0.5, "输入条不低于最小高")
    }

    // MARK: 补 G14：添加面板的图片页可以多选，每张一路

    func testUI_addImagePanelMultiSelectAddsOnePerFile() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 2)))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.inputs.count == 1 })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["片头.png", "台标.png", "字幕条.png"].map { name -> URL in
            let u = dir.appendingPathComponent(name)
            try InputWiringTests.writeSolidPNG(to: u, width: 64, height: 36, red: 100, green: 100, blue: 100)
            return u
        }
        wc.presentAddInput(kind: .image)
        let sheet = try XCTUnwrap(wc.window?.attachedSheet?.windowController as? AddInputSheetController)
        XCTAssertTrue(AddInputModel.imagePanelAllowsMultipleSelection, "图片页的浏览面板允许多选")
        sheet.form.model.setImagePaths(files.map(\.path))
        XCTAssertEqual(sheet.form.model.imagePath, files[0].path)
        XCTAssertEqual(sheet.form.model.imageSelectionSummary, "已选 3 张：每张加一路，名字用文件名")
        sheet.confirmForTesting()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.inputs.map(\.number) == [1, 2, 3, 4] }, "\(session.state.inputs.map(\.number))")
        XCTAssertEqual([1, 3, 4].map { session.state.input($0)?.name }, ["片头.png", "台标.png", "字幕条.png"])
        XCTAssertEqual([1, 3, 4].map { session.state.input($0)?.source }, files.map { .image(path: $0.path) })
        XCTAssertTrue(L("addInput.image.hint").contains("字幕"), "图片页写一句做字幕 / 台标的用法：\(L("addInput.image.hint"))")
    }

    // MARK: 补 D2 / D3 / V-23：调音台开关、⌘F、缩略图框按裁切后的比例

    func testUI_stripMixerToggleFindShortcutAndCroppedThumbnail() throws {
        let session = try AppTest.freshSession()
        defer { if !wc.isMixerPanelVisible { wc.toggleMixerPanel() } }
        try AppTest.addSynthetics(session, count: 2)
        AppTest.pump(seconds: 0.1)
        // 右端"调音台"：与"窗口 › 调音台"同一个动作（nil target、同一个 selector），开着高亮
        let toggle = strip.mixerToggle
        let windowMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.title == "窗口" }?.submenu)
        let mixerItem = try XCTUnwrap(windowMenu.items.first { $0.title == "调音台" })
        XCTAssertEqual(toggle.title, "调音台")
        XCTAssertEqual(toggle.action, mixerItem.action)
        XCTAssertNil(toggle.target)
        XCTAssertNil(mixerItem.target)
        XCTAssertTrue(toggle.refusesFirstResponder)
        XCTAssertTrue(wc.isMixerPanelVisible)
        XCTAssertEqual(toggle.bezelColor, Theme.accent)
        toggle.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(1) { !self.wc.isMixerPanelVisible })
        XCTAssertNil(toggle.bezelColor, "收起 = 不高亮")
        _ = NSApp.sendAction(mixerItem.action!, to: nil, from: mixerItem)
        XCTAssertTrue(AppTest.waitUntil(1) { self.wc.isMixerPanelVisible && toggle.bezelColor == Theme.accent }, "菜单那一路也同步高亮")
        wc.window?.contentView?.layoutSubtreeIfNeeded()   // 调音台刚拉出来，输入条变窄后再量
        let toggleFrame = AppTest.alignmentFrame(toggle, in: strip)
        XCTAssertEqual(toggleFrame.maxX, strip.bounds.maxX - 8, accuracy: 4, "在输入条右端")

        // ⌘F：输入 › 搜索输入，焦点进搜索框（回车 / Esc 还给窗口，数字键又是快捷键）
        let inputMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.title == "输入" }?.submenu)
        let find = try XCTUnwrap(inputMenu.items.first { $0.keyEquivalent == "f" })
        XCTAssertEqual(find.title, "搜索输入")
        XCTAssertEqual(find.keyEquivalentModifierMask, [.command])
        _ = NSApp.sendAction(find.action!, to: nil, from: find)
        XCTAssertTrue(AppTest.waitUntil(1) {
            let r = self.wc.window?.firstResponder
            return r === self.strip.searchField || (r as? NSTextView)?.delegate === self.strip.searchField
        }, "⌘F 后焦点在搜索框")
        wc.window?.makeFirstResponder(nil)

        // V-23：缩略图框的宽高比 = 裁切后那块的宽高比（上下不再留黑边）
        let cell = try XCTUnwrap(strip.cells[1])
        let rect = cell.display.sourceRect
        let expected = (rect.height * Double(session.format.height)) / (rect.width * Double(session.format.width))
        let actual = Double(cell.display.frame.height / cell.display.frame.width)
        print("缩略图框：\(cell.display.frame.size)，裁切后比例 \(expected)")
        XCTAssertEqual(actual, expected, accuracy: 0.01, "显示框按裁切后的比例")
        XCTAssertLessThan(cell.display.frame.height, Theme.thumbnailWidth(for: .medium) * 9 / 16 - 8, "比 16:9 的框矮（切掉了名字条那块）")
    }

    // MARK: 工具

    /// 合成鼠标点在格子缩略图上（同 UISmokeTests：hitTest 找到最深的视图，把 mouseDown / mouseUp 交给它）。
    private func click(_ view: NSView, shift: Bool) {
        guard let window = view.window else { return }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY + 10), to: nil)
        let flags: NSEvent.ModifierFlags = shift ? [.shift] : []
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: center, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: center, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        guard let target = window.contentView?.hitTest(center) else { XCTFail("点不到视图"); return }
        target.mouseDown(with: down)
        target.mouseUp(with: up)
    }
}

/// 拖放的替身：私有剪贴板里放文件 URL（AppKit 不让合成真的拖动会话，拖放目标只读 NSDraggingInfo 这几样）。
@MainActor
final class DropInfo: NSObject, @preconcurrency NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let window: NSWindow?
    init(urls: [URL], window: NSWindow?) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("w5h-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
