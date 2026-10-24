import XCTest
@testable import SwitcherContracts

/// 提案 034（数值入口加固；Codex 2026-10-22 审查 N01 / N02 + "验证到的其他行为"）：节目文件 / API 进来的帧率、尺寸、叠加数组，
/// 非法时要抛可捕获的错误、进程在——原来 `Rational` / `FrameRate` 的 Codable 调到带 precondition 的 init、`Show.load → makeState → MixerState.init`
/// 先断言再 validate，try / catch 兜不住（SIGTRAP）。
/// 夹具 Fixtures/audit-20261022/ 是 Codex 探针写出的七份 JSON 原样（reports/codex-bug-audit-20261022-tests/，逐字节相同）：
/// valid 对照、fpsZero / fpsNegative / rationalMin（N01）、overlays0（N02）、dimensions（宽 −1 高 0 能加载）、fpsHuge（帧率 Int64.max/1 能解码、newShow 换拍时崩）。
final class Contracts034Tests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func fixture(_ mode: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audit-20261022/Audit20261022-\(mode).json"))
    }

    // MARK: N01：帧率解码

    /// N01：节目格式的帧率 0/1、−30/1、1/Int64.min → Show.load 抛 DecodingError（原来 SIGTRAP：前两份打印"帧率必须为正"，第三份在约分变号时溢出）；valid 对照照读。
    func testN01_showLoad_frameRateZeroNegativeOrInt64MinDenominator_throws() throws {
        let valid = try Show.load(from: try Self.fixture("valid"))
        XCTAssertEqual(valid.mixer.format, .hd1080p60, "对照：Codex 探针的有效节目照读")
        for mode in ["fpsZero", "fpsNegative", "rationalMin"] {
            XCTAssertThrowsError(try Show.load(from: try Self.fixture(mode)), mode) {
                XCTAssertTrue($0 is DecodingError, "\(mode)：解码阶段就拒，得到 \($0)")
            }
        }
    }

    /// N01：`Rational` / `FrameRate` 单独解码。分母 0（原来就拒）、分子或分母是 Int64.min（变号 / 取倒数会溢出）→ 抛；帧率分子 ≤ 0 → 抛"帧率必须为正"。
    /// 合法写法照解、约分照旧（−60/−1 = 60、60000/1001 = 59.94、−3/6 = −1/2 只对 Rational 合法）。JSON 形态不变。
    func testN01_decodeRationalAndFrameRate_illegalValuesThrow() throws {
        let d = JSONDecoder()
        func json(_ n: String, _ q: String) -> Data { Data(#"{"numerator":\#(n),"denominator":\#(q)}"#.utf8) }
        let min = String(Int64.min)
        for (n, q) in [("1", "0"), ("1", min), (min, "1"), (min, "-1"), ("0", min), (min, min)] {
            XCTAssertThrowsError(try d.decode(Rational.self, from: json(n, q)), "Rational \(n)/\(q)")
        }
        XCTAssertEqual(try d.decode(Rational.self, from: json("-3", "6")), Rational(-1, 2))
        XCTAssertEqual(try d.decode(Rational.self, from: json(String(Int64.max), "1")), Rational(Int64.max), "Int64.max 本身能表示，Rational 照解（范围在 validate 里查）")
        for (n, q) in [("0", "1"), ("-30", "1"), ("30", "-1"), ("0", "1001"), ("1", min)] {
            XCTAssertThrowsError(try d.decode(FrameRate.self, from: json(n, q)), "FrameRate \(n)/\(q)")
        }
        XCTAssertEqual(try d.decode(FrameRate.self, from: json("60000", "1001")), .fps5994)
        XCTAssertEqual(try d.decode(FrameRate.self, from: json("-60", "-1")), .fps60, "负负得正，约分后就是 60")
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try e.encode(FrameRate.fps5994), as: UTF8.self), #"{"denominator":1001,"numerator":60000}"#, "JSON 形态不变")
    }

    /// N01：屏幕输入的 frameRate 也是 FrameRate——API 的 addInput / setInputSource 在校验器之前解码，原来同样 SIGTRAP。
    func testN01_screenSourceAndCommandDecode_illegalFrameRateThrows() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let source = InputSource.screen(target: .display(id: 1), frameRate: .fps30, captureAudio: false)
        let good30 = #"{"denominator":1,"numerator":30}"#
        let bads = [#"{"denominator":1,"numerator":0}"#, #"{"denominator":1,"numerator":-30}"#, #"{"denominator":-9223372036854775808,"numerator":1}"#]
        let sourceText = String(decoding: try e.encode(source), as: UTF8.self)
        XCTAssertEqual(try JSONDecoder().decode(InputSource.self, from: Data(sourceText.utf8)), source, "对照")
        for bad in bads {
            XCTAssertThrowsError(try JSONDecoder().decode(InputSource.self, from: Data(sourceText.replacingOccurrences(of: good30, with: bad).utf8)), bad)
        }
        for command in [Command.addInput(config: InputConfig(number: 5, name: "屏幕", source: source)), .setInputSource(input: 5, source: source)] {
            let text = String(decoding: try e.encode(command), as: UTF8.self)
            XCTAssertTrue(text.contains(good30), text)
            XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(text.utf8)), command, "对照")
            for bad in bads {
                XCTAssertThrowsError(try JSONDecoder().decode(Command.self, from: Data(text.replacingOccurrences(of: good30, with: bad).utf8)), "\(text) ← \(bad)")
            }
        }
    }

    // MARK: N02：叠加数组先查结构

    /// N02：`mixer.overlays` 不是 4 个 → Show.load 抛 `MixerStateError.overlayCount`（原来 makeState → MixerState.init 的 precondition 先崩，这个错误永远到不了）；
    /// 走 `Show.migrate(from:schemaVersion:)` 那条路同样。
    func testN02_showLoad_overlayCountNotFour_throwsOverlayCount() throws {
        XCTAssertThrowsError(try Show.load(from: try Self.fixture("overlays0"))) {
            XCTAssertEqual($0 as? MixerStateError, .overlayCount(0))
        }
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Self.fixture("valid")) as? [String: Any])
        var mixer = try XCTUnwrap(obj["mixer"] as? [String: Any])
        var overlays = try XCTUnwrap(mixer["overlays"] as? [Any])
        overlays.append(overlays[0])
        mixer["overlays"] = overlays
        obj["mixer"] = mixer
        let five = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try Show.load(from: five)) { XCTAssertEqual($0 as? MixerStateError, .overlayCount(5)) }
        let document = try JSONDecoder().decode(JSONValue.self, from: try Self.fixture("overlays0"))
        XCTAssertThrowsError(try Show.migrate(from: document, schemaVersion: Show.currentSchemaVersion)) {
            XCTAssertEqual($0 as? MixerStateError, .overlayCount(0))
        }
    }

    // MARK: 尺寸 / 超大正帧率（"验证到的其他行为"）

    /// 宽 −1 高 0、帧率 Int64.max/1：原来都能 Show.load（后者在 `MixerState.newShow(format:)` 按帧率换拍时崩）。范围进 validate 之后读到不打开。
    func test034_showLoad_badDimensionsAndHugeFrameRate_refused() throws {
        for mode in ["dimensions", "fpsHuge"] {
            XCTAssertThrowsError(try Show.load(from: try Self.fixture(mode)), mode)
        }
    }
}
