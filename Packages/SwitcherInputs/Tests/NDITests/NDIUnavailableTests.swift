import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
@testable import SwitcherNDI

/// 编译时没有 NDI SDK 时的行为：不崩、文案清楚、start 抛错。有 SDK 时这些用例跳过。
final class NDIUnavailableTests: XCTestCase {
    func testNDI_withoutSDK_startThrowsAndStateIsErrorWithClearMessage() throws {
        if SwitcherNDIInfo.isSDKAvailable { throw XCTSkip("本机有 NDI SDK，走回环测试") }
        let timing = ProgramTiming(format: .hd1080p60, t0: HostClock.now())
        let input = NDIInput(number: 1, name: "NDI", sourceName: "X (Y)", timing: timing, videoSlot: LockFreeFrameSlot(capacity: 3))
        XCTAssertEqual(input.state, .noSignal)
        XCTAssertThrowsError(try input.start()) { XCTAssertEqual($0 as? NDIInputError, .sdkUnavailable) }
        XCTAssertEqual(input.state, .error(message: SwitcherNDIInfo.unavailableMessage))
        XCTAssertTrue(SwitcherNDIInfo.unavailableMessage.contains("NDI SDK"))
        XCTAssertThrowsError(try NDIFinder()) { XCTAssertEqual($0 as? NDIInputError, .sdkUnavailable) }
        input.stop()
        XCTAssertEqual(input.state, .noSignal)
        XCTAssertEqual(SwitcherNDIInfo.sdkVersion, "")
    }

    func testNDI_sourceKindMismatch_throws() throws {
        let timing = ProgramTiming(format: .hd1080p60, t0: HostClock.now())
        let config = InputConfig(number: 2, name: "x", source: .image(path: "/tmp/x.png"))
        XCTAssertThrowsError(try NDIInput(config: config, timing: timing, videoSlot: LockFreeFrameSlot(capacity: 3))) {
            XCTAssertEqual($0 as? NDIInputError, .notAnNDISource(.image))
        }
    }
}
