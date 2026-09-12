// swift-tools-version: 6.0
// SwitcherInputs：各输入实现（摄像头 / UVC、屏幕、文件、图片、纯音频；DeckLink、NDI 各自独立可选 target）
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
import PackageDescription

let package = Package(
    name: "SwitcherInputs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherInputs", targets: ["SwitcherInputs"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
    ],
    targets: [
        .target(
            name: "SwitcherInputs",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ]
        ),
        .testTarget(
            name: "SwitcherInputsTests",
            dependencies: ["SwitcherInputs"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
