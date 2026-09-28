// swift-tools-version: 6.0
// W4-A 探针（问题单 W4A-w2-inputs-file-loop-memory-and-prores-starve §3 的复现 / 验证工具）：只起 FileInput（不接引擎 / 渲染器 / 音频引擎），
// 看循环播放时进程 footprint 是否按圈涨。跑法见 Sources/fileprobe/main.swift 顶部；.build/ 由仓库 .gitignore 的通配盖住，make build / make test 不碰这个包。
import PackageDescription
let package = Package(
    name: "fileprobe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../Packages/SwitcherCore"),
        .package(path: "../../../Packages/SwitcherInputs"),
        .package(path: "../../../Packages/SwitcherAudio"),
    ],
    targets: [
        .executableTarget(name: "fileprobe", dependencies: [
            .product(name: "SwitcherContracts", package: "SwitcherCore"),
            .product(name: "SwitcherEngine", package: "SwitcherCore"),
            .product(name: "SwitcherInputs", package: "SwitcherInputs"),
            .product(name: "SwitcherAudio", package: "SwitcherAudio"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
