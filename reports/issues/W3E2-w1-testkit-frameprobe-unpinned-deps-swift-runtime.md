# W3E2 → W1-A / 检查点：frameprobe 的依赖没钉版本，新 worktree 里编出来的二进制在 macOS 26.6.2 上起不来（`_swift_initBorrow`）

提出：W3-E2（`w3-app-3`，2026-09-23，跑 App 全量时 A4 / 推流两条用例的 frameprobe 子进程起不来）。
归：W1-A（`Tools/frameprobe/`、`Packages/SwitcherTestKit/`）+ 检查点（要不要把这几个 `Package.resolved` 入库是仓库约定，G4 报告 §9 定的是"生成物别提交"）。
严重级：S1（gate4 与 App 的 A4 / 推流用例在新 worktree 里全靠 frameprobe；编得过、一跑就 dyld 崩）。

## 现象

```
$ swift build -c release --package-path Tools/frameprobe && Tools/frameprobe/.build/release/frameprobe
dyld[…]: Symbol not found: _swift_initBorrow
  Referenced from: …/Tools/frameprobe/.build/out/Products/Release/frameprobe
  Expected in:     /usr/lib/swift/libswiftCore.dylib
```

- 本机：macOS 26.6.2（25G83），Xcode 27.0（Swift 6.4）。二进制的 `LC_BUILD_VERSION` 是 minos 15.0 / sdk 15.0，但引用了 Swift 6.4 运行时才有的 `swift_initBorrow`，系统的 libswiftCore 没有。
- 同一份源码（main 4b7a3df），G4 worktree 里 13:02 编的那份能跑（不引用这个符号）；本 worktree 14:05 编的、以及另起 `--scratch-path` 从零编的都起不来。

## 原因（已验证）

`Tools/frameprobe/`（还有 `Packages/SwitcherTestKit/`、`Packages/SwitcherOutputs/`）不跟踪 `Package.resolved`，每次新解析都浮到依赖的最新版本。
今天从零解析拿到的是 swift-collections **1.7.0**、swift-crypto **5.0.0**、swift-nio **2.103.0**、hummingbird 2.27.0、swift-certificates 1.21.0……；
而仓库里跟踪的 `Packages/SwitcherControl/Package.resolved` / `Tools/switcher-headless/Package.resolved` 钉的是 swift-collections 1.6.0、swift-crypto 4.5.2、swift-nio 2.102.0……。

验证：把 `Tools/switcher-headless/Package.resolved` 临时拷成 `Tools/frameprobe/Package.resolved`，另起 scratch path 从零编 → 解析到 1.6.0 / 4.5.2 / 2.102.0，二进制**不引用** `_swift_initBorrow`，`frameprobe` 正常打印版本。
（没逐个二分是哪个包；最可疑的是 swift-collections 1.7.0。）

## 影响

- 任何新 worktree / 清过 `.build` 的机器上：gate4.sh 的 frameprobe 步骤、App 的 `ISOAppTests.testA4_app_…`、`StreamWiringTests.testStream_10s…`（它们找 `Tools/frameprobe/.build/{release,debug}/frameprobe`）一跑就挂。
  W3-E2 的全量里这两条就是这么红的，换成 G4 worktree 那份能跑的二进制后都过（reports/w3-app-3.md §2.2）。
- SwitcherTestKit / SwitcherOutputs 的 `swift test` 同样会浮到新版本；这次没看到它们崩，但同一类风险。

## 建议

1. 把 `Tools/frameprobe/Package.resolved`（和 `Packages/SwitcherTestKit/`、`Packages/SwitcherOutputs/` 的）入库，内容与 `Packages/SwitcherControl/Package.resolved` 同一套版本；
   G4 报告 §9"生成物别提交"那条改成"这几个要提交、别让 xcodebuild / swift build 顺手改掉"。
2. 或者在各 Package.swift 里给 swift-collections / swift-crypto / swift-nio 加上限（`.upToNextMinor`），等确认新版本在最低系统上能跑再放开。
3. 升依赖作为单独的事做（W4-A / W4-B），升完在 macOS 15 / 26 两个系统上各起一次 frameprobe / App。
