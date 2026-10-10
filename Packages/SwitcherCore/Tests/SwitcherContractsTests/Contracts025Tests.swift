import Foundation
import XCTest
@testable import SwitcherContracts

/// 提案 025（用户 2026-10-10 批，P5 落契约）：W5-I 的三个 App 层标记升正式字段——
/// `RecordSettings.armed`（缺键 true）/ `RecordSettings.ownFormat`（缺键 false）/ `StreamSettings.followFirst`（缺键 false）；写出总是写全；
/// 旧的 `OutputSettings.extra["app.record.armed"]` 等三个键由 `OutputSettings.migratingLegacyAppFlags()` 搬（App 在 Show.load 后调一次，归 101）。
final class Contracts025Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func test025_recordAndStreamFlags_defaultsRoundTripMissingKeysAndWriteAll() throws {
        XCTAssertEqual(RecordSettings.jsonKeys, ["directory", "fileNamePattern", "container", "fragmentIntervalSeconds", "remuxToMP4", "armed", "ownFormat"])
        XCTAssertEqual(StreamSettings.jsonKeys, ["url", "streamKey", "reconnectMaxSeconds", "followFirst"])
        // 默认值 = W5-I 的缺键语义：参与录制、跟主录制格式、不跟第一个目的地
        let r = RecordSettings(directory: "/tmp")
        XCTAssertTrue(r.armed)
        XCTAssertFalse(r.ownFormat)
        XCTAssertFalse(StreamSettings(url: "rtmp://x/y").followFirst)
        // 非默认值往返
        let record = RecordSettings(directory: "/Movies", fileNamePattern: "{show}", container: .mov, fragmentIntervalSeconds: 2, remuxToMP4: true, armed: false, ownFormat: true)
        XCTAssertEqual(try JSONDecoder().decode(RecordSettings.self, from: try sortedEncoder.encode(record)), record)
        let stream = StreamSettings(url: "srt://h:9000", streamKey: "k", reconnectMaxSeconds: 10, followFirst: true)
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self, from: try sortedEncoder.encode(stream)), stream)
        XCTAssertEqual(String(decoding: try sortedEncoder.encode(stream), as: UTF8.self),
                       #"{"followFirst":true,"reconnectMaxSeconds":10,"streamKey":"k","url":"srt://h:9000"}"#)
        // 025 之前的文件缺键 → 默认值
        let oldRecord = try JSONDecoder().decode(RecordSettings.self, from: Data(#"{"container":"mov","directory":"/a","fileNamePattern":"{show}-{date}-{time}","fragmentIntervalSeconds":1,"remuxToMP4":false}"#.utf8))
        XCTAssertEqual(oldRecord, RecordSettings(directory: "/a"))
        XCTAssertTrue(oldRecord.armed)
        XCTAssertFalse(oldRecord.ownFormat)
        let oldStream = try JSONDecoder().decode(StreamSettings.self, from: Data(#"{"reconnectMaxSeconds":30,"streamKey":"","url":"rtmp://a/b"}"#.utf8))
        XCTAssertEqual(oldStream, StreamSettings(url: "rtmp://a/b"))
        XCTAssertFalse(oldStream.followFirst)
        // 写出总是写全（默认值也写）
        let recordKeys = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(oldRecord)) as? [String: Any]).keys
        XCTAssertEqual(Set(recordKeys), Set(RecordSettings.jsonKeys))
        let streamKeys = try XCTUnwrap(try JSONSerialization.jsonObject(with: try sortedEncoder.encode(oldStream)) as? [String: Any]).keys
        XCTAssertEqual(Set(streamKeys), Set(StreamSettings.jsonKeys))
    }

    /// 老节目文件（G3 / G4 的场景节目，025 之前写的）照读：录制输出 armed = true、ownFormat = false。
    func test025_legacyScenarioShowsDecodeWithDefaults() throws {
        for name in ["scenarios/g3-show.json", "scenarios/g4-show.json", "scenarios/m0-show.json"] {
            let show = try Show.load(from: try Data(contentsOf: Self.repoRoot.appendingPathComponent(name)))
            let records = show.outputs.filter { $0.kind == .record }
            XCTAssertFalse(records.isEmpty, name)
            for o in records {
                XCTAssertEqual(o.settings.record?.armed, true, "\(name) 输出 \(o.number)")
                XCTAssertEqual(o.settings.record?.ownFormat, false, "\(name) 输出 \(o.number)")
            }
            for o in show.outputs where o.kind == .stream {
                XCTAssertEqual(o.settings.stream?.followFirst, false, "\(name) 输出 \(o.number)")
            }
            // 再写出、再读回不变
            XCTAssertEqual(try Show.load(from: try show.save()), show, name)
        }
    }

    /// W5-I 放在 extra 里的三个键搬进字段：有键按键的原值走、搬完删键；没键不动；别的 extra 键原样；幂等。
    func test025_migratingLegacyAppFlags_movesExtraKeysIntoFields() throws {
        XCTAssertEqual(RecordSettings.legacyArmedExtraKey, "app.record.armed")
        XCTAssertEqual(RecordSettings.legacyOwnFormatExtraKey, "app.record.ownFormat")
        XCTAssertEqual(StreamSettings.legacyFollowFirstExtraKey, "app.stream.followFirst")

        let record = OutputSettings(source: .input(number: 2), record: RecordSettings(directory: "/a"),
                                    extra: [RecordSettings.legacyArmedExtraKey: .bool(false), RecordSettings.legacyOwnFormatExtraKey: .bool(true), "ndi.groups": .string("x")])
        let migrated = record.migratingLegacyAppFlags()
        XCTAssertEqual(migrated.record?.armed, false)
        XCTAssertEqual(migrated.record?.ownFormat, true)
        XCTAssertEqual(migrated.extra, ["ndi.groups": .string("x")], "三个旧键清掉，别的 extra 键原样")
        XCTAssertEqual(migrated.migratingLegacyAppFlags(), migrated, "幂等")

        let stream = OutputSettings(stream: StreamSettings(url: "rtmp://a/b"), extra: [StreamSettings.legacyFollowFirstExtraKey: .bool(true)])
        XCTAssertEqual(stream.migratingLegacyAppFlags().stream?.followFirst, true)
        XCTAssertTrue(stream.migratingLegacyAppFlags().extra.isEmpty)

        // 没有旧键：一个字节不动（字段保持已有的值）
        let plain = OutputSettings(record: RecordSettings(directory: "/a", armed: false), extra: ["k": .number(1)])
        XCTAssertEqual(plain.migratingLegacyAppFlags(), plain)
        // 旧键不是 bool / 子结构不在（录制键挂在推流输出上）：键清掉、字段不动
        let stray = OutputSettings(stream: StreamSettings(url: "rtmp://a/b"), extra: [RecordSettings.legacyArmedExtraKey: .bool(false), StreamSettings.legacyFollowFirstExtraKey: .string("yes")])
        let cleaned = stray.migratingLegacyAppFlags()
        XCTAssertTrue(cleaned.extra.isEmpty)
        XCTAssertEqual(cleaned.stream, StreamSettings(url: "rtmp://a/b"))
        XCTAssertNil(cleaned.record)

        // 整份节目：Show 级的便捷入口对每个输出各做一次
        var state = MixerState(format: .hd1080p60)
        state.outputs = [OutputState(number: 1, kind: .record, name: "录制", settings: record),
                         OutputState(number: 2, kind: .stream, name: "推流", settings: stream)]
        let show = Show(name: "W5-I 存的", state: state).migratingLegacyAppFlags()
        XCTAssertEqual(show.outputs.map { $0.settings.record?.armed }, [false, nil])
        XCTAssertEqual(show.outputs.map { $0.settings.stream?.followFirst }, [nil, true])
        XCTAssertTrue(show.outputs.allSatisfy { !$0.settings.extra.keys.contains { $0.hasPrefix("app.") } })
        // Show.load / migratingLegacyKeys 不搬这三个键（App 在 Show.load 后调一次，归 101）：读回来旧键还在，字段是默认
        let loaded = try Show.load(from: try Show(name: "W5-I 存的", state: state).save())
        XCTAssertEqual(loaded.outputs[0].settings.extra[RecordSettings.legacyArmedExtraKey], .bool(false))
        XCTAssertEqual(loaded.outputs[0].settings.record?.armed, true)
    }
}
