import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherControl

/// 命令目录：34 个 case 一个不少、JSON 顶层键就是 case 名、docs/api.md 与生成器同步。
final class CommandCatalogTests: XCTestCase {
    func testCatalog_coversEveryCommandCase_andWireKeyIsCaseName() throws {
        XCTAssertEqual(CommandKind.allCases.count, 34, "契约 Command 有 34 个 case（CONTRACTS.md §2.6；P3 按提案 010 / 012 从 27 加到 33，提案 016 加 setTransitionParams）")
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

    /// W5-J（01a N1 / N3，04 Q51）：每条命令的类型化参数描述——与 parameters 同名同序、就是样例 JSON 那一层的键（可空的参数样例里可以缺）；
    /// 选动作面板按它生成表单。整条替换 / 增删类（参数里有只能手写 JSON 的结构体，或删输入 / 输出）不面向操作员，只放"高级：手写 JSON"。
    func testCatalog_typedFieldsMatchExampleKeysAndWholeReplaceIsAdvanced() throws {
        for kind in CommandKind.allCases {
            let doc = CommandCatalog.entry(for: kind)
            XCTAssertEqual(doc.fields.map(\.name), doc.parameters.map(\.name), "\(kind)：类型化描述与参数说明同名同序")
            let json = try APIJSON.encoder.encode(doc.example)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            let body = try XCTUnwrap(object[kind.rawValue] as? [String: Any], "\(kind) 的样例")
            let required = Set(doc.fields.filter { !$0.optional }.map(\.name))
            XCTAssertTrue(required.isSubset(of: Set(body.keys)), "\(kind)：必填参数 \(required) 都在样例里 \(body.keys.sorted())")
            XCTAssertTrue(Set(body.keys).isSubset(of: Set(doc.fields.map(\.name))), "\(kind)：样例里的键都有描述")
            let hasJSON = doc.fields.contains { if case .json = $0.type { return true }; return false }
            let destructive = kind == .removeInput || kind == .removeOutput
            XCTAssertEqual(kind.operatorFacing, !hasJSON && !destructive, "\(kind)：面向操作员 ⇔ 表单生成得出来且不是删除")
        }
        let advanced = Set(CommandKind.allCases.filter { !$0.operatorFacing })
        XCTAssertTrue([CommandKind.addInput, .removeInput, .setInputSettings, .setOutputSettings, .loadShow].allSatisfy(advanced.contains), "Q51 点名的五条默认不列")
        XCTAssertTrue([CommandKind.cut, .setPreview, .setProgram, .fade, .setTransition, .autoTransition, .ftb, .overlay, .mute, .audioGain, .busMute, .busGain,
                       .setAFV, .startRecord, .stopRecord, .startStream, .stopStream, .setOutputEnabled].allSatisfy { $0.operatorFacing })
        // 几个具体的描述
        XCTAssertEqual(CommandCatalog.entry(for: .setPreview).fields, [CommandField(name: "input", type: .input(allowsBlack: true))])
        XCTAssertEqual(CommandCatalog.entry(for: .overlay).fields, [CommandField(name: "channel", type: .overlayChannel), CommandField(name: "on", type: .onOff),
                                                                   CommandField(name: "input", type: .input(allowsBlack: false), optional: true)])
        XCTAssertEqual(CommandCatalog.entry(for: .fade).fields, [CommandField(name: "durationTicks", type: .durationTicks)])
        XCTAssertEqual(CommandCatalog.entry(for: .startRecord).fields, [CommandField(name: "output", type: .output(kinds: [.record]))])
        XCTAssertEqual(CommandCatalog.entry(for: .setOutputEnabled).fields.first?.type, .output(kinds: [.ndi, .externalDisplay, .virtualCamera, .multiview]))
        XCTAssertEqual(CommandCatalog.entry(for: .busMute).fields, [CommandField(name: "bus", type: .bus), CommandField(name: "on", type: .onOff)])
        XCTAssertEqual(CommandCatalog.entry(for: .audioGain).fields.last?.type, .decibels(min: -96, max: 24))
        XCTAssertEqual(CommandCatalog.entry(for: .setMonitorMode).fields, [CommandField(name: "mode", type: .choice(["afl", "pfl"]))])
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
