// SwitcherContracts —— 所有包共用的类型：时间、帧、音频块、输入、状态、命令、统计、节目文件、场景、测试图案。
//
// P1（分支 p1-contracts）在这里冻结契约。之后任何公开类型、JSON 字段名、测试图案布局的改动
// 都必须先在 docs/contract-changes/ 写提案（通用前言铁律 1）。每个类型"是什么、谁写、谁读、线程归属"
// 见 docs/CONTRACTS.md；这里的文档注释只讲该类型自己的规则。
//
// 文件一览：
//   Time.swift        HostTime / HostDuration / MachTimebase / Rational / FrameRate / Tick / TickClockSpec
//   Video.swift       PixelFormat / ColorInfo / RGB8 / YCbCr / Frame / ProgramFormat
//   Slots.swift       FrameSlot 协议 / AudioRing 协议（布局在 CSwitcherContracts/sw_audio_ring.h）
//   Input.swift       InputKind / InputState / InputSource / InputSettings / InputConfig / Input 协议
//   MixerState.swift  MixerState 及其子结构、Tally、MixerSnapshot
//   Command.swift     Command / IssuedCommand / CommandReceipt / MixerReducing
//   Stats.swift       stats.jsonl 的那一行
//   Show.swift        节目文件（schemaVersion = 1）与 migrate 占位
//   Scenario.swift    场景脚本
//   Render.swift      Renderer / RenderSink / FrameConsumer 协议草案，RenderedFrame，RenderInputTable
//   TestPattern.swift 合成视频图案（CPU 参考实现）
//   TestSignal.swift  合成音频信号（CPU 参考实现）
//   JSONValue.swift   占位字段用的通用 JSON 值
//   Version.swift     产品版本号（G5 改）
//   C/                CSwitcherContracts target：sw_audio_ring.h（音频环布局）+ layout.c（布局断言）

/// C 侧布局随 SwitcherContracts 一起导出：`import SwitcherContracts` 就能看到 `sw_audio_ring`。
@_exported import CSwitcherContracts
