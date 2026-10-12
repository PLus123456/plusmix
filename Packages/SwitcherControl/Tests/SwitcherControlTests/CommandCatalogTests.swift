import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherControl

/// 命令目录：42 个 case 一个不少、JSON 顶层键就是 case 名、docs/api.md 与生成器同步。
final class CommandCatalogTests: XCTestCase {
    func testCatalog_coversEveryCommandCase_andWireKeyIsCaseName() throws {
        XCTAssertEqual(CommandKind.allCases.count, 42, "契约 Command 有 42 个 case（CONTRACTS.md §2.6；P3 按提案 010 / 012 从 27 加到 33，提案 016 加 setTransitionParams，提案 026 加 setMonitorSource，P5-2 按 020 / 021 / 023 加 7 条）")
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
        // P5-2：提案 020 / 021 / 023 的七条
        XCTAssertEqual(CommandCatalog.entry(for: .useTransitionSlot).fields, [CommandField(name: "slot", type: .transitionSlot), CommandField(name: "start", type: .onOff)])
        XCTAssertEqual(CommandCatalog.entry(for: .setTransitionSlot).fields, [CommandField(name: "slot", type: .transitionSlot), CommandField(name: "config", type: .json("TransitionSlot"))])
        XCTAssertFalse(CommandKind.setTransitionSlot.operatorFacing, "config 是结构体 → 高级：手写 JSON")
        XCTAssertEqual(CommandCatalog.entry(for: .setFTBDuration).fields, [CommandField(name: "ticks", type: .durationTicks)])
        XCTAssertEqual(CommandCatalog.entry(for: .setPlayback).fields, [CommandField(name: "input", type: .input(allowsBlack: false)), CommandField(name: "paused", type: .onOff)])
        XCTAssertEqual(CommandCatalog.entry(for: .seekPlayback).fields, [CommandField(name: "input", type: .input(allowsBlack: false)), CommandField(name: "seconds", type: .seconds)])
        XCTAssertEqual(CommandCatalog.entry(for: .setInputAudio).fields,
                       [CommandField(name: "input", type: .input(allowsBlack: false)), CommandField(name: "solo", type: .onOff, optional: true),
                        CommandField(name: "afv", type: .onOff, optional: true), CommandField(name: "routing", type: .busRouting, optional: true)])
        XCTAssertEqual(CommandCatalog.entry(for: .setInputColor).fields,
                       [CommandField(name: "input", type: .input(allowsBlack: false)), CommandField(name: "color", type: .choice(InputColor.allCases.map(\.rawValue)), optional: true)])
        XCTAssertTrue([CommandKind.useTransitionSlot, .setFTBDuration, .setPlayback, .seekPlayback, .setInputAudio, .setInputColor].allSatisfy { $0.operatorFacing })
    }

    /// P5-3：提案 026 允许 headphones（用户 2026-10-12）——setMonitorSource 的 bus 0–3 四条都能选（3 = 听耳机总线自己），说明里不再写"无效"；命令数不变。
    func testCatalog_026_monitorSourceAllFourBuses() {
        XCTAssertEqual(CommandKind.allCases.count, 42, "P5-3 不加命令")
        let monitor = CommandCatalog.entry(for: .setMonitorSource)
        XCTAssertEqual(monitor.fields, [CommandField(name: "bus", type: .bus)])
        let busNote = monitor.parameters.first { $0.name == "bus" }?.note ?? ""
        XCTAssertTrue(busNote.contains("3 = headphones"), busNote)
        XCTAssertFalse(busNote.contains("无效") || monitor.summary.contains("无效"), "headphones 合法了：\(monitor.summary) / \(busNote)")
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
