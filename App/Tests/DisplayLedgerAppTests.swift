// W3-E3 交付第 3 条：主界面 PGM 监视器 / 多画面窗口的 dropped 走 DisplayFrameLedger（W3-C2 的记账源，夹在渲染器与 MetalDisplayView 之间），
// 不再用"拿不到 drawable 的次数"近似；窗口被遮住 / 收起时断开连续呈现，那段记 undelivered（提案 018）；多画面窗口关着 = idle、不记。
// Stats.display[] 的 monitor / multiviewWindow 两项与记账源同源（铁律 4）。出帧类用例：要桌面可见（W3-E2 报告 §5 第 1 条）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherRender
import SwitcherExternal
@testable import Switcher

@MainActor
final class DisplayLedgerAppTests: XCTestCase {
    func testDisplayStats_monitorAndMultiviewWindowDroppedFromLedger() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        session.send(.setProgram(input: 1))
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let display = wc.programMonitor.display
        let ledger = try XCTUnwrap(wc.programLedger, "PGM 监视器应夹一层记账源")
        XCTAssertTrue((display.source as AnyObject?) === ledger, "显示视图的来源是记账源，它再转给渲染器")
        XCTAssertTrue((ledger.upstream as AnyObject) === session.renderer)
        XCTAssertTrue(ledger.view === display)
        AppTest.pump(seconds: 1.5)
        guard display.presentedFrames > 30 else {
            throw XCTSkip("PGM 监视器 1.5 s 只画了 \(display.presentedFrames) 帧：窗口不可见（锁屏 / 别的 Space），这条要桌面可见")
        }

        // Stats 里的 monitor 项是累计值（显示视图跨 session 活着，frames 跨 session 累计；换 session 时旧记账源的数并进来、不回退），所以都按增量比
        func monitorEntry() throws -> Stats.DisplayEntry { try XCTUnwrap(wc.displayStatsEntries.first { $0.kind == "monitor" }) }

        // 1. 主线程卡 300 ms：渲染器照常出帧（约 18 个版本），监视器两次刷新之间被覆盖的版本记 dropped；拿不到 drawable 的次数不变
        let d0 = ledger.droppedFrames, u0 = ledger.undeliveredFrames, noDrawable0 = display.skipCounters.noDrawable
        let m0 = try monitorEntry()
        Thread.sleep(forTimeInterval: 0.3)
        AppTest.pump(seconds: 0.5)
        let d1 = ledger.droppedFrames
        let m1 = try monitorEntry()
        print("监视器记账：卡主线程 300 ms → dropped \(d0) → \(d1)（Stats 项 \(m0.dropped) → \(m1.dropped)），noDrawable \(noDrawable0) → \(display.skipCounters.noDrawable)")
        XCTAssertGreaterThanOrEqual(d1 - d0, 10, "卡住 300 ms（约 18 个节目帧）应记下没赶上刷新的帧")
        XCTAssertEqual(display.skipCounters.noDrawable, noDrawable0, "这些不是拿不到 drawable——dropped 不再是 noDrawable 的近似")
        XCTAssertEqual(ledger.undeliveredFrames, u0, "窗口一直可见，不记 undelivered")

        // 2. displayStatsEntries 的 monitor 项与记账源同源：增量一样；进 Stats 的就是它（下一行的值落在前后两次读之间）
        XCTAssertEqual(m1.output, 0)
        XCTAssertEqual(m1.state, "presenting")
        XCTAssertEqual(m1.frames, display.presentedFrames)
        XCTAssertEqual(m1.dropped - m0.dropped, d1 - d0, "Stats 项的 dropped 就是记账源的数")
        XCTAssertEqual(m1.undelivered - m0.undelivered, ledger.undeliveredFrames - u0)
        let before = try monitorEntry().dropped
        let after0 = Date()
        var line: Stats?
        let token = session.observeStats { s in if Date() > after0.addingTimeInterval(0.1) { line = s } }
        defer { token.invalidate() }
        XCTAssertTrue(AppTest.waitUntil(3) { line != nil }, "应收到下一行 Stats")
        let inStats = try XCTUnwrap(line?.display.first { $0.kind == "monitor" && $0.output == 0 }, "\(String(describing: line?.display))")
        XCTAssertGreaterThanOrEqual(inStats.dropped, before)
        XCTAssertLessThanOrEqual(inStats.dropped, try monitorEntry().dropped, "Stats.display[] 的 monitor.dropped 来自同一个记账源")

