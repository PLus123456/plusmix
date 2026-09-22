import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
@testable import SwitcherDeckLink

/// 提案 008：`InputSource.decklink(deviceID:connection:)` 的值填进 `DeckLinkInput.Options`。
/// 不需要硬件也不需要 SDK：只看构造出来的 Options 与 deviceID（找设备要等 start）。
final class DeckLinkSourceParametersTests: XCTestCase {
    private func timing() -> ProgramTiming { ProgramTiming(format: .hd1080p60, t0: HostClock.now()) }

    private func make(_ source: InputSource, options: DeckLinkInput.Options = DeckLinkInput.Options()) throws -> DeckLinkInput {
        try DeckLinkInput(config: InputConfig(number: 1, name: "SDI", source: source), timing: timing(),
                          videoSlot: LockFreeFrameSlot(capacity: 3), audioRing: nil, options: options)
    }

    /// case 里的接口填进 Options；deviceID 原样带过去。
    func testP3_008_deckLinkOptionsComeFromInputSource() throws {
        let input = try make(.decklink(deviceID: "peid:1234567890", connection: .hdmi))
        XCTAssertEqual(input.deviceID, "peid:1234567890")
        XCTAssertEqual(input.options.connection, .hdmi)

        for c in DeckLinkConnection.allCases {
            XCTAssertEqual(try make(.decklink(deviceID: "", connection: c)).options.connection, c)
        }
    }

    /// 老节目文件（缺 connection）→ nil = 不改卡上的当前设置。
    func testP3_008_deckLinkLegacySourceLeavesConnectionNil() throws {
        let decoded = try JSONDecoder().decode(InputSource.self, from: Data(#"{"decklink":{"deviceID":"model:Mini Recorder#0"}}"#.utf8))
        let input = try make(decoded)
        XCTAssertEqual(input.deviceID, "model:Mini Recorder#0")
        XCTAssertNil(input.options.connection)
    }

    /// Options 里显式给的（非 nil）盖过 case。
    func testP3_008_explicitOptionsOverrideInputSource() throws {
        var o = DeckLinkInput.Options()
        o.connection = .sdi
        let input = try make(.decklink(deviceID: "peid:1", connection: .composite), options: o)
        XCTAssertEqual(input.options.connection, .sdi, "Options 非 nil = 显式给了，以它为准")
        XCTAssertEqual(input.options.audioChannels, DeckLinkInput.Options().audioChannels, "其它项不受影响")
    }

    /// 契约的单个口 ↔ 包里的位集（一台卡支持哪几个口）。
    func testP3_008_connectionBitsetConversion() {
        for c in SwitcherContracts.DeckLinkConnection.allCases {
            let bits = SwitcherDeckLink.DeckLinkConnection(c)
            XCTAssertEqual(bits.supported, [c], "\(c) 应只对应一位")
        }
        let both: SwitcherDeckLink.DeckLinkConnection = [.sdi, .hdmi]
        XCTAssertEqual(both.supported, [.sdi, .hdmi])
        XCTAssertEqual(SwitcherDeckLink.DeckLinkConnection([]).supported, [])
    }

    /// kind 不符仍然抛错。
    func testP3_008_nonDeckLinkSourceStillThrows() {
        XCTAssertThrowsError(try make(.image(path: "/tmp/x.png"))) {
            XCTAssertEqual($0 as? DeckLinkInputError, .notADeckLinkSource(.image))
        }
    }
}
