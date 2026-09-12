import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// P0 占位测试。W1-B 用带测试 ID 的真实测试替换（testV2_…、testV3_…、testV5_…）。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_linksContracts() {
        XCTAssertEqual(SwitcherEngineSkeleton.contractsVersion, SwitcherVersion.current)
    }
}
