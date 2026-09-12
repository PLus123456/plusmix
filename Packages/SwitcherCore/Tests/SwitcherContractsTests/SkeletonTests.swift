import XCTest
@testable import SwitcherContracts

/// P0 占位测试。P1 用真正的契约测试替换（拍点数学、TestPattern 往返、Codable 快照……）。
final class SkeletonTests: XCTestCase {
    func testP0_skeleton_versionIsSemver() {
        let parts = SwitcherVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "版本号应为 major.minor.patch")
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil }, "版本号每段应为整数")
    }
}
