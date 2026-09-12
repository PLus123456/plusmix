import XCTest
@testable import SwitcherRender
import SwitcherContracts

/// P0 占位测试。W1-C 用带测试 ID 的真实测试替换（testV1_…、testV8_…、testV9_…）。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_linksContracts() {
        XCTAssertEqual(SwitcherRenderSkeleton.contractsVersion, SwitcherVersion.current)
    }
}
