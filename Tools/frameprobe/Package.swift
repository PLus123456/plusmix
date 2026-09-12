// swift-tools-version: 6.0
// frameprobe：分析输出文件 / 流里的帧号、闪光、click（测试标准 §2.3）。W1-A 实现，P0 只打印版本。
import PackageDescription

let package = Package(
    name: "frameprobe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/SwitcherCore"),
        .package(path: "../../Packages/SwitcherTestKit"),
    ],
    targets: [
        .executableTarget(
            name: "frameprobe",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherTestKit", package: "SwitcherTestKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