        // 3. 遮住主窗口 1.2 s：display link 暂停，这段渲染器出的帧记 undelivered、不记 dropped
        AppTest.pump(seconds: 0.3)
        let d2 = ledger.droppedFrames, u2 = ledger.undeliveredFrames
        let m2 = try monitorEntry()
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.titled], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .darkGray
        cover.level = .floating
        cover.orderFrontRegardless()
        AppTest.pump(seconds: 1.2)
        let coveredPaused = display.isLinkPaused
        cover.orderOut(nil)
        cover.close()
        AppTest.pump(seconds: 0.8)
        let d3 = ledger.droppedFrames, u3 = ledger.undeliveredFrames
        let m3 = try monitorEntry()
        print("监视器记账：遮住 1.2 s → undelivered \(u2) → \(u3)，dropped \(d2) → \(d3)（link 暂停 = \(coveredPaused)）")
        XCTAssertTrue(coveredPaused, "被遮住时显示视图应暂停")
        XCTAssertGreaterThanOrEqual(u3 - u2, 40, "遮住 1.2 s（约 72 帧）应记 undelivered")
        XCTAssertLessThanOrEqual(d3 - d2, 2, "遮住的那段不算没赶上刷新")
        XCTAssertEqual(m3.undelivered - m2.undelivered, u3 - u2, "Stats 项的 undelivered 也是记账源的数")
        XCTAssertEqual(m3.dropped - m2.dropped, d3 - d2)

        // 4. 多画面窗口：开着 = presenting（它自己的记账源）；关着 = idle，关着的时候不记 undelivered
        XCTAssertNil(wc.displayStatsEntries.first { $0.kind == "multiviewWindow" }, "没开过多画面窗口不报这一项")
        wc.toggleMultiviewWindow()
        let mv = try XCTUnwrap(wc.multiviewWindow)
        let mvLedger = try XCTUnwrap(mv.ledger)
        XCTAssertTrue((mv.displayView.source as AnyObject?) === mvLedger)
        AppTest.pump(seconds: 1)
        var entry = try XCTUnwrap(wc.displayStatsEntries.first { $0.kind == "multiviewWindow" })
        XCTAssertEqual(entry.state, "presenting")
        XCTAssertEqual(entry.output, 0)
        XCTAssertGreaterThan(entry.frames, 20)
        XCTAssertEqual(entry.dropped, mv.droppedFrames)
        XCTAssertEqual(entry.undelivered, mv.undeliveredFrames)
        wc.toggleMultiviewWindow()
        AppTest.pump(seconds: 0.3)
        let closedUndelivered = mv.undeliveredFrames, closedDropped = mv.droppedFrames
        AppTest.pump(seconds: 1)
        entry = try XCTUnwrap(wc.displayStatsEntries.first { $0.kind == "multiviewWindow" })
        XCTAssertEqual(entry.state, "idle", "关着 = idle")
        XCTAssertEqual(mv.undeliveredFrames, closedUndelivered, "关着的窗口没有该送的帧，不记 undelivered")
        XCTAssertEqual(mv.droppedFrames, closedDropped)
        // 再开：从新的基线接着记，累计值不回退
        wc.toggleMultiviewWindow()
        AppTest.pump(seconds: 1)
        XCTAssertEqual(wc.displayStatsEntries.first { $0.kind == "multiviewWindow" }?.state, "presenting")
        XCTAssertGreaterThanOrEqual(mv.undeliveredFrames, closedUndelivered)
        XCTAssertLessThanOrEqual(mv.undeliveredFrames - closedUndelivered, 2, "重新打开不把关着的那段补记成 undelivered")
        wc.toggleMultiviewWindow()
    }
}
