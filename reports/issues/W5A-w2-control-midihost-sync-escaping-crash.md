# MIDIHost.sync 偶发崩溃："non-escaping closure has escaped"（起停 session 时 App 测试宿主整个崩掉）

归属会话 / 分支：**W2-C3 / `w2-control-3`（prompt 106，2026-10-10 开单）**；原记控制会话（W2-C 系）；`Packages/SwitcherControl/Sources/SwitcherControl/MIDI/MIDIHost.swift`（W2-C2 的 c51c7d7 引入）
发现于：W5-A（prompt 86，分支 w5-app-visual）跑 `make test-app` 全量，2026-10-01；同一天 W5-B（w5-app-safety）的测试宿主也崩在同一处
严重级：S1（正式 App 里新建 / 打开节目、改格式、退出时同样会走这条路，崩了就是整个导播台退出）

## 现象

两份崩溃报告（`~/Library/Logs/DiagnosticReports/`，bundle id com.plusmix.switcher，macOS 27.0 26A428）：

| 报告 | 谁的测试宿主 | 崩在哪 |
|---|---|---|
| PlusMix-2026-10-01-173355.ips | W5-A，用例 `ShortcutAndShowTests.testShow_controllerRoundTripReplacesSession` 开头的 freshSession | `MIDIHost.sync<A>(_:)` ← `MIDIController.start()`（MIDIController.swift:103）← `ControlRuntime.start()` ← `SwitcherSession.warmUpLocked()` ← `AppController.newShow()` |
| PlusMix-2026-10-01-171006.ips | W5-B（栈里是它改过的 `replaceSession(show:baseline:)`） | `MIDIHost.sync<A>(_:)` ← `MIDIController.stop()`（MIDIController.swift:113）← `ControlRuntime.stopAPI()` ← `SwitcherSession.teardownLocked()` |

两份都是 `EXC_BREAKPOINT / SIGTRAP`，顶帧 `Swift runtime failure: non-escaping closure has escaped`。单独复跑同一条用例是绿的——时序竞争，机器忙的时候（别的会话同时在编 / 在测，负载均值 6 左右）更容易出。

## 原因（读代码，已核对）

`MIDIHost.swift:62-75`：

```swift
func sync<T: Sendable>(_ body: @Sendable () -> T) -> T {
    ...
    withoutActuallyEscaping(body) { escapable in
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            result.withLock { $0 = escapable() }
            done.signal()          // ← 调用方在这里就被放行
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
    }                              // ← 离开时运行时检查 escapable 没有别人持有
    ...
}
```

块里先 `done.signal()`，块本身要等它返回、run loop 释放它之后才放掉对 `escapable` 的引用。调用方线程被 signal 放行后立刻离开
`withoutActuallyEscaping`，这时宿主线程上的块往往还没被释放，`escapable` 的引用计数还没回落，运行时的逃逸检查就判它"逃逸了"、直接 trap。

## 建议改法（任选其一，都只动 MIDIHost.swift）

1. `sync` 的参数改成 `@escaping @Sendable () -> T`，去掉 `withoutActuallyEscaping`（调用方本来就同步等结果，逃逸不逃逸没有区别）；调用处都在本包里。
2. 保留非逃逸签名：把闭包放进一个可清空的盒子，块里先取出来跑完、把盒子清空（闭包的最后一个引用在 signal 之前就放掉），再 signal。

验证：在 `SwitcherControlTests` 里加一条压力用例，宿主线程上塞一个慢块，主线程连续 `sync` 上千次（或起停 MIDIController 上百次），Debug 构建不崩；App 侧 `make test-app` 全量里 freshSession 不再偶发崩溃。
