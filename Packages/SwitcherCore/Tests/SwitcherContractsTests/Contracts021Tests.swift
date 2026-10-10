import Foundation
import XCTest
@testable import SwitcherContracts

/// 提案 021（用户 2026-10-11 批，P5-2 落地）：文件输入的播放控制——`InputSettings.playback: PlaybackSettings{paused, restartOnProgram, seekSeconds?, seekTick?}`
///（后两个是瞬态，`resetTransientState` 清；缺键 = 默认；写出写全、nil 不写键）+ 命令 `setPlayback(input:paused:)` / `seekPlayback(input:seconds:)`。
/// "设循环"不加命令（走 setInputSource）。reducer 规则见 ReducerTests.test021_*。
final class Contracts021Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    private func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try sortedEncoder.encode(v), as: UTF8.self) }
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func test021_playbackSettings_defaultsJsonShapeMissingKeysAndClamp() throws {
        XCTAssertEqual(PlaybackSettings.jsonKeys, ["paused", "restartOnProgram", "seekSeconds", "seekTick"])
        XCTAssertEqual(InputSettings.jsonKeys, ["crop", "transform", "audio", "effects", "keyer", "playback"])
        let d = PlaybackSettings()
        XCTAssertFalse(d.paused); XCTAssertFalse(d.restartOnProgram); XCTAssertNil(d.seekSeconds); XCTAssertNil(d.seekTick)
        XCTAssertEqual(InputSettings().playback, d)
        XCTAssertEqual(try json(d), #"{"paused":false,"restartOnProgram":false}"#, "目标值总是写，瞬态 nil 不写键")
        let p = PlaybackSettings(paused: true, restartOnProgram: true, seekSeconds: 12.5, seekTick: Tick(900))
        XCTAssertEqual(try json(p), #"{"paused":true,"restartOnProgram":true,"seekSeconds":12.5,"seekTick":900}"#)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: try sortedEncoder.encode(p)), p)
        // 缺键 = 默认：空对象、以及 021 之前的 InputSettings（没有 playback 键）
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8)), d)
        let oldSettings = try json(InputSettings()).replacingOccurrences(of: #","playback":{"paused":false,"restartOnProgram":false}"#, with: "")
        XCTAssertFalse(oldSettings.contains("playback"))
        XCTAssertEqual(try JSONDecoder().decode(InputSettings.self, from: Data(oldSettings.utf8)), InputSettings())
        // 写出写全：InputSettings 的键集合 = jsonKeys
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(InputSettings())) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), Set(InputSettings.jsonKeys))
        // clamped：seekSeconds 钳 ≥ 0，nil 不动
        var s = InputSettings()
        s.playback.seekSeconds = -5
        XCTAssertEqual(s.clamped().playback.seekSeconds, 0)
        s.playback.seekSeconds = 3.5
        XCTAssertEqual(s.clamped().playback.seekSeconds, 3.5)
        s.playback.seekSeconds = nil
        XCTAssertNil(s.clamped().playback.seekSeconds)
        XCTAssertEqual(InputSettings().clamped(), InputSettings())
    }

    func test021_seekIsTransient_resetTransientStateClearsIt_targetsStay() throws {
        var s = MixerState(format: .hd1080p60)
        s.inputs = [InputConfig(number: 1, name: "片头", source: .file(path: "/a.mov", endAction: .loop, rate: 1)),
                    InputConfig(number: 2, name: "机位", source: .image(path: "/b.png"))]
        s.inputs[0].settings.playback = PlaybackSettings(paused: true, restartOnProgram: true, seekSeconds: 0, seekTick: Tick(10))
        s.inputs[1].settings.playback.seekSeconds = 2   // 别的 kind 照存不读，同样清
        s.resetTransientState()
        XCTAssertEqual(s.inputs[0].settings.playback, PlaybackSettings(paused: true, restartOnProgram: true))
        XCTAssertNil(s.inputs[1].settings.playback.seekSeconds)
        // 载入节目（makeState）同样清
        var again = s
        again.inputs[0].settings.playback.seekTick = Tick(5)
        again.inputs[0].settings.playback.seekSeconds = 7
        XCTAssertNil(Show(name: "x", state: again).makeState().inputs[0].settings.playback.seekTick)
        // 老场景节目照读：每路 playback 默认
        for name in ["scenarios/g3-show.json", "scenarios/g4-show.json", "scenarios/m0-show.json"] {
            let show = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent(name)))
            XCTAssertTrue(show.inputs.allSatisfy { $0.settings.playback == PlaybackSettings() }, name)
            XCTAssertEqual(try Show.load(from: try show.save()), show, name)
        }
    }

    func test021_commands_jsonShape() throws {
        XCTAssertEqual(try json(Command.setPlayback(input: 3, paused: true)), #"{"setPlayback":{"input":3,"paused":true}}"#)
        XCTAssertEqual(try json(Command.seekPlayback(input: 3, seconds: 12.5)), #"{"seekPlayback":{"input":3,"seconds":12.5}}"#)
        XCTAssertEqual(try json(Command.seekPlayback(input: 3, seconds: 0)), #"{"seekPlayback":{"input":3,"seconds":0}}"#, "从头播 = 定位 0")
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"setPlayback":{"input":3,"paused":false}}"#.utf8)), .setPlayback(input: 3, paused: false))
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(#"{"seekPlayback":{"input":3,"seconds":4}}"#.utf8)), .seekPlayback(input: 3, seconds: 4))
    }
}
