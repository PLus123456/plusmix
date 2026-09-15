// swift-tools-version: 6.0
// switcher-headless：命令行跑引擎（无界面模式，测试标准 §2.4）。
// G2 接线：Engine + MetalRenderer + SyntheticVideoInput × N + 合成音频 + 混音（空设备）+ VideoEncoder / Recorder + StatsWriter。
// W2-C：--api 起 SwitcherControl 的 CommandBus + StateFeed + APIServer（C 系列测试不依赖 App）。
// 依赖方向：Tools 在最外层，可以依赖所有包（scripts/check-deps.sh）。
import PackageDescription

let package = Package(
    name: "switcher-headless",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/SwitcherCore"),
        .package(path: "../../Packages/SwitcherAudio"),
        .package(path: "../../Packages/SwitcherOutputs"),
        .package(path: "../../Packages/SwitcherControl"),
        .package(path: "../../Packages/SwitcherTestKit"),
    ],
    targets: [
        .executableTarget(
            name: "switcher-headless",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "SwitcherRender", package: "SwitcherCore"),
                .product(name: "SwitcherAudio", package: "SwitcherAudio"),
                .product(name: "SwitcherOutputs", package: "SwitcherOutputs"),
                .product(name: "SwitcherControl", package: "SwitcherControl"),
                .product(name: "SwitcherTestKit", package: "SwitcherTestKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
