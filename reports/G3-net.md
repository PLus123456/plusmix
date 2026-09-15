## 运行 net：E7–E9（dummynet + pf，netem 代理模式）

- 日期：2026-09-15 19:01:54 +0800；提交：`e97fe51`；负载 跑前 4.44 2.61 2.36 → 跑后 1.08 1.32 1.75
- 命令：`SWITCHER_NETEM=broker swift test --package-path Packages/SwitcherOutputs --filter 'MediaMTXTests/test(E7|E8|E9)'`（xctest 退出码 1；日志 `.build/gate3/net/xctest.log`）

| 测试 ID | 用例 | 结果 | 耗时 | 阈值（测试标准 §4） |
|---|---|---|---|---|
| E7 | `testE7_threeStreams_blockSecondFor30s_othersDropZero` | ✅ 通过 | 85.408 s | 其他路丢帧 0（硬性） |
| E8 | `testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect` | ❌ 失败 | 197.728 s | 10 次全部成功、≤ 15 s（目标 ≤ 5 s）；重连后 A2 达标 |
| E9 | `testE9_bandwidth70pct_5min_dropCountWithin5pct` | ✅ 通过 | 336.103 s | 误差 ≤ 5%（目标 ≤ 1%） |

测试自己打印的数字（送出 / 落盘 / 网络丢帧 / 重连耗时）：

```
/Users/plus/plusmix/.claude/worktrees/wonderful-fermi-40fe5f/Packages/SwitcherOutputs/Tests/StreamingTests/MediaMTXTests.swift:269: error: -[StreamingTests.MediaMTXTests testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect] : failed - 封住 30.0 s 还没判断线
t=18 s 第 2 路判断线：backoff(1, 1.0s)
t=40 s 第 2 路重连成功，放开后 0.67 s
第 1 路：StreamCounters(framesReceived: 3600, framesSent: 3600, keyframesSent: 30, networkDropped: 0, droppedQueueFull: 0, droppedWaitingKeyframe: 0, droppedDisconnected: 0, discardedOnDisconnect: 0, lostInTransport: 0, audioPacketsReceived: 2812, audioPacketsSent: 2812, audioDropped: 0, bytesSent: 46219513, connectAttempts: 1, reconnects: 0, disconnects: 0, lastReconnectSeconds: 0.0, maxReconnectSeconds: 0.0, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 226439, state: stopped)，编码器 skipped 0
第 1 路落盘：(frames: 3599, dropped: 0, gaps: 0, undecodable: 0)
第 3 路：StreamCounters(framesReceived: 3600, framesSent: 3600, keyframesSent: 30, networkDropped: 0, droppedQueueFull: 0, droppedWaitingKeyframe: 0, droppedDisconnected: 0, discardedOnDisconnect: 0, lostInTransport: 0, audioPacketsReceived: 2812, audioPacketsSent: 2812, audioDropped: 0, bytesSent: 46219513, connectAttempts: 1, reconnects: 0, disconnects: 0, lastReconnectSeconds: 0.0, maxReconnectSeconds: 0.0, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 194637, state: stopped)，编码器 skipped 0
第 3 路落盘：(frames: 3599, dropped: 0, gaps: 0, undecodable: 0)
第 2 路：StreamCounters(framesReceived: 3600, framesSent: 1911, keyframesSent: 17, networkDropped: 1811, droppedQueueFull: 2, droppedWaitingKeyframe: 125, droppedDisconnected: 1502, discardedOnDisconnect: 60, lostInTransport: 122, audioPacketsReceived: 2812, audioPacketsSent: 1489, audioDropped: 1323, bytesSent: 24593551, connectAttempts: 3, reconnects: 1, disconnects: 1, lastReconnectSeconds: 22.038100083, maxReconnectSeconds: 22.038100083, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 0, state: stopped)
  断线判定用了 9.1 s：backoff(1, 1.0s)
  第 1 次重连成功：放开后 1.12 s
#                                                     也不受 sudo 5 分钟凭证过期影响（E9 一跑 5 分钟）。Ctrl-C 退出时自动 clear。
# E7 / E8：先起三个 MediaMTX 实例（见 scripts/mediamtx.yml 头部），推三路到 1935 / 1936 / 1937，然后
#   sudo scripts/netem.sh block 1936 30        → 第 2 路断 30 s；第 1、3 路丢帧应为 0，第 2 路 30 s 后自动重连。
# E9：sudo scripts/netem.sh limit 1935 4200 300  → 6 Mbps 的流限到 70%，跑 5 分钟。
  断线判定用了 9.0 s：backoff(1, 1.0s)
  第 2 次重连成功：放开后 1.03 s
#   scripts/netem.sh cle/Users/plus/plusmix/.claude/worktrees/wonderful-fermi-40fe5f/Packages/SwitcherOutputs/Tests/StreamingTests/MediaMTXTests.swift:296: error: -[StreamingTests.MediaMTXTests testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect] : XCTAssertEqual failed: ("9") is not equal to ("10") - 10 / 10 在 15 s 内：[1.116330166, 1.032738166, 0.115713541, 20.233685458, 0.982203833, 0.101790541, 0.13217225, 0.149693208, 0.116327208, 1.0499335]
/Users/plus/plusmix/.claude/worktrees/wonderful-fermi-40fe5f/Packages/SwitcherOutputs/Tests/StreamingTests/MediaMTXTests.swift:297: error: -[StreamingTests.MediaMTXTests testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect] : XCTAssertEqual failed: ("9") is not equal to ("10")
  第 9 次重连成功：放开后 0.12 s
  断线判定用了 9.0 s：backoff(1, 1.0s)
  第 10 次重连成功：放开后 1.05 s
E8 重连耗时：["1.12", "1.03", "0.12", "20.23", "0.98", "0.10", "0.13", "0.15", "0.12", "1.05"]；断线判定：["9.1", "9.0", "9.1", "8.9", "9.1", "9.1", "9.1", "9.1", "9.0"]；StreamCounters(framesReceived: 11100, framesSent: 6722, keyframesSent: 60, networkDropped: 5491, droppedQueueFull: 19, droppedWaitingKeyframe: 1374, droppedDisconnected: 2445, discardedOnDisconnect: 540, lostInTransport: 1113, audioPacketsReceived: 8672, audioPacketsSent: 5226, audioDropped: 3446, bytesSent: 86276940, connectAttempts: 10, reconnects: 9, disconnects: 9, lastReconnectSeconds: 2.018793291, maxReconnectSeconds: 2.021028958, queueDepth: 0, audioQueueDepth: 0, inFlightBytes: 0, state: stopped)
```

生成时间：2026-09-15 19:12:20
