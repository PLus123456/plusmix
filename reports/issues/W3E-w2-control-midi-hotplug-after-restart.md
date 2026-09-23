# W3E → W2-C：MIDIController 停过一次之后，热插拔通知收不到（新出现的源连不上）

提出：W3-E（w3-app2），2026-09-19，做 MIDI 映射面板的 learn 测试时发现。归：W2-C / w2-control（`Packages/SwitcherControl/Sources/SwitcherControl/MIDI/MIDIController.swift`）。

## 现象

App 里每个 session 一个 `MIDIController`（`ControlRuntime`），换节目 = 旧的 `stop()`、新的 `start()`。第二个及以后的控制器起来之后，
再建一个虚拟源（`VirtualMIDISource`）或插一个 USB MIDI 设备，`controller.sources` 永远不包含它（测试里等 5 s 仍是 `[]`）；
起控制器之前就存在的源能连上（`setUpOnThread` 里的枚举），消息也正常。W2-C 自己的 `MIDITests` 只起一个控制器，所以没撞上。

## 原因（推断，未改包代码验证）

`MIDIClientCreateWithBlock` 的通知块由"进程里第一次调用 MIDIClientCreate 时的 run loop"派发（CoreMIDI 文档）。控制器在自己的线程上建客户端
（`setUpOnThread`，run loop = 该线程），`stop()` 后线程退出、run loop 不再跑；之后新控制器再建客户端，通知仍派给第一条（已死的）run loop，
`kMIDIMsgObjectAdded` 永远到不了 `connect(source:)`。

## 建议

- 客户端在主线程（主 run loop）上建一次、进程内共用（`MIDIClientCreate` 本来就是每进程一个的东西），输入口 / 连接仍归各控制器；或
- 通知块里只做 `CFRunLoopPerformBlock` 到当前控制器的线程 run loop（但第一次调用时的 run loop 必须一直活着，等于还是要一条常驻线程）。
- 补一个测试：起 → 停 → 再起之后建虚拟源，5 s 内出现在 `sources`。

## W3-E 的绕法

测试里先建虚拟源再起 session（`ControlEditorTests.testMIDIMapping_learnFromVirtualSourceAndSave`）。用户侧的影响：换过节目之后插的 MIDI 设备要重开 App 才能用。

## App 侧绕法（W3-E2 / w3-app-3，2026-09-23；W2-C 还没修）

- 探针证实了上面的推断：第一个客户端的线程退出后，新客户端收到 `msgObjectAdded` 0 次；先在主线程建一个客户端，新客户端收到 1 次、回调在 main。
- App 启动时（`AppController.init`，第一个 session 之前）在主线程建一个不干活的锚客户端（`App/Sources/Engine/MIDINotificationAnchor.swift`），
  全进程的通知都走主 run loop；`MIDIController.handleNotification` 只动带锁的源表和 MIDI API，在主线程上被调没问题。
- 守门用例 `ControlEditorTests.testMIDI_hotplugAfterShowReplaced_newSourceConnects`（换两次节目后建虚拟源，5 s 内连上、销毁后消失）；去掉锚时红。
- W2-C 按"建议"第一条修了（客户端进程内共用 / 在常驻 run loop 上建）之后，App 的锚可以删，用例留着。
