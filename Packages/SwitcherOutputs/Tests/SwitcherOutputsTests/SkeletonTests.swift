import XCTest
@testable import SwitcherOutputs
import SwitcherContracts

/// P0 占位测试。W1-E / W2-D / W3-C 用带测试 ID 的真实测试替换。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_linksContracts() {
        XCTAssertEqual(SwitcherOutputsSkeleton.contractsVersion, SwitcherVersion.current)
    }
}
