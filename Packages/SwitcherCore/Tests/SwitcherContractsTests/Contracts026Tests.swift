import Foundation
import XCTest
@testable import SwitcherContracts

/// 提案 026（用户 2026-10-10 批，P5 落契约）：耳机 / 监听总线上听哪条总线进状态——`AudioState.monitorSource: Bus`（缺键 master）+ 命令 `setMonitorSource(bus:)`
///（Command 34 → 35 个 case）。用户 2026-10-12 允许 `headphones`（= 听耳机总线自己，P5-3 落地）：四条都合法、文件 / API 全量状态按字面读写（P5 的"读成 master"兜底去掉）。引擎侧归 102。
final class Contracts026Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func test026_audioStateMonitorSource_defaultRoundTripMissingKeyAndHeadphonesRoundTrip() throws {
        XCTAssertEqual(AudioState.jsonKeys, ["buses", "afv", "monitorMode", "alignmentFrames", "monitorPoint", "monitorSource"])
        XCTAssertEqual(AudioState().monitorSource, .master)
        var custom = AudioState()
        custom.monitorSource = .busB
        let data = try sortedEncoder.encode(custom)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""monitorSource":2"#), "JSON 形态 = Bus.rawValue，与 busGain 的 bus 一致")
        XCTAssertEqual(try JSONDecoder().decode(AudioState.self, from: data), custom)
        // 026 之前的快照 / 节目缺键 → master
        let old = #"{"afv":false,"alignmentFrames":2048,"buses":[{"bus":0,"effects":[],"gainDb":0,"muted":false},{"bus":1,"effects":[],"gainDb":0,"muted":false},{"bus":2,"effects":[],"gainDb":0,"muted":false},{"bus":3,"effects":[],"gainDb":0,"muted":false}],"monitorMode":"afl","monitorPoint":"preDelayLine"}"#
        let back = try JSONDecoder().decode(AudioState.self, from: Data(old.utf8))
        XCTAssertEqual(back.monitorSource, .master)
        XCTAssertEqual(back, AudioState())
        // 写出总是写全
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(back)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), Set(AudioState.jsonKeys))
        // headphones（3）= 听耳机总线自己（用户 2026-10-12 允许，P5-3）：按字面读、按字面写，不再读成 master
        let headphones = try JSONDecoder().decode(AudioState.self, from: Data(old.replacingOccurrences(of: #""monitorPoint":"preDelayLine""#, with: #""monitorPoint":"preDelayLine","monitorSource":3"#).utf8))
        XCTAssertEqual(headphones.monitorSource, .headphones)
        var ownBus = AudioState()
        ownBus.monitorSource = .headphones
        let ownBusData = try sortedEncoder.encode(ownBus)
        XCTAssertTrue(String(decoding: ownBusData, as: UTF8.self).contains(#""monitorSource":3"#))
        XCTAssertEqual(try JSONDecoder().decode(AudioState.self, from: ownBusData), ownBus)
        var ownBusState = MixerState()
        ownBusState.audio.monitorSource = .headphones
        let ownBusShow = Show(name: "监听耳机总线", state: ownBusState)
        XCTAssertEqual(try Show.load(from: try ownBusShow.save()).audio.monitorSource, .headphones, "节目文件里也按字面往返")
        // 认不出的值（不是 0–3）照 Bus 的解码规则报错，与别处一致
        XCTAssertThrowsError(try JSONDecoder().decode(AudioState.self, from: Data(old.replacingOccurrences(of: #""monitorPoint":"preDelayLine""#, with: #""monitorPoint":"preDelayLine","monitorSource":9"#).utf8)))
        // 老场景节目照读
        for name in ["scenarios/g3-show.json", "scenarios/g4-show.json"] {
            let show = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent(name)))
            XCTAssertEqual(show.audio.monitorSource, .master, name)
            XCTAssertEqual(try Show.load(from: try show.save()), show, name)
        }
    }

    func test026_setMonitorSourceCommand_jsonShapeAndCaseCount() throws {
        XCTAssertEqual(Samples.commandCaseCount, 42, "026 加 setMonitorSource：34 → 35；P5-2 的 020 / 021 / 023 → 42")
        XCTAssertEqual(Set(Samples.commands().map(Samples.caseName(of:))).count, 42)
        let c = Command.setMonitorSource(bus: .busA)
        let data = try sortedEncoder.encode(c)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"setMonitorSource":{"bus":1}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: data), c)
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setMonitorSource":{"bus":0}}"#.utf8)), .setMonitorSource(bus: .master))
        // headphones（3）= 听耳机总线自己：P5-3 起合法（P5 时校验器 / reducer 拒），wire 形态不变
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setMonitorSource":{"bus":3}}"#.utf8)), .setMonitorSource(bus: .headphones))
        XCTAssertThrowsError(try JSONDecoder().decode(Command.self, from: Data(#"{"setMonitorSource":{"bus":4}}"#.utf8)))
    }
}
