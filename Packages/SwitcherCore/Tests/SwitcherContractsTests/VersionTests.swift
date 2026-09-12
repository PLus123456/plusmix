import XCTest
@testable import SwitcherContracts

final class VersionTests: XCTestCase {
    func testP1_versionIsSemver() {
        let parts = SwitcherVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "版本号应为 major.minor.patch")
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil }, "版本号每段应为整数")
    }
}
