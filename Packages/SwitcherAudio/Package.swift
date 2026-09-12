// swift-tools-version: 6.0
// SwitcherAudio：混音循环（C 热路径）、重采样、效果链、表、设备层
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
import PackageDescription

let package = Package(
    name: "SwitcherAudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherAudio", targets: ["SwitcherAudio"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
    ],
    targets: [
        .target(
            name: "SwitcherAudio",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ]
        ),
        .testTarget(
            name: "SwitcherAudioTests",
            dependencies: ["SwitcherAudio"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
