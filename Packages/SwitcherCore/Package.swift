// swift-tools-version: 6.0
// SwitcherCore：引擎包。三个 target 的边界见设计方案 §11 和 docs/OWNERSHIP.md：
//   SwitcherContracts  所有包共用的类型（P1 冻结，改动走 docs/contract-changes/）
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
            name: "SwitcherContracts"
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
