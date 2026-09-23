import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
@testable import SwitcherNDI

/// 提案 008：`InputSource.ndi(sourceName:bandwidth:jitterBufferFrames:)` 的值填进 `NDIInput.Options`。
/// 不需要硬件也不需要 SDK：只看构造出来的 Options（起流才需要 SDK）。
final class NDISourceParametersTests: XCTestCase {
    private func timing() -> ProgramTiming { ProgramTiming(format: .hd1080p60, t0: HostClock.now()) }

    private func make(_ source: InputSource, options: NDIInput.Options = NDIInput.Options()) throws -> NDIInput {
        try NDIInput(config: InputConfig(number: 1, name: "远端", source: source), timing: timing(),
                     videoSlot: LockFreeFrameSlot(capacity: 3), audioRing: nil, options: options)
    }

    /// case 里的带宽 / 抖动缓冲填进 Options。
    func testP3_008_ndiOptionsComeFromInputSource() throws {
        let input = try make(.ndi(sourceName: "STUDIO (Cam A)", bandwidth: .lowest, jitterBufferFrames: 2))
        XCTAssertEqual(input.sourceName, "STUDIO (Cam A)")
        XCTAssertEqual(input.options.bandwidth, .lowest)
        XCTAssertEqual(input.options.jitterBufferFrames, 2)

        let zero = try make(.ndi(sourceName: "X (Y)", bandwidth: .audioOnly, jitterBufferFrames: 0))
        XCTAssertEqual(zero.options.bandwidth, .audioOnly)
        XCTAssertEqual(zero.options.jitterBufferFrames, 0)
    }

    /// 老节目文件（缺键）按契约默认解 → highest / 1，与加参数之前的行为相同。
    func testP3_008_ndiLegacySourceUsesDefaults() throws {
        let decoded = try JSONDecoder().decode(InputSource.self, from: Data(#"{"ndi":{"sourceName":"X (Y)"}}"#.utf8))
        let input = try make(decoded)
        XCTAssertEqual(input.options.bandwidth, .highest)
        XCTAssertEqual(input.options.jitterBufferFrames, 1)
    }

    /// Options 里显式给的（与默认不同）盖过 case：组装方要临时压低带宽 / 改缓冲时用。
    func testP3_008_explicitOptionsOverrideInputSource() throws {
        var o = NDIInput.Options()
        o.bandwidth = .highest
        o.jitterBufferFrames = 0
        let input = try make(.ndi(sourceName: "X (Y)", bandwidth: .lowest, jitterBufferFrames: 2), options: o)
        XCTAssertEqual(input.options.jitterBufferFrames, 0, "Options 与默认不同 = 显式给了，以它为准")
        XCTAssertEqual(input.options.bandwidth, .lowest, "Options 里是默认值 → 用 case 里的")
        // 其它 Options 项不受影响
        XCTAssertEqual(input.options.noSignalMultiplier, NDIInput.Options().noSignalMultiplier)
    }

    /// 两边的带宽枚举可互转（契约的 NDIBandwidth ↔ 包里的 Bandwidth）。
    func testP3_008_bandwidthConversionIsTotal() {
        for b in NDIBandwidth.allCases {
            XCTAssertEqual(NDIInput.Bandwidth(b).contractValue, b)
        }
        for b in NDIInput.Bandwidth.allCases {
            XCTAssertEqual(NDIInput.Bandwidth(b.contractValue), b)
        }
    }

    /// kind 不符仍然抛错。
    func testP3_008_nonNDISourceStillThrows() {
        XCTAssertThrowsError(try make(.image(path: "/tmp/x.png"))) {
            XCTAssertEqual($0 as? NDIInputError, .notAnNDISource(.image))
        }
    }
}
