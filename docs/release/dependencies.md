# 依赖钉版本与升级（prompt 71 第 6 条）

## 为什么钉

swift-collections 1.7.0 用了 Swift 6.4 运行时才导出的 `_swift_initBorrow`，macOS 26.6.2 及更早的 `libswiftCore` 里没有、也不向后部署：
解析到它的 App / frameprobe 编得过、一起就 dyld 崩（issues `W3C2-g5-swift-collections-1.7-dyld-crash`、`W3E2-w1-testkit-frameprobe-unpinned-deps-swift-runtime`）。
本产品最低系统是 macOS 15，所以所有解析结果钉在 1.6.0 那一套，直到最低系统的运行时带上这个符号。

macOS 27.0 的运行时已经导出 `_swift_initBorrow`（W4-B 2026-09-27 用 `dyld_info -exports /usr/lib/swift/libswiftCore.dylib` 验过），
所以 1.7.0 在 27 上不崩——但用户在 15 / 26 上会崩，钉法不变。

## 钉在哪

| 文件 | 谁用 | 入库 |
|---|---|---|
| `scripts/xcode-workspace-Package.resolved` | `make gen` 拷进 `Switcher.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`（工程是生成物） | 是 |
| `Packages/SwitcherControl/Package.resolved`、`Packages/SwitcherOutputs/…`、`Packages/SwitcherTestKit/…` | 各包 `swift build / test` | 是 |
| `Tools/switcher-headless/Package.resolved`、`Tools/frameprobe/Package.resolved` | 两个工具 | 是 |
| `Packages/SwitcherCore`、`SwitcherInputs`、`SwitcherAudio` | 没有远程依赖，没有 resolved | — |

Sparkle（App 的直接依赖）在 project.yml 写 `exactVersion: 2.10.0`，模板里同时钉 tag 的提交号。

## 工具：`scripts/release/pin-deps.sh`

- `check`：七份文件（存在的那些）对同一依赖必须同版本同提交；受限依赖不超上限（`MAX_ALLOWED`，现在只有 swift-collections ≤ 1.6.x）；
  工作区文件与模板同一套 pin。`make pin-check`；`make lint` 不带它（lint 不该读生成物），`make archive` 第一步就是它。
- `sync`：把模板拷进工作区（`make gen` 也做这步；SWITCHER_KEEP_RESOLVED=1 跳过）。
- `upgrade <identity> <version> <revision>`：所有文件一起改；这是升依赖的唯一正式路径。
- `verify-runtime <mach-o>…`：`nm -u` 里不许有 `DENYLIST` 的符号（现在 `_swift_initBorrow`）。`make release-test` 的 R4 对归档出的 App、包内 dylib、frameprobe 跑它。

发布构建（`archive.sh`）：先 `check`，`xcodebuild … -onlyUsePackageVersionsFromResolvedFile`，`make gen` 之后再 `check` 一遍。

## 升级流程

1. 看目标版本要不要更新的运行时：`swift-collections` 每次大改都看 release notes；或先在临时包里 `swift build` 一个小可执行，`nm -u` 看有没有 `_swift_initBorrow` 一类新符号。
2. `scripts/release/pin-deps.sh upgrade swift-collections 1.x.y <40 位提交号>`；如果是 Sparkle，另改 project.yml 的 `exactVersion` 与 THIRD_PARTY/Sparkle/SOURCE.md。
3. `make clean && make gen build test`；`make archive-adhoc && make release-test`（R3 / R4）。
4. **macOS 15 与 26 各起一次 App 与 frameprobe**（虚拟机或另一台机器；本机已升 27，26.6.2 只能靠别的机器）——这是升依赖的放行条件，写进报告。
5. 提交信息写清为什么升、验过哪些系统。

## 已知坑

- `Packages/SwitcherControl/Package.resolved` 会被 xcodebuild 顺手写（haishinkit / logboard、originHash）：提交前 `git checkout` 它（issue W3E2 的处理结果）。
- 模板的 `originHash` 与 Xcode 计算的不同时，Xcode 会重解析——只要 pin 一致就没事；`pin-deps.sh check` 只比 pin，不比 originHash。
- 第一次解析在没有网络的机器上会失败：CI runner 与打包机要能访问 GitHub。
