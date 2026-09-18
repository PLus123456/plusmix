// swift-tools-version: 6.0
// SwitcherOutputs：编码、录制、推流、NDI 发送、外部显示、虚拟摄像头桥
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
//
// target 归属（docs/OWNERSHIP.md）：
//   SwitcherOutputs          W1-E：VideoEncoder / AudioEncoder / Recorder / 喂料器
//   switcher-record-probe    W1-E：命令行录制器，E6 崩溃恢复测试的子进程，也用来生成 Tests/Fixtures/pattern.mov
//   SwitcherStreaming        W2-D：StreamOutput（RTMP / RTMPS / SRT，HaishinKit 只当连接 + 封装层，编码是我们自己的）
//   SwitcherNDISend          W2-D：NDISender（NDI SDK 在时真发；不在时空实现，Stats 标 unavailable）
//   External / VirtualCamera / ISO  W3-C 加
import Foundation
import PackageDescription

// NDI SDK：默认装在 /Library/NDI SDK for Apple（NDI_SDK_DIR 可改）。头文件在就把系统库 target `NDI` 挂上，
// 源码里 `#if canImport(NDI)` 才为真；不在就完全不声明它（SwiftPM 没有"可选的系统库"，只能在清单里判断）。
let ndiSDKDir = ProcessInfo.processInfo.environment["NDI_SDK_DIR"] ?? "/Library/NDI SDK for Apple"
let ndiAvailable = FileManager.default.fileExists(atPath: ndiSDKDir + "/include/Processing.NDI.Lib.h")

var ndiSendDependencies: [Target.Dependency] = [
    "SwitcherOutputs",
    .product(name: "SwitcherContracts", package: "SwitcherCore"),
]
var ndiSendSwiftSettings: [SwiftSetting] = []
var ndiSendLinkerSettings: [LinkerSetting] = []
var extraTargets: [Target] = []
if ndiAvailable {
    ndiSendDependencies.append("NDI")
    // 系统库 target 只有 module.modulemap + shim 头；头文件搜索路径和链接路径在这里给（SDK 目录带空格，走 unsafeFlags）
    ndiSendSwiftSettings.append(.unsafeFlags(["-Xcc", "-I\(ndiSDKDir)/include"]))
    ndiSendLinkerSettings.append(.unsafeFlags(["-L\(ndiSDKDir)/lib/macOS", "-lndi", "-Xlinker", "-rpath", "-Xlinker", "\(ndiSDKDir)/lib/macOS"]))
    extraTargets.append(.systemLibrary(name: "NDI", path: "Sources/NDISend/CNDI"))
}

let package = Package(
    name: "SwitcherOutputs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherOutputs", targets: ["SwitcherOutputs"]),
        .library(name: "SwitcherStreaming", targets: ["SwitcherStreaming"]),
        .library(name: "SwitcherNDISend", targets: ["SwitcherNDISend"]),
        .executable(name: "switcher-record-probe", targets: ["switcher-record-probe"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
        // 推流协议 + 封装层（BSD-3）。libsrt（MPL-2.0）是它自带的二进制 xcframework。
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift.git", exact: "2.2.5"),
    ],
    targets: [
        .target(
            name: "SwitcherOutputs",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ]
        ),
        .target(
            name: "SwitcherStreaming",
            dependencies: [
                "SwitcherOutputs",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
                .product(name: "SRTHaishinKit", package: "HaishinKit.swift"),
            ],
            path: "Sources/Streaming"
        ),
        .target(
            name: "SwitcherNDISend",
            dependencies: ndiSendDependencies,
            path: "Sources/NDISend",
            exclude: ["CNDI"],
            swiftSettings: ndiSendSwiftSettings,
            linkerSettings: ndiSendLinkerSettings
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
        .testTarget(
            name: "StreamingTests",
            dependencies: ["SwitcherStreaming", "SwitcherOutputs", .product(name: "SwitcherContracts", package: "SwitcherCore")],
            path: "Tests/StreamingTests"
        ),
        .testTarget(
            name: "NDISendTests",
            dependencies: ["SwitcherNDISend", "SwitcherOutputs", .product(name: "SwitcherContracts", package: "SwitcherCore")],
            path: "Tests/NDISendTests"
        ),
    ] + extraTargets,
    swiftLanguageModes: [.v6]
)
