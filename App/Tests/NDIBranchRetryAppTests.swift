// W3-E4 交付第 5 条（可选；W3-E3 报告 §3 第 2 条）：源是输入 n 的 NDI 发送，那一路的帧槽分支（每路 InputFrameTee.maxBranches 个，与 ISO / Aux 共用）
// 用完时 sender 照跑、没画面、只提示一次；之后那一路有分支还回来（InputRuntime.releaseBranch → onBranchReleased）→ OutputRuntime 给它重新要分支、
// 接上再送、提示一次"接上了"，不用关开一次。不需要 NDI SDK：分支 / tap 是 App 侧的接线，没有 SDK 时 sender 是空实现（帧照收、直接丢），tap 的转发计数照样走。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherISO
@testable import Switcher

@MainActor
final class NDIBranchRetryAppTests: XCTestCase {
    @MainActor final class Notices { var list: [String] = [] }

    func testW3E4_5_ndiInputSourceBranchExhausted_noticeOnce_reattachesWhenBranchReturned() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        XCTAssertEqual(AppTest.waitLive(session, input: 2, timeout: 5), .live)
        // 占满输入 2 的分支（ISO / Aux 就是这么占的）
        var held: [LockFreeFrameSlot] = []
        for _ in 0..<InputFrameTee.maxBranches { held.append(try XCTUnwrap(session.inputs.openBranch(input: 2), "应能开到 \(InputFrameTee.maxBranches) 个分支")) }
        XCTAssertNil(session.inputs.openBranch(input: 2), "第 \(InputFrameTee.maxBranches + 1) 个开不出来")
        let notices = Notices()
        let token = session.observeNotices { notices.list.append($0) }
        func exhausted() -> Int { notices.list.filter { $0.contains("用完") }.count }
        func restored() -> Int { notices.list.filter { $0.contains("重新接上") }.count }

        let page = AppTest.controller.panels.showOutputSettings(tab: .ndi).model
        let number = page.addNDI(name: "Switcher 分支重试 \(ProcessInfo.processInfo.processIdentifier)", groups: "", conversion: "cpu", source: .input(number: 2))
        XCTAssertTrue(AppTest.waitUntil(8) { session.outputs.ndiSenders[number]?.phase == .running }, "\(String(describing: session.outputs.failed[number]))")
        let entry = try XCTUnwrap(session.outputs.ndiSenders[number])
        XCTAssertNil(entry.inputTap, "分支用完：没有 tap、没画面")
        XCTAssertNil(entry.branch)
        XCTAssertTrue(entry.branchPending, "记着在等分支")
        XCTAssertTrue(AppTest.waitUntil(2) { exhausted() == 1 }, "应提示一次分支用完：\(notices.list)")
        // 别的状态变化（切 PGM、改转换方式）让运行表再对一次快照：不重复提示、不重建 sender
        session.send(.setProgram(input: 2))
        page.setNDI(number, conversion: "auto")
        AppTest.pump(seconds: 1.0)
        XCTAssertEqual(exhausted(), 1, "只提示一次：\(notices.list)")
        XCTAssertTrue(session.outputs.ndiSenders[number] === entry, "不重建 sender")
        XCTAssertEqual(restored(), 0)

        // 还一个分支 → 运行表重新要到、接上、在送；分支数又是满的（3 个测试占的 + NDI 的 1 个）
        session.inputs.releaseBranch(held.removeLast(), input: 2)
        XCTAssertTrue(AppTest.waitUntil(5) { (session.outputs.ndiSenders[number]?.inputTap?.counters.forwarded ?? 0) > 30 },
                      "还了分支后应接上并转发：\(String(describing: session.outputs.ndiSenders[number]?.inputTap?.counters))")
        XCTAssertTrue(session.outputs.ndiSenders[number] === entry, "接的是分支，sender 不重建")
        XCTAssertFalse(entry.branchPending)
        XCTAssertEqual(entry.inputTap?.inputNumber, 2)
        XCTAssertEqual(session.inputs.entries[2]?.tee.branchCount, InputFrameTee.maxBranches)
        XCTAssertTrue(AppTest.waitUntil(2) { restored() == 1 }, "接上时提示一次：\(notices.list)")
        XCTAssertEqual(exhausted(), 1)
        XCTAssertNil(session.inputs.openBranch(input: 2), "又满了")
        print("NDI 分支重试（App）：占满 \(InputFrameTee.maxBranches) 个 → 提示 \(exhausted()) 次；还 1 个 → 接上、转发 \(entry.inputTap?.counters.forwarded ?? 0) 帧，提示 \(restored()) 次")

        // 收尾：删输出 → 分支还回去；测试占的也还掉
        page.removeOutput(number)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.ndiSenders[number] == nil })
        XCTAssertEqual(session.inputs.entries[2]?.tee.branchCount, held.count)
        for b in held { session.inputs.releaseBranch(b, input: 2) }
        XCTAssertEqual(session.inputs.entries[2]?.tee.branchCount, 0)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        token.invalidate()
        AppTest.controller.panels.closeAll()
    }
}
