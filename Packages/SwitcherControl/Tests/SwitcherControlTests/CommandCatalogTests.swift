import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherControl

/// 命令目录：27 个 case 一个不少、JSON 顶层键就是 case 名、docs/api.md 与生成器同步。
final class CommandCatalogTests: XCTestCase {
    func testCatalog_coversEveryCommandCase_andWireKeyIsCaseName() throws {
        XCTAssertEqual(CommandKind.allCases.count, 27, "契约 Command 有 27 个 case（CONTRACTS.md §2.6）")
        for kind in CommandKind.allCases {
            let doc = CommandCatalog.entry(for: kind)
            XCTAssertEqual(CommandKind(of: doc.example), kind, "\(kind) 的样例不是它自己")
            let json = try APIJSON.encoder.encode(doc.example)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            XCTAssertEqual(Array(object.keys), [kind.rawValue], "\(kind) 的 JSON 顶层键")
            XCTAssertFalse(doc.summary.isEmpty, "\(kind) 缺说明")
            // 样例能往返
            let back = try APIJSON.decoder.decode(Command.self, from: json)
            XCTAssertEqual(back, doc.example)
        }
        XCTAssertEqual(Set(CommandCatalog.entries.map(\.kind)).count, CommandKind.allCases.count)
    }

    func testCatalog_generatedMarkdownMatchesCommittedDocsApiMd() throws {
        // docs/api.md 在仓库根：Packages/SwitcherControl/Tests/SwitcherControlTests/ → 上四级
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "docs/api.md")
        let committed = try String(contentsOf: url, encoding: .utf8)
        let generated = APIDocument.markdown()
        XCTAssertEqual(committed, generated, "docs/api.md 过期：swift run switcher-apidoc > docs/api.md")
    }
}
