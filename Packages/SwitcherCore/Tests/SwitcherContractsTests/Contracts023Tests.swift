import Foundation
import XCTest
@testable import SwitcherContracts

/// 提案 023 二–五（用户 2026-10-11 批，P5-2 落地）：
/// 二 `RecordSettings.container` 标废弃（照读不写：缺键 = mov，写出仍写）；三 `InputSettings.effects` 只放音频（只改文字）；
/// 四 `InputColor` + `InputConfig.color`（可选，nil 不写键）+ 命令 `setInputColor` + W5-H 的 layout 键搬迁 `Show.migratingLegacyInputCategories()`（不并进 Show.load）；
/// 五 命令 `setInputAudio(input:solo:afv:routing:)`（三参数可选，nil = 不动、JSON 不写键）。
final class Contracts023Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    private func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try sortedEncoder.encode(v), as: UTF8.self) }
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: 二

    func test023_2_recordContainer_missingKeyReadsAsMov_stillWritten() throws {
        let noContainer = #"{"directory":"/a","fileNamePattern":"{show}","fragmentIntervalSeconds":1,"remuxToMP4":true}"#
        let r = try JSONDecoder().decode(RecordSettings.self, from: Data(noContainer.utf8))
        XCTAssertEqual(r.container, .mov, "缺键 = mov（运行时从不读它，文件一律 .mov）")
        XCTAssertTrue(r.remuxToMP4)
        // 老文件里写着 mp4 的照读、原样写回
        let mp4 = try JSONDecoder().decode(RecordSettings.self, from: Data(#"{"container":"mp4","directory":"/a","fileNamePattern":"{show}","fragmentIntervalSeconds":1,"remuxToMP4":false}"#.utf8))
        XCTAssertEqual(mp4.container, .mp4)
        XCTAssertTrue(try json(mp4).contains(#""container":"mp4""#))
        // 写出总是写全（含废弃的 container）
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(r)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), Set(RecordSettings.jsonKeys))
        XCTAssertEqual(RecordSettings.jsonKeys, ["directory", "fileNamePattern", "container", "fragmentIntervalSeconds", "remuxToMP4", "armed", "ownFormat"], "键表不变")
    }

    // MARK: 四

    func test023_4_inputColor_fieldOptionalNotWrittenWhenNil_andCommandShape() throws {
        XCTAssertEqual(InputColor.allCases.map(\.rawValue), ["red", "orange", "yellow", "green", "blue", "purple"], "Finder 标签那六种 = W5-H 的 rawValue")
        XCTAssertEqual(InputConfig.jsonKeys, ["number", "name", "source", "settings", "color"])
        let plain = InputConfig(number: 1, name: "机位", source: .image(path: "/a.png"))
        XCTAssertNil(plain.color, "默认无分类")
        let plainJSON = try json(plain)
        XCTAssertFalse(plainJSON.contains("color"), "nil 不写键：\(plainJSON)")
        let red = InputConfig(number: 1, name: "机位", source: .image(path: "/a.png"), color: .red)
        XCTAssertTrue(try json(red).contains(#""color":"red""#))
        XCTAssertEqual(try JSONDecoder().decode(InputConfig.self, from: try sortedEncoder.encode(red)), red)
        XCTAssertEqual(try JSONDecoder().decode(InputConfig.self, from: try sortedEncoder.encode(plain)), plain)
        // 023 之前的文件：没有 color 键 → nil；认不出的颜色照 Codable 规则报错（文件级的脏数据不静默吞）
        let old = #"{"name":"x","number":2,"settings":\#(try json(InputSettings())),"source":{"image":{"path":"/b.png"}}}"#
        XCTAssertNil(try JSONDecoder().decode(InputConfig.self, from: Data(old.utf8)).color)
        XCTAssertThrowsError(try JSONDecoder().decode(InputConfig.self, from: Data(old.replacingOccurrences(of: #""number":2"#, with: #""number":2,"color":"pink""#).utf8)))
        // 命令
        XCTAssertEqual(try json(Command.setInputColor(input: 1, color: .blue)), #"{"setInputColor":{"color":"blue","input":1}}"#)
        XCTAssertEqual(try json(Command.setInputColor(input: 1, color: nil)), #"{"setInputColor":{"input":1}}"#, "清分类：不写 color 键")
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setInputColor":{"input":1}}"#.utf8)), .setInputColor(input: 1, color: nil))
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setInputColor":{"input":1,"color":"green"}}"#.utf8)), .setInputColor(input: 1, color: .green))
    }

    /// W5-H 存在 Show.layout["inputCategories"] 里的分类 → 各路 InputConfig.color：有键按原值搬、认不出 / 输入不存在的跳过、正式字段已有值的不动、搬完删键、幂等；
    /// 名字键 inputCategoryNames 留在 layout（023 四默认 (a)）；与 025 同一做法：不并进 Show.load（App 切换时在 Show.load 后调一次，归之后的 App 会话）。
    func test023_4_migratingLegacyInputCategories_movesLayoutKeyIntoInputConfigColor() throws {
        XCTAssertEqual(InputConfig.legacyCategoriesLayoutKey, "inputCategories")
        var state = MixerState(format: .hd1080p60)
        state.inputs = (1...4).map { InputConfig(number: $0, name: "输入 \($0)", source: .image(path: "/\($0).png")) }
        state.inputs[3].color = .purple   // 4 号已经有正式字段
        var show = Show(name: "W5-H 存的", state: state)
        show.layout = ShowLayout(values: [
            InputConfig.legacyCategoriesLayoutKey: .object(["1": .string("red"), "3": .string("blue"), "9": .string("green"), "2": .string("pink"), "4": .string("red")]),
            "inputCategoryNames": .object(["red": .string("机位")]),
            "mixerVisible": .bool(true),
        ])
        let migrated = show.migratingLegacyInputCategories()
        XCTAssertEqual(migrated.inputs.map(\.color), [.red, nil, .blue, .purple], "1 / 3 搬了，2 认不出跳过，9 没这路，4 正式字段已有值不动")
        XCTAssertNil(migrated.layout.values[InputConfig.legacyCategoriesLayoutKey], "搬完删键")
        XCTAssertEqual(migrated.layout.values["inputCategoryNames"], .object(["red": .string("机位")]), "名字留在 layout（(a)）")
        XCTAssertEqual(migrated.layout.values["mixerVisible"], .bool(true))
        XCTAssertEqual(migrated.migratingLegacyInputCategories(), migrated, "幂等")
        // 没有旧键：一个字节不动
        XCTAssertEqual(migrated.migratingLegacyInputCategories().inputs, migrated.inputs)
        // 旧键不是对象：只清键
        var stray = show
        stray.layout.values[InputConfig.legacyCategoriesLayoutKey] = .string("red")
        XCTAssertNil(stray.migratingLegacyInputCategories().layout.values[InputConfig.legacyCategoriesLayoutKey])
        XCTAssertEqual(stray.migratingLegacyInputCategories().inputs.map(\.color), [nil, nil, nil, .purple])
        // Show.load / migratingLegacyKeys 不搬（App 在 Show.load 后调一次）：读回来旧键还在、字段仍是 nil
        let loaded = try Show.load(from: try show.save())
        XCTAssertNotNil(loaded.layout.values[InputConfig.legacyCategoriesLayoutKey])
        XCTAssertEqual(loaded.inputs.map(\.color), [nil, nil, nil, .purple])
        XCTAssertEqual(try Show.load(from: try migrated.save()), migrated, "搬完的节目再写再读不变")
    }

    // MARK: 五

    func test023_5_setInputAudio_optionalParametersNotWrittenWhenNil() throws {
        XCTAssertEqual(try json(Command.setInputAudio(input: 1)), #"{"setInputAudio":{"input":1}}"#, "全 nil = 什么都不动，只写 input")
        XCTAssertEqual(try json(Command.setInputAudio(input: 1, solo: true, afv: false, routing: BusRouting(master: true, busA: true))),
                       #"{"setInputAudio":{"afv":false,"input":1,"routing":{"busA":true,"busB":false,"headphones":false,"master":true},"solo":true}}"#)
        XCTAssertEqual(try json(Command.setInputAudio(input: 2, routing: .masterOnly)),
                       #"{"setInputAudio":{"input":2,"routing":{"busA":false,"busB":false,"headphones":false,"master":true}}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setInputAudio":{"input":1,"solo":true}}"#.utf8)), .setInputAudio(input: 1, solo: true, afv: nil, routing: nil))
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setInputAudio":{"input":1,"afv":true,"routing":{"master":false,"busA":true,"busB":false,"headphones":true}}}"#.utf8)),
                       .setInputAudio(input: 1, solo: nil, afv: true, routing: BusRouting(master: false, busA: true, busB: false, headphones: true)))
        // 老节目照读：输入设置形态没变
        for name in ["scenarios/g3-show.json", "scenarios/g4-show.json", "scenarios/m0-show.json"] {
            let show = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent(name)))
            XCTAssertTrue(show.inputs.allSatisfy { $0.color == nil }, name)
            XCTAssertEqual(try Show.load(from: try show.save()), show, name)
        }
    }
}
