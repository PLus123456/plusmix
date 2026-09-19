# 外部 tally 输出（SwitcherTally）

`Packages/SwitcherControl/Sources/Tally/`：只读快照、把 tally 变成给外部设备用的 JSON 流。多画面边框、Stream Deck 颜色、Companion 反馈、
tally 灯、第二版的 TSL 都从同一份数据来——`MixerState.tallies`（契约代码，全系统只算这一处）。

## 接线

```swift
let publisher = TallyPublisher(stateMachine: stateMachine) { engine.clock?.spec }
await publisher.start()                                              // 挂状态机的 SnapshotObserver，用当前快照做第一帧
let tally = TallyServer(publisher: publisher, configuration: TallyServerConfiguration(host: "0.0.0.0", port: 8766, heartbeatSeconds: 5))
try await tally.start()                                              // tally.boundPort
…
await tally.stop(); await publisher.stop()
```

默认 0.0.0.0:8766（API 端口 + 1）：tally 设备通常在局域网另一台机器上，流是只读的、不收命令，所以不像 API 那样默认只听本机。

## 协议

`WS ws://host:8766/tally`：连接上依次收到 `hello`、当前 `tally` 帧，之后**每次 tally 内容变化一帧**（与 tally 无关的状态变化——增益、名字之外的设置——不发），
没有变化时每 `heartbeatSeconds` 一条 `heartbeat`。`GET http://host:8766/tally` 返回最近一帧（轮询用；还没有帧时 503）。

```json
{"type":"hello","version":"0.1.0","now":123456789,"timebase":{"numer":125,"denom":3},"clock":{"t0":123,"frameDuration":{"numerator":1,"denominator":60}}}
{"type":"tally","sequence":12,"tick":345,"tickTime":123456,"publishedAt":123457,
 "program":1,"preview":2,"transitionActive":false,"ftb":false,"recording":true,"streaming":false,
 "inputs":[{"number":1,"name":"机位 1","program":true,"preview":false},{"number":2,"name":"机位 2","program":false,"preview":true}],
 "outputs":[{"number":1,"kind":"record","name":"录制","enabled":true},{"number":2,"kind":"stream","name":"推流","enabled":false}]}
{"type":"heartbeat","now":123456999,"sequence":12}
```

- `inputs[].program` 的规则与画面一致：在 PGM、或转场进行中在 PVW、或某个可见的叠加通道用了它。`preview` = 在 PVW。FTB 不改变 tally。
- `tickTime` 没有引擎时钟时是 `null`（键仍在）。时间戳都是 host time（mach_absolute_time 的 tick），`timebase` 换算成纳秒。
- 每个订阅者独立缓冲 64 帧，慢客户端丢旧的，不拖状态机；一帧是整状态，丢了也自愈。
- 键排序、不转义斜杠，与 API / stats.jsonl 同一种写法。

## 客户端例子

Python（标准库，见 `scripts/apitest/apitest.py` 里的 WS 实现）或任何 WebSocket 库：连上、按 `type` 分发、`tally` 帧里按 `number` 找自己那路，
`program` 亮红、`preview` 亮绿。ESP32 / Arduino 类设备用 `GET /tally` 每 200 ms 轮询也行（`sequence` 变了才重画）。

## 第二版：TSL UMD

TSL 3.1 / 5.0（UDP，每路一个地址：tally 1 / tally 2 位 + 16 字节文字）直接从同一份 `TallyFrame` 生成：地址 = 输入编号（可配偏移），
tally 1 = program，tally 2 = preview，文字 = 名字。放在同一个 target 里，配置多一个 `TSLOutput{host, port, version, addressOffset}`；
`TallyPublisher.subscribe()` 拿帧，变化时发一包，另加每秒重发（TSL 设备靠重发保活）。本期没做。
