import XCTest
import SwitcherContracts
@testable import SwitcherControl

/// P5-7：提案 034 的边界写进命令目录（docs/api.md 由它生成），文字与校验器 400 的文案同一组常量；字段（选动作面板的表单）不变、命令数仍 42。
/// 放新文件是因为 CommandCatalogTests 不在本会话的目录里（OWNERSHIP：SwitcherControlTests 只动 CommandBusTests / 新文件）。
final class CommandCatalog034Tests: XCTestCase {
    func testCatalog_034_numericLimitsDocumented() {
        XCTAssertEqual(CommandKind.allCases.count, 42, "034 不加命令（叠加清空用 input 0）")
        for kind in [CommandKind.fade, .setTransition, .setFTBDuration, .setTransitionSlot, .setOverlay] {
            let entry = CommandCatalog.entry(for: kind)
            XCTAssertTrue((entry.summary + entry.parameters.map(\.note).joined()).contains("864000"), "\(kind)：\(entry.summary) \(entry.parameters)")
        }
        let overlay = CommandCatalog.entry(for: .overlay)
        XCTAssertTrue(overlay.parameters.first { $0.name == "input" }?.note.contains("0 = 清空") == true, "\(overlay.parameters)")
        XCTAssertEqual(overlay.fields.map(\.name), ["channel", "on", "input"])
        for kind in [CommandKind.addInput, .setInputSource] {
            let summary = CommandCatalog.entry(for: kind).summary
            XCTAssertTrue(summary.contains("1–240") && summary.contains("16–8192"), "\(kind)：\(summary)")
            XCTAssertTrue(summary.contains("0.1–8"), "031 那句还在：\(summary)")
        }
        XCTAssertTrue(CommandCatalog.entry(for: .addInput).summary.contains("1–16"), "032 那句还在")
        let load = CommandCatalog.entry(for: .loadShow).summary
        XCTAssertTrue(load.contains("运行中不能换格式") && load.contains("makeValidatedState"), load)
    }
}
