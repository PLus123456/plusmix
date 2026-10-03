# 耳机里听所选总线 / 2 声道设备上监听时临时占用 Master 声道：音频引擎还不支持

归属会话 / 分支：W1-D 系（SwitcherAudio：设备回调 sw_device_ioproc.c 的散射、或混音器的耳机总线）；接 App 的那几行归之后的 App 会话（界面与命令 97 已做）
发现于：W5-K 面板改版（w5-app-panels，prompt 97 交付 4 / 5；01a J7 / J8，02 X09 / V07）
现象：
1. **监听这条（J7）**：Master 条上要能选"耳机里听哪条总线"（Master / Bus A / Bus B / 耳机总线）。现在耳机输出只能是耳机总线自己（sw_mix.c 第 7 步：
   有独听时只听独听的，否则按每路的 H 送出），引擎没有"耳机输出 = 某条总线"的开关。97 做了界面（Master 条的监听菜单）和 App 侧入口
   `MixerModel.listen(_:)`，`MixerModel.listenToOtherBusSupported = false`：Master / Bus A / Bus B 三项灰着、写"要音频引擎支持（下一版）"。
2. **监听时临时占用 Master 声道（X09）**：2 声道设备（MacBook 内置输出、普通 USB 耳机）上耳机总线没有声道可出，独听 / PFL / AFL 都听不到。
   97 的音频设备页在 2 声道设备上写明"当前设备没有耳机声道"（调音台头部同一句），并给了这个选项（`AppSettings.borrowMasterForMonitor`，存本机），
   但页上写着"尚未生效"：`AudioOutputDevice.busMap` 是建设备时定死的（`let`），设备回调按它把 8 个逻辑声道散到设备声道，运行中换不了；
   而"临时"的意思是**只在有独听时**让设备的 1/2 放耳机总线、没有独听时放 Master——要在实时线程里按"这一块有没有独听"切换。
复现步骤：内置输出 → 调音台某路点"独听"→ 耳机里没声；Master 条监听菜单里 Master / Bus A / Bus B 是灰的。
严重级：S1（X09：2 声道设备上监听整个不能用；0.1.0 放行条件按 Q68 (a) 含 X08 / X09，用户 2026-10-03 定"97 / 102 做完再发"——X08 与 X09 的界面半 97 已做，
      X09 的引擎半在这张单上）
建议改法（不加锁、不分配，热路径照 W1-D 规则）：
- 设备客户端加一个"监听来源"原子量：`sw_device_client_set_monitor_source(c, logical_bus)`（控制线程写、IOProc 读，int32 原子），散射时耳机那两个逻辑声道
  （out_scratch[6], [7]）换成所选总线的 sum（Master 0/1、A 2/3、B 4/5）；`AudioEngine.setMonitorSource(_ bus: Bus)` 包一层，App 的 `MixerModel.listen` 调它。
- "占用 Master 声道"：再加一个原子开关 `borrow_master_while_solo`；IOProc 里 `solo_active`（混音器每块已经算了，sw_mix.c:935）为真且开关开着时，
  Master 那一对设备声道写耳机总线（而不是 Master）；没有独听时照常写 Master。录制 / 推流 / NDI 走的是消费者流，不受影响。
  App 侧：`AudioRuntime` 建引擎后按 `settings.borrowMasterForMonitor` 调一次，音频设备页的"尚未生效"那句跟着删。
- 测试：IntegrationTests 加"选 Bus A 监听 → 耳机声道的样本 = Bus A 的 sum""borrow 开、有独听 → 设备 1/2 = 耳机总线；独听关 → 回到 Master"，A7 违规 0 照跑。
