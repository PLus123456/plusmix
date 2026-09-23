# W3C2 → 合并 w3-outputs-3 的检查点 / W4-B（发布工程）：新 worktree 的 `make gen` 会把 swift-collections 解到 1.7.0，App 一启动就 dyld 崩

来源：W3-C2（prompt 65）跑 App 测试时撞到（报告 reports/w3-outputs-3.md §5 第 2 条）。与本分支的代码无关，是依赖解析的环境坑；**任何新开的 worktree / 干净检出都会中**。

## 现象

- `make gen && xcodebuild test`：测试宿主一启动就崩
  `dyld: Symbol not found: _swift_initBorrow … Referenced from: Switcher.app/Contents/MacOS/Switcher.debug.dylib  Expected in: /usr/lib/swift/libswiftCore.dylib`
  （Test crashed with signal abrt before establishing connection；xcresult 里 0 个用例）。
- 引用这个符号的是 swift-collections 的 `InternalCollectionsUtilities`（`Optional+Extras.o`、`BorrowingIteratorProtocol+Extras.o`），不是本仓库的代码。
- 原因：`Switcher.xcodeproj` 是生成物，它的 `project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 不入库；新 worktree 第一次解析拿的是各清单允许的最新版——
  swift-collections **1.7.0**（上游新发的），它用了 Swift 6.4 运行时的 `swift_initBorrow`，macOS 26.6.2（25G83）自带的 libswiftCore 里没有，也没有向后部署。
  入库的 `Packages/SwitcherControl/Package.resolved`、`Tools/switcher-headless/Package.resolved` 钉的是 **1.6.0**，其他 worktree 生成的工作区文件也都是 1.6.0，所以以前没人碰到。
- 包级 `swift test` 不受影响（各包用自己的 Package.resolved）；只有 App（Xcode 工作区统一解析）中招。`make build-app` 能编过，崩在运行。

## 本会话的临时绕法（只动了生成物，没提交任何东西）

```bash
cp <任一别的 worktree>/Switcher.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
   Switcher.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
rm -rf .build/DerivedData/SourcePackages          # 不清的话第一次解析留下的 hummingbird 2.27 等新检出会和 1.6.0 的钉法打架（trait FullFoundation 报错）
xcodebuild -resolvePackageDependencies -project Switcher.xcodeproj -scheme Switcher -derivedDataPath .build/DerivedData
```

## 建议的正式修法（归 W4-B 或检查点，本会话不动 project.yml / Makefile）

1. 把一份钉好的工作区 Package.resolved 入库（例如 `App/Package.resolved`），`make gen` 之后拷进 `Switcher.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`；
   或者在 project.yml 里给 App 的远程包依赖写死 `exactVersion`（swift-collections 是传递依赖，要在 project.yml 的 packages 里显式声明才钉得住）。
2. 等 macOS 的 Swift 运行时带上 `swift_initBorrow`（或 swift-collections 修了部署目标）再放开。
3. G5 的发布构建必须用钉住的解析结果，否则发出去的 App 在 macOS 26.6 上起不来。
