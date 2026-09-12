// swift-tools-version: 6.0
// SwitcherControl：命令总线、HTTP / WS API、快捷键、MIDI、Tally；VMixCompat 独立 target 默认关
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
import PackageDescription

let package = Package(
    name: "SwitcherControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherControl", targets: ["SwitcherControl"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
    ],
    targets: [
        .target(
            name: "SwitcherControl",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ]
        ),
        .testTarget(
            name: "SwitcherControlTests",
            dependencies: ["SwitcherControl"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
