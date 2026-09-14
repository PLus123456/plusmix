// swift-tools-version: 6.0
// SwitcherOutputs：编码、录制、推流、NDI 发送、外部显示、虚拟摄像头桥
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
//
// target 归属（docs/OWNERSHIP.md）：
//   SwitcherOutputs          W1-E：VideoEncoder / AudioEncoder / Recorder / 喂料器
//   switcher-record-probe    W1-E：命令行录制器，E6 崩溃恢复测试的子进程，也用来生成 Tests/Fixtures/pattern.mov
//   Streaming / NDISend      W2-D 加；External / VirtualCamera / ISO  W3-C 加
import PackageDescription

let package = Package(
    name: "SwitcherOutputs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherOutputs", targets: ["SwitcherOutputs"]),
        .executable(name: "switcher-record-probe", targets: ["switcher-record-probe"]),
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
        .executableTarget(
            name: "switcher-record-probe",
            dependencies: [
                "SwitcherOutputs",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ]
        ),
        .testTarget(
            name: "SwitcherOutputsTests",
            // 依赖可执行 target 只是为了让 swift test 一并把它编出来（E6 要 spawn 它）
            dependencies: ["SwitcherOutputs", "switcher-record-probe"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
