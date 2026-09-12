// swift-tools-version: 6.0
// SwitcherOutputs：编码、录制、推流、NDI 发送、外部显示、虚拟摄像头桥
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
import PackageDescription

let package = Package(
    name: "SwitcherOutputs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherOutputs", targets: ["SwitcherOutputs"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
    ],
    targets: [
        .target(
            name: "SwitcherOutputs",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ]
        ),
        .testTarget(
            name: "SwitcherOutputsTests",
            dependencies: ["SwitcherOutputs"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
