## 运行 net：E7–E9（dummynet + pf，netem 代理模式）

- 日期：2026-09-18 10:43:09 +0800；提交：`fce834a`；负载 跑前 3.51 3.33 3.08 → 跑后 1.85 2.22 2.58
- 命令：`SWITCHER_NETEM=broker swift test --package-path Packages/SwitcherOutputs --filter 'MediaMTXTests/test(E7|E8|E9)'`（xctest 退出码 0；日志 `.build/gate3/net/xctest.log`）

| 测试 ID | 用例 | 结果 | 耗时 | 阈值（测试标准 §4） |
|---|---|---|---|---|
| E7 | `testE7_threeStreams_blockSecondFor30s_othersDropZero` | ✅ 通过 | 82.737 s | 其他路丢帧 0（硬性） |
| E8 | `testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect` | ✅ 通过 | 180.271 s | 10 次全部成功、≤ 15 s（目标 ≤ 5 s）；重连后 A2 达标 |
| E9 | `testE9_bandwidth70pct_5min_dropCountWithin5pct` | ✅ 通过 | 338.526 s | 误差 ≤ 5%（目标 ≤ 1%） |

测试自己打印的数字（送出 / 落盘 / 网络丢帧 / 重连耗时）：

```
t=18 s 第 2 路判断线：backoff(1, 1.0s)
t=40 s 第 2 路重连成功，放开后 0.67 s
第 1 路：StreamCounters(framesReceived: 3600, framesSent: 3600, keyframesSent: 30, networkDropped: 0, droppedQueueFull: 0, droppedWaitingKeyframe: 0, droppedDisconnected: 0, discardedOnDisconnect: 0, lostInTransport: 0, audioPacketsReceived: 2812, audioPacketsSent: 2812, audioDropped: 0, bytesSent: 46217368, connectAttempts: 1, reconnects: 0, disconnects: 0, lastReconnectSeconds: 0.0, maxReconnectSeconds: 0.0, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 212663, state: stopped)，编码器 skipped 0
第 1 路落盘：(frames: 3599, dropped: 0, gaps: 0, undecodable: 0)
第 3 路：StreamCounters(framesReceived: 3600, framesSent: 3600, keyframesSent: 30, networkDropped: 0, droppedQueueFull: 0, droppedWaitingKeyframe: 0, droppedDisconnected: 0, discardedOnDisconnect: 0, lostInTransport: 0, audioPacketsReceived: 2812, audioPacketsSent: 2812, audioDropped: 0, bytesSent: 46217368, connectAttempts: 1, reconnects: 0, disconnects: 0, lastReconnectSeconds: 0.0, maxReconnectSeconds: 0.0, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 212663, state: stopped)，编码器 skipped 0
第 3 路落盘：(frames: 3599, dropped: 0, gaps: 0, undecodable: 0)
第 2 路：StreamCounters(framesReceived: 3600, framesSent: 1913, keyframesSent: 17, networkDropped: 1814, droppedQueueFull: 2, droppedWaitingKeyframe: 123, droppedDisconnected: 1502, discardedOnDisconnect: 60, lostInTransport: 127, audioPacketsReceived: 2812, audioPacketsSent: 1491, audioDropped: 1321, bytesSent: 24553002, connectAttempts: 3, reconnects: 1, disconnects: 1, lastReconnectSeconds: 22.039497166, maxReconnectSeconds: 22.039497166, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 208008, state: stopped)
  断线判定用了 9.0 s：backoff(1, 1.0s)
  第 1 次重连成功：放开后 1.07 s
  断线判定用了 9.1 s：backoff(1, 1.0s)
  第 2 次重连成功：放开后 0.08 s
  断线判定用了 9.0 s：backoff(1, 1.0s)
  第 3 次重连成功：放开后 1.04 s
  断线判定用了 9.2 s：backoff(1, 1.0s)
  第 4 次重连成功：放开后 0.18 s
  断线判定用了 9.1 s：backoff(1, 1.0s)
  第 5 次重连成功：放开后 1.10 s
  断线判定用了 9.1 s：backoff(1, 1.0s)
  第 6 次重连成功：放开后 1.05 s
  断线判定用了 9.1 s：backoff(1, 1.0s)
  第 7 次重连成功：放开后 0.22 s
  断线判定用了 9.1 s：backoff(1, 1.0s)
  第 8 次重连成功：放开后 1.08 s
  断线判定用了 9.0 s：backoff(1, 1.0s)
  第 9 次重连成功：放开后 1.05 s
  断线判定用了 9.0 s：backoff(1, 1.0s)
  第 10 次重连成功：放开后 1.06 s
E8 重连耗时：["1.07", "0.08", "1.04", "0.18", "1.10", "1.05", "0.22", "1.08", "1.05", "1.06"]；断线判定：["9.0", "9.1", "9.0", "9.2", "9.1", "9.1", "9.1", "9.1", "9.0", "9.0"]；StreamCounters(framesReceived: 10080, framesSent: 5077, keyframesSent: 46, networkDropped: 6238, droppedQueueFull: 20, droppedWaitingKeyframe: 1519, droppedDisconnected: 2864, discardedOnDisconnect: 600, lostInTransport: 1235, audioPacketsReceived: 7875, audioPacketsSent: 3938, audioDropped: 3937, bytesSent: 65181162, connectAttempts: 11, reconnects: 10, disconnects: 10, lastReconnectSeconds: 2.016587583, maxReconnectSeconds: 2.021567916, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 0, state: stopped)
t=30 s：送出 1440 丢 360（满 4 等关键帧 356 断线 0）在途 1340 KB 状态 publishing
t=60 s：送出 2617 丢 983（满 12 等关键帧 971 断线 0）在途 793 KB 状态 publishing
t=90 s：送出 3907 丢 1493（满 19 等关键帧 1474 断线 0）在途 1025 KB 状态 publishing
t=120 s：送出 5126 丢 2074（满 28 等关键帧 2046 断线 0）在途 1186 KB 状态 publishing
t=150 s：送出 6328 丢 2650（满 38 等关键帧 2612 断线 0）在途 1511 KB 状态 publishing
t=180 s：送出 7532 丢 3268（满 46 等关键帧 3222 断线 0）在途 1246 KB 状态 publishing
t=210 s：送出 8822 丢 3778（满 53 等关键帧 3725 断线 0）在途 1135 KB 状态 publishing
t=240 s：送出 10016 丢 4378（满 61 等关键帧 4317 断线 0）在途 1504 KB 状态 publishing
t=270 s：送出 11272 丢 4911（满 69 等关键帧 4842 断线 0）在途 1528 KB 状态 publishing
E9：StreamCounters(framesReceived: 18000, framesSent: 12549, keyframesSent: 130, networkDropped: 5451, droppedQueueFull: 75, droppedWaitingKeyframe: 5376, droppedDisconnected: 0, discardedOnDisconnect: 0, lostInTransport: 0, audioPacketsReceived: 14062, audioPacketsSent: 14062, audioDropped: 0, bytesSent: 163349724, connectAttempts: 1, reconnects: 0, disconnects: 0, lastReconnectSeconds: 0.0, maxReconnectSeconds: 0.0, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 0, state: stopped)
E9：收到 18000，落盘 12548（1 个文件），缺 5451，软件报告 5451，误差 0.00%
```

生成时间：2026-09-18 10:53:18
