// SwitcherTally —— 外部 tally 输出基础（W3-D，设计方案 §9.4 Tally 行）。
//
// 只读快照：TallyFrame 由 MixerState.tallies 推导（全系统只算这一处，契约代码），不依赖 SwitcherControl。
// 输出：WebSocket JSON tally 流（每次 tally 变化一帧 + 心跳）和 GET 轮询。第二版的 TSL UMD 用同一份 TallyFrame。
//
// 文件一览：
//   TallyFrame.swift      帧结构（program / preview / 每路 {number, name, program, preview} / ftb / recording / streaming）+ JSON 编码器
//   TallyPublisher.swift  挂状态机的 SnapshotObserver → 只在 tally 变化时出一帧 → 扇出给订阅者（每个订阅者独立缓冲，慢的丢旧）
//   TallyServer.swift     Hummingbird：WS /tally（hello → 当前帧 → 变化帧 + 心跳）、GET /tally（最近一帧）
import SwitcherContracts

/// Tally 包版本随产品版本走。
public enum SwitcherTallyInfo {
    public static let version = SwitcherVersion.current
}
