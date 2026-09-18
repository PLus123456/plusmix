// swift-tools-version: 6.0
// SwitcherAudio：混音循环（C 热路径）、重采样、效果链、表、设备层（W1-D）。
// 依赖方向（设计方案 §11 / scripts/check-deps.sh）：只许依赖 SwitcherCore 的产品，不许依赖同层的其他包。
//
// target 分层（设计方案 §3.5 的热路径规则落在 target 边界上）：
//   CLibSamplerate     第三方 libsamplerate 0.2.2 内嵌源码（BSD-2，许可证在 THIRD_PARTY/libsamplerate/）
//   CLibEBUR128        第三方 libebur128 1.2.6 内嵌源码（MIT，许可证在 THIRD_PARTY/libebur128/）
//   CSwitcherAudioRT   热路径：音频环读写、混音块 sw_mix_block、延迟线、速率估计、表更新、设备 IOProc。
//                      单独编译，scripts/check-rt-symbols.sh 对它的目标文件做 nm -u 检查（不许 malloc / 锁 / 日志 / ObjC / Swift 运行时）。
//                      源文件里用 [[clang::nonblocking]] + `#pragma clang diagnostic error "-Wfunction-effects"` 做编译期检查。
//   CSwitcherAudioHost 非实时侧的 C：分配 / 释放环与混音上下文、命令入队、统计快照。允许 malloc，不允许被回调调用。
//   SwitcherAudio      Swift：AudioRing 实现包装、AudioMixer 控制 API、AudioUnit 效果链搭建、CoreAudio 设备层、离线 / 空设备驱动。
//   SwitcherAudioIntegration（Sources/Integration/，W2-E）：音频进引擎的胶水——状态机快照 / 转场事件 → 混音命令（AFV、FTB、监听、
//                      每路参数）、输入环的槽位管理与对齐延迟、Master / ISO 块的 PTS（拍点同一 host 时基）与消费者泵、表与状态快照。
//                      依赖 SwitcherEngine（层 1，允许）；非实时代码，不进 IOProc。
//
// 三个 C target 在 debug 配置下也用 -O2（unsafeFlags；SwiftPM 对本地路径依赖允许，W1-D 实测 TestKit 能解析）：
// -O0 的 sinc 重采样 + K 加权滤波每块 2 ms（8 路），debug 下跑真设备会贴近 5.3 ms 预算，离线 10 分钟要 9 分钟；
// -O2 后 ≈ 十分之一。热路径规则与优化级别无关（符号检查两种配置都跑）。
import PackageDescription

let package = Package(
    name: "SwitcherAudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwitcherAudio", targets: ["SwitcherAudio"]),
        .library(name: "SwitcherAudioIntegration", targets: ["SwitcherAudioIntegration"]),
    ],
    dependencies: [
        .package(path: "../SwitcherCore"),
    ],
    targets: [
        .target(
            name: "CLibSamplerate",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .define("NDEBUG", .when(configuration: .release)),
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CLibEBUR128",
            cSettings: [
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CSwitcherAudioRT",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                "CLibSamplerate",
                "CLibEBUR128",
            ],
            cSettings: [
                .define("SW_AUDIO_RT_TARGET"),
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "CSwitcherAudioHost",
            dependencies: ["CSwitcherAudioRT", "CLibSamplerate", "CLibEBUR128"],
            cSettings: [
                // sw_mix_internal.h / sw_device_internal.h 故意不放进 RT 的 include/：Swift 不该看到内部布局（对 Swift 是 OpaquePointer）
                .headerSearchPath("../CSwitcherAudioRT"),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "SwitcherAudio",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                "CSwitcherAudioRT",
                "CSwitcherAudioHost",
                "CLibEBUR128",
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .testTarget(
            name: "SwitcherAudioTests",
            dependencies: ["SwitcherAudio"]
        ),
        // W2-E：音频集成（docs/OWNERSHIP.md 允许本会话加的唯一 target）。
        .target(
            name: "SwitcherAudioIntegration",
            dependencies: [
                .product(name: "SwitcherContracts", package: "SwitcherCore"),
                .product(name: "SwitcherEngine", package: "SwitcherCore"),
                "SwitcherAudio",
                "CLibSamplerate",
            ],
            path: "Sources/Integration"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["SwitcherAudioIntegration", "SwitcherAudio"],
            path: "Tests/IntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c17
)
