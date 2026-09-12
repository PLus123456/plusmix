import XCTest
@testable import SwitcherControl
import SwitcherContracts

/// P0 占位测试。W2-C / W3-D 用带测试 ID 的真实测试替换。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_linksContracts() {
        XCTAssertEqual(SwitcherControlSkeleton.contractsVersion, SwitcherVersion.current)
    }
}
