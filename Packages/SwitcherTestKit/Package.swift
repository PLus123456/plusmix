// swift-tools-version: 6.0
// SwitcherTestKit：合成测试源、帧号解码、指标采集（StatsWriter / StatsSummary）、场景脚本执行器（W1-A 填）。
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：可以依赖 SwitcherCore 和四个功能包；只有 Tools 和 App 能依赖它。
import PackageDescription

let package = Package(
    name: "SwitcherTestKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherTestKit", targets: ["SwitcherTestKit"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
        .package(path: "../SwitcherInputs"),
        .package(path: "../SwitcherAudio"),
        .package(path: "../SwitcherOutputs"),
        .package(path: "../SwitcherControl"),
    ],
    targets: [
        .target(
            name: "SwitcherTestKit",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "SwitcherRender", package: "SwitcherCore"),
                .product(name: "SwitcherInputs", package: "SwitcherInputs"),
                .product(name: "SwitcherAudio", package: "SwitcherAudio"),
                .product(name: "SwitcherOutputs", package: "SwitcherOutputs"),
                .product(name: "SwitcherControl", package: "SwitcherControl"),
            ]
        ),
        .testTarget(
            name: "SwitcherTestKitTests",
            dependencies: ["SwitcherTestKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
