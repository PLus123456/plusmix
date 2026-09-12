import XCTest
@testable import SwitcherInputs
import SwitcherContracts

/// P0 占位测试。W2-A / W3-A 用带测试 ID 的真实测试替换。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_linksContracts() {
        XCTAssertEqual(SwitcherInputsSkeleton.contractsVersion, SwitcherVersion.current)
    }
}
