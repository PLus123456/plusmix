// swift-tools-version: 6.0
// switcher-headless：命令行跑引擎（无界面模式，测试标准 §2.4）。
// G2 接线：Engine + MetalRenderer + SyntheticVideoInput × N + 合成音频 + 混音（空设备）+ VideoEncoder / Recorder + StatsWriter。
// W2-C：--api 起 SwitcherControl 的 CommandBus + StateFeed + APIServer（C 系列测试不依赖 App）。
// G3：音频换用 W2-E 的 SwitcherAudioIntegration.AudioEngine（对齐延迟 / AFV / 消费者泵 / 真设备重采样），--iso-audio 起 ISO 音轨录制器（A4）。
// G4：接图片输入（Stinger 的 alpha 图层）、NDI 输入 + NDI 发送（回环 L1）、W3-D 的兼容层 / tally（--compat / --tally-port，C5）。
// W4-A：只加参数——--stream（W2-D 的 StreamOutput 推到本地 MediaMTX）、节目里的摄像头 / 文件输入、make-show / make-scenario 的 soak / perf-e4 预设（长稳与 L5 基线）。
// 依赖方向：Tools 在最外层，可以依赖所有包（scripts/check-deps.sh）。
import PackageDescription

let package = Package(
    name: "switcher-headless",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/SwitcherCore"),
        .package(path: "../../Packages/SwitcherInputs"),
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
                .product(name: "SwitcherAudioIntegration", package: "SwitcherAudio"),
                .product(name: "SwitcherInputs", package: "SwitcherInputs"),
                .product(name: "SwitcherNDI", package: "SwitcherInputs"),
                .product(name: "SwitcherOutputs", package: "SwitcherOutputs"),
                .product(name: "SwitcherNDISend", package: "SwitcherOutputs"),
                .product(name: "SwitcherStreaming", package: "SwitcherOutputs"),
                .product(name: "SwitcherControl", package: "SwitcherControl"),
                .product(name: "SwitcherTally", package: "SwitcherControl"),
                .product(name: "VMixCompat", package: "SwitcherControl"),
                .product(name: "SwitcherTestKit", package: "SwitcherTestKit"),
            ]
        ),
        // W4-A：soak / perf-e4 预设的用例（make test 不跑工具的用例，改预设时手跑：swift test --package-path Tools/switcher-headless）
        .testTarget(
            name: "switcher-headlessTests",
            dependencies: [
                "switcher-headless",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
