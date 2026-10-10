# 写手册时对着代码查出来的几处 App 行为缺口（外部显示 Esc 删输出、无信号不说原因、NDI® 横幅、备用目录提示）

归属会话 / 分支：App 会话（W5-I / W5-H / W5-K 系：`App/Sources/Engine/AuxOutputRuntime.swift`、`App/Sources/Settings/OutputPagesViews.swift`、`App/Sources/UI/InputCellView.swift`、`App/Resources/*/Localizable.strings`、`App/Sources/Engine/OutputRuntime.swift`）；第 1 条也碰 `Packages/SwitcherOutputs/Sources/External/ExternalDisplayWindow.swift`。哪一路顺手由检查点定
发现于：W4-C2（prompt 103，分支 `w4-docs-2`）写 输入 / 输出 / 故障排查 三页时，核对 agent 对着 main 93f50d9 的代码逐句查出；手册已经照现状写（含警告和绕法），这里记实现上要不要改
现象：
1. **外部显示窗口里按 Esc = 删掉这一路输出（连同设置）**：`ExternalDisplayWindow` 的 `onKey` 收到 Esc 调 `onCloseRequested`（ExternalDisplayWindow.swift:138-141），
   `AuxOutputRuntime` 把它接成 `.removeOutput(output:)`（AuxOutputRuntime.swift:44）。现场在投影 / 副屏窗口上按一下 Esc，这块屏的配置（显示器、来源）就没了，节目没有撤销。
   设置 › 外部显示 每一路底下的按钮写"关闭这路"/"Close"，做的也是 `removeOutput`（OutputPagesViews.swift:577）——字面像"关掉"，实际是删除；路由菜单里同一件事叫"删除 n …"。
   之前的手册和 docs/checklists/G4.md:60 都写"Esc 关闭（窗口）"。
2. **无信号的格子从不说在等什么**：`InputState.noSignal` 不带文案（SwitcherContracts/Input.swift:16-21），格子只写"无信号"/"等音频设备…"（InputCellView.swift:347）；
   各输入自己的 `lastError`（"设备已断开，等待重新连接"、"没有找到 DeckLink 驱动：…"、"网络上找不到 NDI 源 …"，CameraInput.swift:343、DeckLinkInput.swift:272、NDIInput.swift:341、AudioDeviceInput.swift:507）App 里没有任何地方读。
   docs/checklists/G4.md:15 / :20、G7.md:57 / :59 都按"格子显示这句"写验收项，跟实现不符（这两份是检查点的记录，W4-C2 没动）。
3. **NDI® 横幅许诺"装好之后这一路会自己好"**：`addInput.banner.ndi.message`（zh：…"装好之后这一路会自己好"；en：…"it starts working once the runtime is installed"）。
   横幅只在 `SwitcherNDIInfo.isSDKAvailable == false` 时挂（AddInputSupport.swift:127-128），而那是编译期开关（`sw_ndi_sdk_compiled()`，SwitcherNDI.swift:28）：这份 App 里装运行库也不会好，要换带 SDK 编的 App。
   DeckLink SDK 的横幅（"请换用带 DeckLink 支持的版本"）写对了，可以照它改。
4. **低于磁盘下限切备用目录时提示写"磁盘满"**：`belowMinimum` 有备用目录时走 `switchToFallback`（OutputRuntime.swift:524-529），提示统一是 `notice.recordingFallback`"录制 n：磁盘满，已切到备用目录：…"（SwitcherSession.swift:407），盘其实没满。
   建议区分两种原因（例如"低于下限 n MB，已切到备用目录"）。
复现步骤：
- 1：开一路外部显示（底栏"外部显示"主体，有第二块屏），点一下那块屏上的窗口、按 Esc → 设置 › 外部显示 里这一路没了；`curl -s 127.0.0.1:8765/api/v1/state | jq '.state.outputs[] | select(.kind=="externalDisplay")'` 为空。
- 2：添加输入 › NDI® 手填 `不存在的机器 (Nope)` → 格子只写"无信号"。
- 3：在没装 NDI SDK 的机器上编 App，打开添加输入 › NDI® 看横幅。
- 4：设置 › 高级 把磁盘下限调到比当前剩余空间大、设一个备用目录，开始录制。
严重级：S2（1：现场一键丢配置，且按钮文字误导）；S3（2、3、4）
建议：
1. Esc 只关窗口 / 把这一路 `enabled = false`（配置留着，和路由菜单的"关闭"一致），"关闭这路"改名"删除这一路"或改成只关；改了告诉文档会话删掉 输出 / outputs §4 的两处警告。
2. 格子在 noSignal 时把那一路的 `lastError` 作为第二行或悬停提示（要从 InputRuntime 把它带到界面；不改契约也能做）；改了文档会话把 输入 / 故障排查 §2 的"格子只写无信号"改回去，检查点清单也就对上了。
3. NDI® 横幅照 DeckLink SDK 那条改成"这一版编译时没带 NDI® SDK，请换用带 NDI® 支持的版本"；改了告诉文档会话删掉 输入 / 故障排查里"那句不成立"的注。
4. 见上。
