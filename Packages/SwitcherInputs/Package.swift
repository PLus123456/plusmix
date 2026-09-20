// swift-tools-version: 6.0
// SwitcherInputs：各输入实现（摄像头 / UVC、屏幕、文件、图片；DeckLink、NDI 各自独立可选 target，W3-A 加）
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
//
// target 归属（docs/OWNERSHIP.md）：
//   SwitcherInputs          W2-A：CameraInput / ScreenInput / FileInput / ImageInput + 无信号 / 热插拔 / 权限（库只依赖契约）
//   SwitcherInputsHarness   W2-A：组装方——真引擎 + 真渲染器 + 真帧槽（包一层 L1 记录）+ L1 消费者；探针和测试共用。
//                           它是"组装方"，所以可以看 SwitcherEngine（帧槽、引擎）和 SwitcherRender（Metal 渲染器）；库本身只依赖契约。
//   switcher-input-probe    W2-A：命令行探针——设备清单、时间戳时钟探针、量 L1、S5 热插拔计时、S6 权限观察。
//   SwitcherNDI             W3-A：NDIInput（源发现、接收、抖动缓冲、tally 回传）。C 封装 target CSwitcherNDI 包住 NDI SDK：
//                           SDK 的头只在 .c 里包含，不另起一个叫 `NDI` 的系统库模块（SwitcherOutputs 已经有一个同名的，
//                           App 同时链接两个包时 SwiftPM 不许 target 撞名，clang 模块也不许同一头文件出现在两个模块里）。
//                           SDK 不在（Package.swift 探测不到）时 CSwitcherNDI 编成空实现，`SwitcherNDIInfo.isSDKAvailable == false`。
//   SwitcherDeckLink        W3-A：DeckLinkInput。C++ 桥接 target CSwitcherDeckLink 对着 DeckLink SDK 的 COM 接口写，
//                           对 Swift 只暴露 C API；SDK 不在时桥接层编成空实现（枚举 0 台、打开失败并给文案）。
//                           带了 SDK 时还编进一个 Fake IDeckLinkInput（C++ 假对象），DeckLinkTests 用它跑格式变更 / 无信号 / 帧到达三条路径。
import Foundation
import PackageDescription

let env = ProcessInfo.processInfo.environment
let fm = FileManager.default

// ---- NDI SDK：默认装在 /Library/NDI SDK for Apple（NDI_SDK_DIR 可改）。头在就把 SDK 编进 CSwitcherNDI（-I + -lndi）；不在就是空实现。
let ndiSDKDir = env["NDI_SDK_DIR"] ?? "/Library/NDI SDK for Apple"
let ndiAvailable = fm.fileExists(atPath: ndiSDKDir + "/include/Processing.NDI.Lib.h")

// ---- DeckLink SDK：DECKLINK_SDK_DIR（设了就只看它，设成不存在的路径 = 明确关掉）→ ~/SDKs/DeckLink（P0-H 清单指定的位置；
// 支持解压后的 <dir>/Mac/include 布局）→ NDI SDK 示例目录自带的 Blackmagic SDK 副本（10.11.2，只用来在没装正式 SDK 的机器上
// 编译桥接层和跑 Fake 测试；驱动对老版本接口 IID 向后兼容，正式 SDK 装到 ~/SDKs/DeckLink 后自动优先）。
// 需要的文件：DeckLinkAPI.h 和 DeckLinkAPIDispatch.cpp（后者由 CSwitcherDeckLink/sw_decklink_dispatch.cpp 用 -I 包含进来编译）。
func deckLinkIncludeDir(under dir: String) -> String? {
    let fm = FileManager.default   // 顶层的 fm 是 main-actor 隔离的，manifest 里的普通函数碰不了
    for inc in [dir + "/include", dir + "/Mac/include", dir] {
        if fm.fileExists(atPath: inc + "/DeckLinkAPI.h"), fm.fileExists(atPath: inc + "/DeckLinkAPIDispatch.cpp") { return inc }
    }
    return nil
}
let deckLinkCandidates: [String] = env["DECKLINK_SDK_DIR"].map { [$0] }
    ?? [fm.homeDirectoryForCurrentUser.path + "/SDKs/DeckLink", ndiSDKDir + "/examples/C++/NDIlib_Send_BMD/BMDSDK"]
