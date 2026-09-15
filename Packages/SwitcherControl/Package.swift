// swift-tools-version: 6.0
// SwitcherControl：命令总线、HTTP / WS API、快捷键、MIDI、Tally；VMixCompat 独立 target 默认关（W3-D）。
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品（Contracts + Engine 的状态机），不许依赖同层的其他包。
// 第三方：Hummingbird 2 + hummingbird-websocket（都是 Apache-2.0），只给 API target 用。
import PackageDescription

let package = Package(
    name: "SwitcherControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherControl", targets: ["SwitcherControl"]),
        .executable(name: "switcher-apidoc", targets: ["switcher-apidoc"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
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
        // docs/api.md 的生成器：按 Command 的 27 个 case 输出每条命令的说明与 JSON 样例
        .executableTarget(
            name: "switcher-apidoc",
            dependencies: ["SwitcherControl"]
        ),
        .testTarget(
            name: "SwitcherControlTests",
            dependencies: ["SwitcherControl"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
