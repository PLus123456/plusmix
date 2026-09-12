// swift-tools-version: 6.0
// switcher-headless：命令行跑引擎（无界面模式，测试标准 §2.4）。G2 接线，P0 只打印版本。
import PackageDescription

let package = Package(
    name: "switcher-headless",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/SwitcherCore"),
        .package(path: "../../Packages/SwitcherTestKit"),
    ],
    targets: [
        .executableTarget(
            name: "switcher-headless",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "SwitcherTestKit", package: "SwitcherTestKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
