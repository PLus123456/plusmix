import XCTest
@testable import SwitcherTestKit
import SwitcherContracts

/// P0 占位测试。W1-A 用带测试 ID 的真实测试替换（图案往返、click 检测、合成源自测……）。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_linksAllLowerPackages() {
        XCTAssertEqual(SwitcherTestKitSkeleton.linkedVersions.count, 6)
        XCTAssertTrue(SwitcherTestKitSkeleton.linkedVersions.allSatisfy { $0 == SwitcherVersion.current })
    }
}
