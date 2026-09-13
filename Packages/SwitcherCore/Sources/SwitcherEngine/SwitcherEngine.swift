// SwitcherEngine —— 节目时钟、帧槽、状态机、引擎骨架、统计（W1-B）。
//
// 只依赖 SwitcherContracts；渲染器（W1-C）和输出消费者（W1-E）通过 Contracts 里的协议接进来。
//
// 文件一览：
//   Clock/RealtimeThread.swift    pthread 封装：QoS + 可选的 time-constraint 实时策略
//   Clock/ProgramClock.swift      按 TickClockSpec 生成拍点，mach_wait_until 等待，跳拍计数，唤醒抖动记录
//   Sync/HazardPublisher.swift    单写多读的原子指针发布（hazard pointer），状态快照 / 输入表都用它
//   Sync/SPSCOverwriteRing.swift  无锁 SPSC 环，满则挤最旧；帧槽与消费者队列的底层
//   Slots/LockFreeFrameSlot.swift FrameSlot 协议的实现：容量 3，latest(atOrBefore:) 挑帧，统计
//   State/MixerReducer.swift      MixerReducing 的实现：reduce / advance 纯函数，全部 27 条命令
//   State/StateThreadExecutor.swift 状态机 actor 的专用线程执行器；渲染线程用原子量 + 信号量唤醒它
//   State/StateMachine.swift      持有 MixerState 的 actor：sequence 顺序、按拍准备快照、原子发布、转场事件
//   Engine/Engine.swift           时钟 → 快照 → 挑帧 → Renderer → 完成回调 → FrameConsumer → 计数
//   Engine/EngineCounters.swift   原子计数 + Stats 行的组装（铁律 4：统计只有这一份）
//   Engine/QueuedFrameConsumer.swift 消费者侧"自己的有界队列 + 自己的线程"的可复用实现
//   Show/ShowStore.swift          节目文件读写与 schemaVersion 逐级迁移框架
//
// 线程规则（设计方案 §3.2、§3.5；CONTRACTS.md §6）在各文件头逐条注明谁在哪个线程调什么。
import SwitcherContracts

/// 引擎包版本随产品版本走。
public enum SwitcherEngineInfo {
    /// 与 SwitcherContracts 同一个版本号。
    public static let version = SwitcherVersion.current
}

/// P0 占位的兼容别名：SwitcherTestKit 的 P0 占位（`SwitcherTestKitSkeleton.linkedVersions`）还引用它，
/// 单独在本分支上 `make build` 也要绿。W1-A 删掉那边的占位后，G2 把这个别名一起删。
public enum SwitcherEngineSkeleton {
    public static let contractsVersion = SwitcherEngineInfo.version
}