let deckLinkInclude: String? = deckLinkCandidates.lazy.compactMap(deckLinkIncludeDir).first

// CSwitcherNDI 的编译 / 链接参数（SDK 目录带空格，走 unsafeFlags；本包只被路径依赖，SwiftPM 允许）
var ndiCSettings: [CSetting] = [.define("SWITCHER_HAS_NDI_SDK", to: ndiAvailable ? "1" : "0")]
var ndiLinkerSettings: [LinkerSetting] = [.linkedFramework("CoreVideo")]
if ndiAvailable {
    ndiCSettings.append(.unsafeFlags(["-I\(ndiSDKDir)/include"]))
    ndiLinkerSettings.append(.unsafeFlags(["-L\(ndiSDKDir)/lib/macOS", "-lndi", "-Xlinker", "-rpath", "-Xlinker", "\(ndiSDKDir)/lib/macOS"]))
}
// CSwitcherDeckLink 的编译参数。DeckLinkAPI.framework 由 SDK 的 Dispatch.cpp 在运行时 CFBundle 加载，不用链接。
var deckLinkCxxSettings: [CXXSetting] = [.define("SWITCHER_HAS_DECKLINK_SDK", to: deckLinkInclude != nil ? "1" : "0")]
if let inc = deckLinkInclude { deckLinkCxxSettings.append(.unsafeFlags(["-I\(inc)"])) }

let package = Package(
    name: "SwitcherInputs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherInputs", targets: ["SwitcherInputs"]),
        .library(name: "SwitcherNDI", targets: ["SwitcherNDI"]),
        .library(name: "SwitcherDeckLink", targets: ["SwitcherDeckLink"]),
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
        .target(
            name: "SwitcherInputsHarness",
            dependencies: [
                "SwitcherInputs",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "SwitcherRender", package: "SwitcherCore"),
            ]
        ),
        .executableTarget(
            name: "switcher-input-probe",
            dependencies: [
                "SwitcherInputs",
                "SwitcherInputsHarness",
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
                "SwitcherInputsHarness",
                "switcher-input-probe",
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                .product(name: "SwitcherRender", package: "SwitcherCore"),
            ]
        ),

        // ---- W3-A：NDI 接收 ----
        .target(
            name: "CSwitcherNDI",
            path: "Sources/NDI/CSwitcherNDI",
            cSettings: ndiCSettings,
            linkerSettings: ndiLinkerSettings
        ),
        .target(
            name: "SwitcherNDI",
            dependencies: [
                "CSwitcherNDI",
                "SwitcherInputs",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ],
            path: "Sources/NDI",
            exclude: ["CSwitcherNDI"]
        ),
        .testTarget(
            name: "NDITests",
            dependencies: [
                "SwitcherNDI",
                "CSwitcherNDI",
                "SwitcherInputs",
                "SwitcherInputsHarness",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
            ],
            path: "Tests/NDITests"
        ),

        // ---- W3-A：DeckLink ----
        .target(
            name: "CSwitcherDeckLink",
            path: "Sources/DeckLink/CSwitcherDeckLink",
            cxxSettings: deckLinkCxxSettings,
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("CoreVideo")]
        ),
        .target(
            name: "SwitcherDeckLink",
            dependencies: [
                "CSwitcherDeckLink",
                "SwitcherInputs",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
            ],
            path: "Sources/DeckLink",
            exclude: ["CSwitcherDeckLink"]
        ),
        .testTarget(
            name: "DeckLinkTests",
            dependencies: [
                "SwitcherDeckLink",
                "CSwitcherDeckLink",
                "SwitcherInputs",
                "SwitcherInputsHarness",
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
            ],
            path: "Tests/DeckLinkTests"
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
