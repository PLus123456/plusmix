import XCTest
@testable import SwitcherAudio
import SwitcherContracts

/// P0 占位测试。W1-D / W2-E 用带测试 ID 的真实测试替换。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_linksContracts() {
        XCTAssertEqual(SwitcherAudioSkeleton.contractsVersion, SwitcherVersion.current)
    }
}
