import XCTest
import SwitcherContracts
import SwitcherTestKit
@testable import Switcher

/// P0 占位测试：App target 能链接全部本地包，并作为测试宿主真正启动（delegate 生效、主窗口已建）。
/// W2-B 用 UI 冒烟测试替换。
final class SkeletonTests: XCTestCase {
    @MainActor
    func testP0_skeleton_appLaunchesAndLinksPackages() {
        let app = NSApplication.shared
        XCTAssertNotNil(app.delegate as? AppDelegate, "main.swift 应把 AppDelegate 挂到 NSApplication 上")
        XCTAssertTrue(app.windows.contains { $0.title.hasPrefix("Switcher") }, "applicationDidFinishLaunching 应已建主窗口")
        XCTAssertEqual(SwitcherTestKitSkeleton.contractsVersion, SwitcherVersion.current)
    }
}
