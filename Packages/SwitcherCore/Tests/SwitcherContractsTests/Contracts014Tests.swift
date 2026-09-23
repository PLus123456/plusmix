import XCTest
@testable import SwitcherContracts

/// 提案 014（用户 2026-09-23 批，W2-A2 落地）：`InputSource.audio` / `.decklink` 的 `channels`（声道映射）。
/// 钉三件事：老文件缺键按 [] 解；空映射不写键（014 之前能表达的值编出来逐字节不变）；带映射的往返。
final class Contracts014Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    private func json(_ source: InputSource) throws -> String { String(decoding: try sortedEncoder.encode(source), as: UTF8.self) }
    private func decode(_ json: String) throws -> InputSource { try JSONDecoder().decode(InputSource.self, from: Data(json.utf8)) }

    // MARK: 老文件

    func test014_legacyJSONWithoutChannelsDecodesToEmptyMap() throws {
        XCTAssertEqual(try decode(#"{"audio":{"deviceUID":"BuiltInMicrophoneDevice"}}"#),
                       .audio(deviceUID: "BuiltInMicrophoneDevice", channels: []))
        XCTAssertEqual(try decode(#"{"decklink":{"deviceID":"peid:42"}}"#),
                       .decklink(deviceID: "peid:42", connection: nil, channels: []))
        XCTAssertEqual(try decode(#"{"decklink":{"connection":"sdi","deviceID":"peid:42"}}"#),
                       .decklink(deviceID: "peid:42", connection: .sdi, channels: []))
        // 构造时不写 channels = 默认 []，与解出来的相等（014 之前的调用点不用改）
        XCTAssertEqual(InputSource.audio(deviceUID: "x"), .audio(deviceUID: "x", channels: []))
        XCTAssertEqual(InputSource.decklink(deviceID: "y"), .decklink(deviceID: "y", connection: nil, channels: []))
    }

    // MARK: 空映射不写键

    func test014_emptyChannelsAreNotWritten_legacyShapeUnchanged() throws {
        XCTAssertEqual(try json(.audio(deviceUID: "uid")), #"{"audio":{"deviceUID":"uid"}}"#)
        XCTAssertEqual(try json(.decklink(deviceID: "peid:1")), #"{"decklink":{"deviceID":"peid:1"}}"#)
        XCTAssertEqual(try json(.decklink(deviceID: "peid:1", connection: .hdmi)), #"{"decklink":{"connection":"hdmi","deviceID":"peid:1"}}"#)
    }

    // MARK: 带映射的形态与往返

    func test014_channelsAreWrittenAndRoundTrip() throws {
        let audio = InputSource.audio(deviceUID: "AppleUSBAudioEngine:Focusrite:4", channels: [4, 5])
        XCTAssertEqual(try json(audio), #"{"audio":{"channels":[4,5],"deviceUID":"AppleUSBAudioEngine:Focusrite:4"}}"#)
        XCTAssertEqual(try decode(try json(audio)), audio)

        let mono = InputSource.audio(deviceUID: "u", channels: [4])
        XCTAssertEqual(try decode(try json(mono)), mono, "单项映射（单声道话筒）原样往返，不在契约层展开")

        let dl = InputSource.decklink(deviceID: "peid:7", connection: .sdi, channels: [2, 3])
        XCTAssertEqual(try json(dl), #"{"decklink":{"channels":[2,3],"connection":"sdi","deviceID":"peid:7"}}"#)
        XCTAssertEqual(try decode(try json(dl)), dl)

        let dlNoConnection = InputSource.decklink(deviceID: "peid:7", channels: [8, 9])
        XCTAssertEqual(try json(dlNoConnection), #"{"decklink":{"channels":[8,9],"deviceID":"peid:7"}}"#)
        XCTAssertEqual(try decode(try json(dlNoConnection)), dlNoConnection)

        // 显式的空数组 / null 都按"取前几路"解
        XCTAssertEqual(try decode(#"{"audio":{"channels":[],"deviceUID":"u"}}"#), .audio(deviceUID: "u"))
        XCTAssertEqual(try decode(#"{"audio":{"channels":null,"deviceUID":"u"}}"#), .audio(deviceUID: "u"))
        // kind 不受影响
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(dl.kind, .decklink)
    }

    // MARK: 其它 case 的形态一个字节不变（014 把 Codable 改成了一个镜像枚举，逐个 case 再钉一遍）

    func test014_otherCasesShapeUnchanged() throws {
        let cases: [(InputSource, String)] = [
            (.camera(uniqueID: "0x1234"), #"{"camera":{"uniqueID":"0x1234"}}"#),
            (.screen(target: .window(id: 9), frameRate: nil, captureAudio: false), #"{"screen":{"captureAudio":false,"target":{"window":{"id":9}}}}"#),
            (.screen(target: .application(bundleID: "com.example"), frameRate: .fps60, captureAudio: true),
             #"{"screen":{"captureAudio":true,"frameRate":{"denominator":1,"numerator":60},"target":{"application":{"bundleID":"com.example"}}}}"#),
            (.file(path: "/a.mov", endAction: .holdLastFrame, rate: 0.5), #"{"file":{"endAction":"holdLastFrame","path":"/a.mov","rate":0.5}}"#),
            (.image(path: "/a.png"), #"{"image":{"path":"/a.png"}}"#),
            (.ndi(sourceName: "A (B)"), #"{"ndi":{"bandwidth":"highest","jitterBufferFrames":1,"sourceName":"A (B)"}}"#),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(try json(source), expected)
            XCTAssertEqual(try decode(expected), source)
        }
        let synthetic = InputSource.synthetic(settings: SyntheticSourceSettings(frameRate: .fps5994, patternID: 3, audio: false))
        XCTAssertEqual(try decode(try json(synthetic)), synthetic)
        // 多键 / 未知键的对象仍然抛错
        XCTAssertThrowsError(try decode(#"{"nope":{}}"#))
        XCTAssertThrowsError(try decode(#"{"audio":{"channels":[1]}}"#), "deviceUID 是必填")
    }

    // MARK: 放在节目文件里

    func test014_showWithChannelMapsRoundTrips() throws {
        let inputs = [
            InputConfig(number: 1, name: "话筒 5/6", source: .audio(deviceUID: "usb:interface", channels: [4, 5])),
            InputConfig(number: 2, name: "SDI 3/4", source: .decklink(deviceID: "peid:1", connection: .sdi, channels: [2, 3])),
            InputConfig(number: 3, name: "默认", source: .audio(deviceUID: "")),
        ]
        let show = Show(name: "014", state: MixerState(format: .hd1080p60, inputs: inputs, program: 1, preview: 2))
        let data = try show.save()
        let back = try Show.load(from: data)
        XCTAssertEqual(back.inputs.map(\.source), inputs.map(\.source), "节目文件存取后声道映射不丢")
        let compact = String(decoding: try sortedEncoder.encode(show), as: UTF8.self)
        XCTAssertTrue(compact.contains(#""channels":[4,5]"#), compact)
        XCTAssertTrue(compact.contains(#""channels":[2,3]"#), compact)
        XCTAssertTrue(compact.contains(#"{"audio":{"deviceUID":""}}"#), "默认映射不写键：\(compact)")
    }
}
