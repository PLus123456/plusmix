// swift-tools-version: 6.0
// SwitcherInputs：各输入实现（摄像头 / UVC、屏幕、文件、图片；DeckLink、NDI 各自独立可选 target，W3-A 加）
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
//
// target 归属（docs/OWNERSHIP.md）：
//   SwitcherInputs          W2-A：CameraInput / ScreenInput / FileInput / ImageInput + 无信号 / 热插拔 / 权限（库只依赖契约）
//   switcher-input-probe    W2-A：命令行探针——设备清单、时间戳时钟探针、真引擎 + 真渲染器下量 L1、S5 热插拔计时、S6 权限观察。
//                           它是"组装方"，所以可以看 SwitcherEngine（帧槽、引擎）和 SwitcherRender（Metal 渲染器）。
//   DeckLink / NDI          W3-A 加
import PackageDescription

let package = Package(
    name: "SwitcherInputs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherInputs", targets: ["SwitcherInputs"]),
        .executable(name: "switcher-input-probe", targets: ["switcher-input-probe"]),
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
        .executableTarget(
            name: "switcher-input-probe",
            dependencies: [
                "SwitcherInputs",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "SwitcherRender", package: "SwitcherCore"),
            ]
        ),
        .testTarget(
            name: "SwitcherInputsTests",
            // 测试是组装方：真帧槽（SwitcherEngine）和真渲染器（SwitcherRender）用来量 L1；依赖探针只是让 swift test 一并编出它
            dependencies: [
                "SwitcherInputs",
                "switcher-input-probe",
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "SwitcherRender", package: "SwitcherCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
