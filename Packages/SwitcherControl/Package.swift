// swift-tools-version: 6.0
// SwitcherControl：命令总线、HTTP / WS API、快捷键、MIDI、Tally；VMixCompat 独立 target 默认关（W3-D）。
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品（Contracts + Engine 的状态机），不许依赖同层的其他包。
// 第三方：Hummingbird 2 + hummingbird-websocket（都是 Apache-2.0），给 API / Tally / 兼容层的 HTTP 用；swift-nio（Apache-2.0，
// Hummingbird 本来就带）给兼容层的 TCP 文本协议用。
//
// W3-D 加的两个 target（各自独立产品，App / headless 按设置决定链不链、起不起）：
//   SwitcherTally（Sources/Tally）   外部 tally 输出：WebSocket JSON tally 流 + GET 轮询；第二版 TSL 用同一份 TallyFrame。
//   VMixCompat（Sources/VMixCompat） 第三方导播软件 API 兼容层（设计方案 §9.3、§0 法律灰区）：默认不启用，设置里显式打开；
//                                    HTTP GET /api 与 TCP 8099 文本协议子集，函数名映射到内部 Command。发布前问律师。
import PackageDescription

let package = Package(
    name: "SwitcherControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherControl", targets: ["SwitcherControl"]),
        .library(name: "SwitcherTally", targets: ["SwitcherTally"]),
        .library(name: "VMixCompat", targets: ["VMixCompat"]),
        .executable(name: "switcher-apidoc", targets: ["switcher-apidoc"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [
        .target(
            name: "SwitcherControl",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        // 外部 tally 输出（W3-D）：只读快照，不依赖 SwitcherControl
        .target(
            name: "SwitcherTally",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "Sources/Tally"
        ),
        // 第三方 API 兼容层（W3-D）：走 SwitcherControl 的 CommandBus / StateFeed，默认关
        .target(
            name: "VMixCompat",
            dependencies: [
                "SwitcherControl",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // docs/api.md 的生成器：按 Command 的 27 个 case 输出每条命令的说明与 JSON 样例
        .executableTarget(
            name: "switcher-apidoc",
            dependencies: ["SwitcherControl"]
        ),
        .testTarget(
            name: "SwitcherControlTests",
            dependencies: ["SwitcherControl"]
        ),
        .testTarget(
            name: "TallyTests",
            dependencies: ["SwitcherTally"]
        ),
        .testTarget(
            name: "VMixCompatTests",
            dependencies: ["VMixCompat"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
