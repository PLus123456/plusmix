import XCTest
@testable import SwitcherContracts

/// 提案 034（数值入口加固，用户 2026-10-25 批；Codex 2026-10-22 审查 N01 / N02 + "验证到的其他行为"）：节目文件 / API 进来的帧率、尺寸、叠加数组、时长、
/// 音频对齐帧数，非法时要抛可捕获的错误、进程在——原来 `Rational` / `FrameRate` 的 Codable 调到带 precondition 的 init、`Show.load → makeState → MixerState.init`
/// 先断言再 validate，try / catch 兜不住（SIGTRAP）。reducer / 校验器那一侧在 ReducerTests / CommandBusTests 的 testN0x_ / test034_。
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

    // MARK: ② 尺寸 / 帧率范围（"验证到的其他行为"）

    /// 宽 −1 高 0、帧率 Int64.max/1：原来都能 Show.load（后者在 `MixerState.newShow(format:)` 按帧率换拍时崩）。范围进 validate 之后读到不打开（`.format`）。
    /// 没有 slots 的老文件带同样的帧率：搬迁按帧率补出厂槽的换拍原来也溢出，现在钳住、照样走到 validate 报 `.format`。
    func test034_showLoad_badDimensionsAndHugeFrameRate_refused() throws {
        for mode in ["dimensions", "fpsHuge"] {
            XCTAssertThrowsError(try Show.load(from: try Self.fixture(mode)), mode) {
                guard case .format? = $0 as? MixerStateError else { return XCTFail("\(mode)：\($0)") }
            }
        }
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Self.fixture("fpsHuge")) as? [String: Any])
        var mixer = try XCTUnwrap(obj["mixer"] as? [String: Any])
        var transition = try XCTUnwrap(mixer["transition"] as? [String: Any])
        transition["slots"] = nil
        transition["currentSlot"] = nil
        mixer["transition"] = transition
        obj["mixer"] = mixer
        XCTAssertThrowsError(try Show.load(from: try JSONSerialization.data(withJSONObject: obj)), "020 之前的写法 + 超大帧率") {
            guard case .format? = $0 as? MixerStateError else { return XCTFail("\($0)") }
        }
        let huge = MixerState.newShow(format: ProgramFormat(width: 1920, height: 1080, frameRate: FrameRate(Int64.max)))
        XCTAssertEqual(huge.transition.slots.map(\.durationTicks), Array(repeating: DurationLimits.maxTicks, count: 4), "换拍钳到上限，不溢出")
        XCTAssertEqual(huge.overlays[0].animation.durationTicks, DurationLimits.maxTicks)
    }

    /// 常量与 validate：宽高各 16…8192、帧率 1…240 fps（按有理数比）；节目格式越界 → `.format(格式)`；App 的格式预设与边界值都合法。
    func test034_formatRange_constantsAndValidate() {
        XCTAssertEqual(ProgramFormat.sizeRange, 16...8192)
        XCTAssertEqual(FrameRate.programRange, Rational(1)...Rational(240))
        for rate in [FrameRate(1), .fps24, .fps25, .fps2997, .fps30, .fps50, .fps5994, .fps60, FrameRate(120), FrameRate(240), FrameRate(Rational(240_000, 1_001))] {
            XCTAssertTrue(FrameRate.programRange.contains(rate.framesPerSecond), "\(rate)")
        }
        for rate in [FrameRate(Rational(1, 2)), FrameRate(Rational(999, 1_000)), FrameRate(241), FrameRate(Rational(240_001, 1_000)), FrameRate(Int64.max)] {
            XCTAssertFalse(FrameRate.programRange.contains(rate.framesPerSecond), "\(rate)")
        }
        for format in [ProgramFormat.hd1080p60, .hd1080p5994, .hd1080p30, .hd720p60, .uhd2160p30,
                       ProgramFormat(width: 16, height: 16, frameRate: FrameRate(1)), ProgramFormat(width: 8192, height: 8192, frameRate: FrameRate(240)),
                       ProgramFormat(width: 1080, height: 1920, frameRate: .fps30), ProgramFormat(width: 8192, height: 4320, frameRate: .fps24)] {
            XCTAssertNoThrow(try MixerState.newShow(format: format).validate(), "\(format)")
        }
        for format in [ProgramFormat(width: -1, height: 0, frameRate: .fps60), ProgramFormat(width: 15, height: 1080, frameRate: .fps60),
                       ProgramFormat(width: 1920, height: 8193, frameRate: .fps60), ProgramFormat(width: Int.max, height: 1080, frameRate: .fps60),
                       ProgramFormat(width: 1920, height: 1080, frameRate: FrameRate(241)), ProgramFormat(width: 1920, height: 1080, frameRate: FrameRate(Rational(1, 2)))] {
            var s = MixerState(format: .hd1080p60)
            s.format = format
            XCTAssertThrowsError(try s.validate(), "\(format)") { XCTAssertEqual($0 as? MixerStateError, .format(format)) }
        }
    }

    /// 屏幕输入给了帧率（nil = 跟节目，不查）与合成源（②b）的帧率 / 宽高同一组范围：越界 → `.inputFrameRate(input:)` / `.inputSize(input:)`，
    /// 判定在契约的 `InputSource.rangeError(input:)`（validate / reducer / 校验器共用）；文件速率仍是 `.fileRate`（031）。
    func test034_inputSourceRanges_screenAndSynthetic() {
        func show(_ source: InputSource) -> MixerState {
            var s = MixerState(format: .hd1080p60)
            s.inputs = [InputConfig(number: 3, name: "源", source: source)]
            return s
        }
        let screen: (FrameRate?) -> InputSource = { .screen(target: .display(id: 1), frameRate: $0, captureAudio: false) }
        let synthetic: (FrameRate, Int, Int) -> InputSource = { .synthetic(settings: SyntheticSourceSettings(frameRate: $0, width: $1, height: $2)) }
        for ok in [screen(nil), screen(.fps30), screen(FrameRate(240)), screen(FrameRate(1)), synthetic(.fps5994, 1920, 1080), synthetic(FrameRate(240), 16, 8192)] {
            XCTAssertNil(ok.rangeError(input: 3), "\(ok)")
            XCTAssertNoThrow(try show(ok).validate(), "\(ok)")
        }
        let bad: [(InputSource, MixerStateError)] = [
            (screen(FrameRate(241)), .inputFrameRate(input: 3)), (screen(FrameRate(Rational(1, 2))), .inputFrameRate(input: 3)),
            (synthetic(FrameRate(Int64.max), 1920, 1080), .inputFrameRate(input: 3)), (synthetic(.fps60, 0, 1080), .inputSize(input: 3)),
            (synthetic(.fps60, 1920, 9000), .inputSize(input: 3)), (synthetic(FrameRate(300), -1, -1), .inputFrameRate(input: 3)),
            (.file(path: "/a.mov", endAction: .loop, rate: 0), .fileRate(input: 3, rate: 0)),
        ]
        for (source, error) in bad {
            XCTAssertEqual(source.rangeError(input: 3), error, "\(source)")
            XCTAssertThrowsError(try show(source).validate(), "\(source)") { XCTAssertEqual($0 as? MixerStateError, error) }
        }
        for other in [InputSource.image(path: "/a.png"), .camera(uniqueID: "x"), .ndi(sourceName: "A (B)"), .audio(deviceUID: ""), .decklink(deviceID: "")] {
            XCTAssertNil(other.rangeError(input: 3), "\(other)")
        }
    }

    // MARK: ④ 时长上限

    /// `DurationLimits.maxTicks` = 864 000（1 小时 @ 240 fps）；节目里四处时长（转场、四个槽、FTB、四路叠加动画）要在 0…上限，越界 → `.durationTicks(值)`。
    func test034_durationLimits_validateFourPlaces() {
        XCTAssertEqual(DurationLimits.maxTicks, 864_000)
        XCTAssertEqual(DurationLimits.maxTicks, 3_600 * 240, "1 小时 @ 240 fps")
        XCTAssertEqual(DurationLimits.tickRange, 0...864_000)
        let base = MixerState.newShow(format: .hd1080p60)
        XCTAssertNoThrow(try base.validate())
        let edits: [(String, (inout MixerState, Int) -> Void)] = [
            ("转场", { $0.transition.durationTicks = $1 }), ("槽 3", { $0.transition.slots[2].durationTicks = $1 }),
            ("FTB", { $0.ftb.durationTicks = $1 }), ("叠加 2", { $0.overlays[1].animation.durationTicks = $1 }),
        ]
        for (name, edit) in edits {
            for ok in [0, 1, DurationLimits.maxTicks] {
                var s = base
                edit(&s, ok)
                XCTAssertNoThrow(try s.validate(), "\(name) = \(ok)")
            }
            for bad in [DurationLimits.maxTicks + 1, Int.max, -1, Int.min] {
                var s = base
                edit(&s, bad)
                XCTAssertThrowsError(try s.validate(), "\(name) = \(bad)") { XCTAssertEqual($0 as? MixerStateError, .durationTicks(bad)) }
            }
        }
    }

    // MARK: ⑧ 音频对齐帧数

    /// `AudioState.alignmentRange` = 0…24 000（App 设置面板的范围）；节目里越界 → `.alignmentFrames(值)`、Show.load 不打开（原来极大值让 AudioEngine 起 session 时 Int64 换算溢出）。
    func test034_alignmentFrames_validateAndShowLoad() throws {
        XCTAssertEqual(AudioState.alignmentRange, 0...24_000)
        XCTAssertTrue(AudioState.alignmentRange.contains(AudioState.defaultAlignmentFrames))
        var s = MixerState(format: .hd1080p60)
        for ok in [0, 2048, 24_000] {
            s.audio.alignmentFrames = ok
            XCTAssertNoThrow(try s.validate(), "\(ok)")
        }
        for bad in [24_001, -1, 1 << 62] {
            s.audio.alignmentFrames = bad
            XCTAssertThrowsError(try s.validate(), "\(bad)") { XCTAssertEqual($0 as? MixerStateError, .alignmentFrames(bad)) }
        }
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Self.fixture("valid")) as? [String: Any])
        var audio = try XCTUnwrap(obj["audio"] as? [String: Any])
        audio["alignmentFrames"] = 1 << 62
        obj["audio"] = audio
        XCTAssertThrowsError(try Show.load(from: try JSONSerialization.data(withJSONObject: obj))) {
            XCTAssertEqual($0 as? MixerStateError, .alignmentFrames(1 << 62))
        }
    }

    // MARK: ③ 结构检查在 makeState 之前

    /// `Show.validateStructure()`：叠加恰好 4 个、转场槽 4 个或空（空的搬迁补齐）；`makeValidatedState()` = 结构检查 + makeState + validate，
    /// 合法节目的结果与 `makeState()` 相同。代码里能直接造出叠加 0 个的 `MixerSettings`（它的 init 没有断言），这种 Show 原来 makeState 就崩。
    func test034_validateStructure_beforeMakeState() throws {
        let good = Show(name: "好", state: MixerState.newShow(format: .hd1080p60))
        XCTAssertNoThrow(try good.validateStructure())
        XCTAssertEqual(try good.makeValidatedState(), good.makeState())
        for count in [0, 3, 5] {
            var bad = good
            bad.mixer.overlays = Array(repeating: OverlayState(), count: count)
            XCTAssertThrowsError(try bad.validateStructure(), "\(count)") { XCTAssertEqual($0 as? MixerStateError, .overlayCount(count)) }
            XCTAssertThrowsError(try bad.makeValidatedState(), "\(count)") { XCTAssertEqual($0 as? MixerStateError, .overlayCount(count)) }
        }
        var legacy = good
        legacy.mixer.transition.slots = []
        XCTAssertNoThrow(try legacy.validateStructure(), "空槽 = 020 之前的写法，搬迁补齐")
        XCTAssertEqual(try legacy.migratingLegacyKeys().makeValidatedState().transition.slots.count, 4)
        var three = good
        three.mixer.transition.slots.removeLast()
        XCTAssertThrowsError(try three.validateStructure()) { XCTAssertEqual($0 as? MixerStateError, .transitionSlotCount(3)) }
        var wide = good
        wide.mixer.format = ProgramFormat(width: 9000, height: 1080, frameRate: .fps60)
        XCTAssertNoThrow(try wide.validateStructure(), "结构检查只管个数，取值在 validate")
        XCTAssertThrowsError(try wide.makeValidatedState()) { XCTAssertEqual($0 as? MixerStateError, .format(wide.mixer.format)) }
    }

    // MARK: 护栏

    /// 仓库里带的节目（Samples/ 三份、scenarios/ 四份、契约测试的 g4 老节目）与 Codex 的 valid 对照：034 的范围都不让它们打不开。
    func test034_shippedShowsStillLoad() throws {
        let files = ["Samples/church/church.switcher.json", "Samples/classroom/classroom.switcher.json", "Samples/event/event.switcher.json",
                     "scenarios/m0-show.json", "scenarios/g3-show.json", "scenarios/g4-show.json", "scenarios/g4-ndi-show.json",
                     "Packages/SwitcherCore/Tests/SwitcherContractsTests/Fixtures/g4-show-before-p3.json",
                     "Packages/SwitcherCore/Tests/SwitcherContractsTests/Fixtures/audit-20261022/Audit20261022-valid.json"]
        for f in files {
            let show = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent(f)))
            let state = show.makeState()
            XCTAssertTrue(ProgramFormat.sizeRange.contains(state.format.width) && ProgramFormat.sizeRange.contains(state.format.height), f)
            XCTAssertTrue(FrameRate.programRange.contains(state.format.frameRate.framesPerSecond), f)
            XCTAssertTrue(state.inputs.allSatisfy { $0.source.rangeError(input: $0.number) == nil }, f)
            XCTAssertTrue(DurationLimits.tickRange.contains(state.transition.durationTicks) && DurationLimits.tickRange.contains(state.ftb.durationTicks), f)
        }
    }
}
