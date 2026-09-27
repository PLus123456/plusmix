# W3C2 → 下一个动 CameraExtension/ 的会话（W4-B 定签名 / bundle id 时一起，或单开）：扩展要回报"已输出"，虚拟摄像头的 dropped 才有扩展那一份

来源：W3-C2（prompt 65 交付 2："虚拟摄像头的 dropped 从扩展的丢弃计数来"；报告 reports/w3-outputs-3.md §1 / §3 第 3 条）。CameraExtension/ 不归 W3-C2，
扩展激活本身 BLOCKED-签名（Team ID + /Applications），所以只做了主程序这一侧，扩展侧差下面三行。

## 主程序这一侧已经做好的（SwitcherOutputs/Sources/VirtualCamera/）

- 每一帧排进 sink 之前挂 CMIO 序号（`CMIOSequenceNumber.set`，每个连接从 0 连续编号，排不进的不占号）。
  `CMIOSampleBuffer.h` 不在 CoreMediaIO 的 Swift 模块里，C 函数 `CMIOSampleBufferSet/GetSequenceNumber` 用 dlsym 取（探针：本机导出，附件键
  `com.apple.cmio.buffer_attachment.sequence_number`）。
- `CMIOSinkStreamClient.open()` 在 sink stream 上注册 `kCMIOStreamPropertyScheduledOutputNotificationProc`（'sonp'），回调进 `ScheduledOutputTracker`：
  相邻两条通知的序号差 − 1 = 扩展收了却没输出的帧（`Counters.droppedExtension`），通知条数 = `framesOutput`。
- `statsEntry` 的 dropped = 本端队列满 + 排不进 sink + `droppedExtension`。扩展不回报时这一项恒 0。

## 扩展侧要加的（CameraExtension/Sources/CameraExtensionProvider.swift，`consumeNext(from:)`）

```swift
sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
    ...
    if let sampleBuffer {
        ...
        self.sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: ns)
        // 告诉主程序这一帧已经输出（主程序按序号跳号算扩展丢的帧）
        self.sinkStream.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: ns))
        ...
    }
```
- 现在回调里第二个参数（sampleBufferSequenceNumber）被 `_` 丢掉了，改成接住它。
- 扩展自己要丢帧（例如以后加"没有 source 客户端时不转发"）就**不要**为那一帧发通知——跳号就是丢帧的记账方式，不用另开计数。

## 解锁后怎么验（BLOCKED-签名解除之后）

1. `DEVELOPMENT_TEAM=<TeamID> make gen`，App 装到 /Applications，菜单"输出 → 虚拟摄像头 → 安装 / 激活扩展"，系统设置里允许。
2. 开虚拟摄像头输出，QuickTime / FaceTime 选 "Switcher"：`Stats.display[]` 里 kind = virtualCamera 那一项 state = publishing、frames 随节目帧率涨；
   `VirtualCameraOutput.countersSnapshot.extensionReports == true`、`framesOutput` 跟着 frames 涨（差几帧是在路上的）。
3. 让扩展故意丢（临时在转发里每 10 帧跳过一帧不 send、不 notify）：dropped 每秒涨 6（60 fps）。
4. 停用扩展（`systemextensionsctl` 或系统设置里关掉）：一秒内 state 回到 waitingExtension（连续排不进 → 关掉重找 → 找不到设备），
   之后的帧只进 `droppedNoDevice`，不进 Stats 的 dropped。

注：'sonp' 在扩展背后的 CMIO 桥上是否照样转发 `notifyScheduledOutputChanged`，本机没法验（没有签名的扩展）；
头文件（CMIOExtensionStream.h / CMIOHardwareStream.h）的描述是这么设计的。第一次签名跑通时看 `extensionReports` 是否为 true、`framesOutput` 是否在涨，
不涨就说明桥没转发，换扩展自定义属性（CMIOExtensionProperty 自定义键）回报计数。

## W3-C3（w3-outputs-4，2026-09-27）处理结果

- **扩展侧已加**（`CameraExtension/Sources/CameraExtensionProvider.swift` 的 `consumeNext`）：接住 `sampleBufferSequenceNumber`，
  `sourceStream.stream.send` 之后 `sinkStream.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber:hostTimeInNanoseconds:))`；
  时刻用发出去那一刻（头文件："the host time … when the buffer was output"），不是 PTS；序号是 `UInt64.max`（kCMIOInvalidSequenceNumber，没挂上）的不回报。
  探针（w3-outputs-4 报告 §1）：`CMIOExtensionScheduledOutput` 的 Swift 形状与头文件一致；进程内对没接服务的流调 notify 不崩、什么也不做。
- **主程序侧加了守卫**：sink 排队之前 `ScheduledOutputTracker.noteSent` 记下序号；回报的序号不是本连接排过的（invalid / 比排过的都大 /
  新连接还没排过帧时到的旧连接回报）只记 `unmatched`（`VirtualCameraOutput.countersSnapshot.extensionUnmatched`），不算输出也不算丢。
- **记账用例**：`VirtualCameraTests.testVirtualCamera_extensionReportsViaSonp_sequenceGapsBecomeDropped`（假扩展走注册在 sink 上的 'sonp' C 回调，
  同步 / 异步 / 重连三段）。

## 第一次签名跑通时怎么看（补上一节"解锁后怎么验"的第 2 步）

`VirtualCameraOutput.countersSnapshot`（App：`session.aux.virtualCamera?.countersSnapshot`，或断点 / 日志打出来）：
1. `extensionReports == true`（'sonp' 注册上了）；
2. `framesOutput` 跟着 `framesSent` 涨（差几帧是在路上的）→ 桥在转发扩展的回报；**不涨** = 桥没转发 → 换扩展自定义属性回报计数（见上文注）；
3. `extensionUnmatched == 0` → 扩展拿到的就是本进程挂的序号；**在涨** = 桥改了 / 丢了序号（`framesOutput` 不涨、dropped 不可信）——看扩展日志里
   `sampleBufferSequenceNumber` 是什么，按它改 `ScheduledOutputTracker` 的对法；
4. `droppedExtension` 平时是 0；上一节第 3 步（扩展里临时每 10 帧不 send、不 notify）时每秒涨 6。
