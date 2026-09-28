## 78 W2-C2 MIDI 热插拔在换过节目（第一个 session 停过）之后失效（用户 2026-09-28 指派 agent 直接做）
分支：w2-control-2（从 main 开）。只准动：Packages/SwitcherControl/Sources/SwitcherControl/MIDI/、Packages/SwitcherControl/Tests/SwitcherControlTests/、Hotkeys/HotkeyTable.swift（只改 UserConfig 的目录名）、API/APIServer.swift（只改 serverName）。
先读：reports/issues/W3E-w2-control-midi-hotplug-after-restart.md、reports/w2-control.md §5 第 5 条（CoreMIDI 通知只送到建客户端那条线程的 run loop）。

交付：
1. 先写红测试：起 MIDIController → 停 → 再起 → 创建虚拟源 → 必须自动连上（现在连不上）；连停三次都要能收到增删通知。
2. 修：MIDI 客户端 / 通知 run loop 放在进程级、长期存活的线程上（或每次 start 重建客户端并确保通知块所在 run loop 在跑），stop 只摘端口不杀通知源；命令仍经原来的 AsyncStream 顺序提交，CC 不乱序。
3. 验证：MIDI 全部既有用例 + 新用例过；`make lint BRANCH=w2-control-2`。
4. 产品改名 PlusMix 的包内跟改（issue W4D-packages-user-visible-code-name-leftovers）：`UserConfig.directory` 的子目录 "Switcher" → "PlusMix"（`~/Library/Application Support/PlusMix`，0.1.0 没发布过、不做迁移；相关用例跟改）、`MIDIController` 默认 clientName、`APIServer` 的 serverName → "PlusMix"。App 侧若写死了旧目录由 W3-E5 跟（报告里写明查到的调用点）。
不做：映射表格式、契约。报告 reports/w2-control-2.md。不 push、不 merge。
