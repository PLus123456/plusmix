import XCTest
@testable import SwitcherContracts

/// 提案 032（用户 2026-10-18 批"按建议"，P5-5 / prompt 123 落地；W2-C4 报告 §3 第 4 条：主 API 加一路编号极大的输入后，兼容层按编号分配的 TALLY 串 /
/// XML 占位分配失败崩或卡死——S1）：输入编号的合法范围 `InputConfig.numberRange` = 1…16 进契约，与 App"添加输入满 16 路"、引擎默认 `maxInputs` 一致。
/// 同一条边界两处共用：节目文件（`MixerState.validate()` → `MixerStateError.inputNumber`，Show.load / loadShow 读到不打开）、API（`CommandValidator` 的 addInput，
/// HTTP 400；reducer 同判、原样返回）。0 与负数照旧是 `reservedInputNumber`；JSON 形态不变、不加命令。
final class Contracts032Tests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func input(_ number: Int) -> InputConfig {
        InputConfig(number: number, name: "输入 \(number)", source: .synthetic(settings: SyntheticSourceSettings()))
    }

    /// 常量：1…16。两端在里面；0、17、极大、负数不在。
    func test032_numberRange_oneToSixteen() {
        XCTAssertEqual(InputConfig.numberRange, 1...16)
        XCTAssertEqual(InputConfig.numberRange.lowerBound, MixerState.noInput + 1, "0 仍保留给黑场")
        for n in [1, 2, 8, 16] { XCTAssertTrue(InputConfig.numberRange.contains(n), "\(n)") }
        for n in [0, -1, 17, 99, 1 << 62, Int.max, Int.min] { XCTAssertFalse(InputConfig.numberRange.contains(n), "\(n)") }
    }

    /// 节目里的输入编号超过 16 → `MixerStateError.inputNumber(input:)`；16 合法；0 / 负数仍是 `reservedInputNumber`（老口径不变）。
    /// Show.load 读到这种文件不打开（与别的不变量同一处理）——JSON 里直接写 2^62 的也一样（116 的触发条件绕过 addInput 的那一条路）。
    func test032_validateRejectsInputNumberAboveRange_showLoadRefuses() throws {
        var s = MixerState(format: .hd1080p60)
        s.inputs = [Self.input(1), Self.input(16)]
        XCTAssertNoThrow(try s.validate(), "16 = 上限")
        for bad in [17, 99, 1 << 62, Int.max] {
            s.inputs[1].number = bad
            XCTAssertThrowsError(try s.validate(), "\(bad)") { XCTAssertEqual($0 as? MixerStateError, .inputNumber(input: bad)) }
        }
        for reserved in [0, -1, Int.min] {
            s.inputs[1].number = reserved
            XCTAssertThrowsError(try s.validate(), "\(reserved)") { XCTAssertEqual($0 as? MixerStateError, .reservedInputNumber(reserved)) }
        }

        // 节目文件：Show.load 先搬迁再 validate，越界的编号读进来报错、不打开
        s.inputs[1].number = 17
        XCTAssertThrowsError(try Show.load(from: try Show(name: "17 路", state: s).save())) {
            XCTAssertEqual($0 as? MixerStateError, .inputNumber(input: 17))
        }
        s.inputs[1].number = 16
        let good = try Show(name: "16 路", state: s).save()
        XCTAssertEqual(try Show.load(from: good).inputs.map(\.number), [1, 16])
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: good) as? [String: Any])
        var inputs = try XCTUnwrap(obj["inputs"] as? [[String: Any]])
        inputs[1]["number"] = 1 << 62
        obj["inputs"] = inputs
        XCTAssertThrowsError(try Show.load(from: try JSONSerialization.data(withJSONObject: obj))) {
            XCTAssertEqual($0 as? MixerStateError, .inputNumber(input: 1 << 62))
        }
    }

    /// 仓库里带的节目（Samples/ 三份样例、scenarios/ 四份、契约测试的 P3 之前的 g4 老节目）编号都在 1…16、Show.load 照读——032 不让现有节目打不开。
    func test032_shippedShowsWithinRange_stillLoad() throws {
        let files = ["Samples/church/church.switcher.json", "Samples/classroom/classroom.switcher.json", "Samples/event/event.switcher.json",
                     "scenarios/m0-show.json", "scenarios/g3-show.json", "scenarios/g4-show.json", "scenarios/g4-ndi-show.json",
                     "Packages/SwitcherCore/Tests/SwitcherContractsTests/Fixtures/g4-show-before-p3.json"]
        for f in files {
            let show = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent(f)))
            XCTAssertFalse(show.inputs.isEmpty, f)
            XCTAssertTrue(show.inputs.allSatisfy { InputConfig.numberRange.contains($0.number) }, "\(f)：\(show.inputs.map(\.number))")
        }
    }

    /// 不加字段：InputConfig 的键与写出形态不变（编号仍是一个整数，范围只在 validate / 校验器里查）。
    func test032_wireShapeUnchanged() throws {
        XCTAssertEqual(InputConfig.jsonKeys, ["number", "name", "source", "settings", "color"])
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try e.encode(InputConfig(number: 16, name: "满", source: .image(path: "/a.png"))), as: UTF8.self)
        XCTAssertTrue(json.hasPrefix(#"{"name":"满","number":16,"settings":"#), json)
        XCTAssertEqual(try JSONDecoder().decode(InputConfig.self, from: Data(json.utf8)).number, 16)
        // 解码不拒（越界在 validate 里报，与 fileRate / 转场槽同一处理），单路 InputConfig 照解
        let wide = json.replacingOccurrences(of: #""number":16"#, with: #""number":4611686018427387904"#)
        XCTAssertEqual(try JSONDecoder().decode(InputConfig.self, from: Data(wide.utf8)).number, 1 << 62)
    }
}
