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
