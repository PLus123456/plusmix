import XCTest
@testable import SwitcherContracts

/// 提案 016（用户 2026-09-23 批，W3-E2 落地）：`Command.setTransitionParams(wipe:stinger:)`。
/// 钉三件事：JSON 形态（HTTP API 的 wire format）；提案正文里的样例能解、往返不变；只加命令不动字段，老命令 / 老状态的形态逐字节不变。
final class Contracts016Tests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    private func json(_ c: Command) throws -> String { String(decoding: try sortedEncoder.encode(c), as: UTF8.self) }

    func test016_setTransitionParams_jsonShape() throws {
        XCTAssertEqual(try json(.setTransitionParams(wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams(input: 9, cutAtTick: 12))),
                       #"{"setTransitionParams":{"stinger":{"cutAtTick":12,"input":9},"wipe":{"direction":"topToBottom","softness":0.2}}}"#)
        // stinger 没设输入：不写 input 键（与 TransitionState.stinger 在节目文件里的编法一样）
        XCTAssertEqual(try json(.setTransitionParams(wipe: WipeParams(), stinger: StingerParams())),
                       #"{"setTransitionParams":{"stinger":{"cutAtTick":0},"wipe":{"direction":"leftToRight","softness":0}}}"#)
    }

    func test016_proposalExampleDecodes_andRoundTrips() throws {
        let example = #"{"setTransitionParams":{"wipe":{"direction":"topToBottom","softness":0.2},"stinger":{"input":9,"cutAtTick":12}}}"#
        let decoded = try JSONDecoder().decode(Command.self, from: Data(example.utf8))
        XCTAssertEqual(decoded, .setTransitionParams(wipe: WipeParams(direction: .topToBottom, softness: 0.2), stinger: StingerParams(input: 9, cutAtTick: 12)))
        let samples: [Command] = [decoded,
                                  .setTransitionParams(wipe: WipeParams(direction: .diagonal, softness: 1), stinger: StingerParams(input: nil, cutAtTick: 90))]
        for c in samples {
            XCTAssertEqual(try JSONDecoder().decode(Command.self, from: try JSONEncoder().encode(c)), c)
        }
        // 缺 input 键 = nil
        let noInput = #"{"setTransitionParams":{"wipe":{"direction":"diagonal","softness":0},"stinger":{"cutAtTick":3}}}"#
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: Data(noInput.utf8)),
                       .setTransitionParams(wipe: WipeParams(direction: .diagonal, softness: 0), stinger: StingerParams(input: nil, cutAtTick: 3)))
    }

    /// 只加命令、不加字段：setTransition 与节目文件里的 transition 一个字节不变，Show.schemaVersion 不升。
    func test016_existingShapesUnchanged() throws {
        XCTAssertEqual(try json(.setTransition(type: .wipe, durationTicks: 20)), #"{"setTransition":{"durationTicks":20,"type":"wipe"}}"#)
        let t = TransitionState(type: .stinger, durationTicks: 40, wipe: WipeParams(direction: .rightToLeft, softness: 0.1), stinger: StingerParams(input: 3, cutAtTick: 12))
        XCTAssertEqual(String(decoding: try sortedEncoder.encode(t), as: UTF8.self),
                       #"{"durationTicks":40,"progress":0,"source":"auto","stinger":{"cutAtTick":12,"input":3},"type":"stinger","wipe":{"direction":"rightToLeft","softness":0.1}}"#)
        XCTAssertEqual(Show.currentSchemaVersion, 1)
    }
}
