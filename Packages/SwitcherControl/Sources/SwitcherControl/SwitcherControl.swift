// SwitcherControl —— 命令总线、HTTP / WS API、快捷键、MIDI；Tally 随状态推送（W2-C）。VMixCompat 独立 target 默认关（W3-D）。
//
// 只依赖 SwitcherCore（Contracts + Engine 的 StateMachine）和 Hummingbird 2 / hummingbird-websocket（Apache-2.0）。
//
// 文件一览：
//   CommandBus/CommandBus.swift        统一入口：校验 → sequence / issuedAt → StateMachine.submit → 回执（appliedTick）→ 观察者
//   CommandBus/CommandValidator.swift  结构性校验（引用不存在的输入 / 输出、通道越界、负时长……），给 API 的 400 一个理由
//   CommandBus/CommandCatalog.swift    27 个 case 的目录（穷举 switch 钉住）+ 样例；docs/api.md 由它生成（switcher-apidoc）
//   API/APIServer.swift                GET /api/v1/state、POST /api/v1/command、GET /api/v1/commands、WS /api/v1/events；token 鉴权
//   API/StateFeed.swift                状态快照 → 事件流（整快照 + 版本号）+ 每秒 Stats；每拍观察者 / 总线观察者唤醒，不轮询
//   API/APIModels.swift                报文结构（键名与 Codable 一致）
//   API/APIDocument.swift              docs/api.md 生成器
//   Hotkeys/KeyCombo.swift             组合键解析 / 归一化；KeyCombo(event:)（AppKit）
//   Hotkeys/ControlAction.swift        快捷键 / MIDI Note 共用的动作（命令或开关型，按快照解析成命令）
//   Hotkeys/HotkeyTable.swift          JSON 表、默认表（数字 PVW / Shift 数字 PGM / 空格 Cut / 回车 Auto / F FTB）、冲突检测、用户配置位置
//   Hotkeys/HotkeyDispatcher.swift     组合键 → 命令 → 总线
//   MIDI/MIDIMapTable.swift            触发（CC / Note）→ 动作（tbar / 推子 / 命令）的 JSON 表
//   MIDI/MIDIMapper.swift              UMP 解析、映射纯函数、T-bar 换向
//   MIDI/MIDIController.swift          CoreMIDI 客户端（run loop 线程）、热插拔、learn、顺序派发
//   MIDI/VirtualMIDISource.swift       虚拟源（自测 / 软件推杆）
import SwitcherContracts

/// 控制包版本随产品版本走。
public enum SwitcherControlInfo {
    public static let version = SwitcherVersion.current
}
