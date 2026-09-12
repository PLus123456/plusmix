// swift-tools-version: 6.0
// SwitcherCore：引擎包。target 的边界见设计方案 §11 和 docs/OWNERSHIP.md：
//   CSwitcherContracts 契约里必须被 C 热路径直接读写的结构布局（音频环）。只有头文件和布局断言，没有实现（P1）。
//                      目录放在 Sources/SwitcherContracts/C/：它就是契约的一部分，和 Swift 契约同一个归属（docs/OWNERSHIP.md）
//   SwitcherContracts  所有包共用的类型（P1 冻结，改动走 docs/contract-changes/）；re-export CSwitcherContracts
//   SwitcherEngine     节目时钟、帧槽、状态机、引擎骨架、统计（W1-B）
//   SwitcherRender     Metal 合成、NV12 转换、显示视图（W1-C）
// Engine 与 Render 只通过 Contracts 里的协议见面，互不依赖（scripts/check-deps.sh 会拦）。
import PackageDescription

let package = Package(
    name: "SwitcherCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherContracts", targets: ["SwitcherContracts"]),
        .library(name: "SwitcherEngine", targets: ["SwitcherEngine"]),
        .library(name: "SwitcherRender", targets: ["SwitcherRender"]),
    ],
    targets: [
        .target(
            name: "CSwitcherContracts",
            path: "Sources/SwitcherContracts/C"
        ),
        .target(
            name: "SwitcherContracts",
            dependencies: ["CSwitcherContracts"],
            exclude: ["C"]
        ),
        .target(
            name: "SwitcherEngine",
            dependencies: ["SwitcherContracts"]
        ),
        .target(
            name: "SwitcherRender",
            dependencies: ["SwitcherContracts"]
        ),
        .testTarget(
            name: "SwitcherContractsTests",
            dependencies: ["SwitcherContracts"]
        ),
        .testTarget(
            name: "SwitcherEngineTests",
            dependencies: ["SwitcherEngine"]
        ),
        .testTarget(
            name: "SwitcherRenderTests",
            dependencies: ["SwitcherRender"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
