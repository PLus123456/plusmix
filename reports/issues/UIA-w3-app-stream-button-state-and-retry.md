# 底栏推流按钮：一路起不来 / 重连时全起全停误伤其它路，状态文案不准

归属会话 / 分支：App 会话（W3-E 系）；推流状态字段要不要加进 Stats 归契约提案（见 04-待拍板 Q13）
发现于：界面对照调研 UIA，提交 c836cce；R7-M02 / M04，核对 VF1 §1 与 §4 第 1–4 条
现象：
1. 一路推流起不来（没地址 / scheme 不认 / StreamOutput 建不起来）时进 failed 表，Stats 报 idle，按钮显示英文原样"推流 · idle"；在推流页把地址改对也不会自动重试，必须先停再起（failed 只在 enabled 变 false 时清）。
2. 这一路 enabled 仍为真，所以再点推流按钮 = "有在跑的就全停"，把正常的几路一起停掉；想单独重试只能全停再全起。
3. 按钮文案只看第一个目的地（多路时第二路在重连也显示"● 推流中（2 路）"，"2 路"是目的地总数）；首次连接也显示"重连中（第 1 次）"；括号里的 n = reconnects + 1，而 reconnects 只在重连成功后才加，所以一直连不上的路永远是"第 1 次"。
4. 录制按钮同样把 idle / stopping / failed 原样塞进"录制 · %@"。
5. 推流页"重连上限 n s"其实是两次重试之间的最长等待（App 里重连不限次数），容易被理解成"超过就放弃"；docs/user/输出.md:60 同样含糊。
复现步骤：加两个推流目的地，一个填不存在的服务器；点底栏推流；再点一次。
严重级：S2
猜测原因：`App/Sources/UI/BottomBarView.swift:143-167`（取 streams.first、streams.count、reconnects + 1）、`:215-224`（streamPressed 全起全停）；`App/Sources/Engine/OutputRuntime.swift:222-234`（failed 与 enabled）、`:512-532`、`:742`；`Packages/SwitcherOutputs/Sources/Streaming/StreamOutput.swift:97-98`、`:388-389`；`App/Resources/zh-Hans.lproj/Localizable.strings:177`、`:562`。
建议改法：推流改"⚙ 主体 ▴"三段，▴ 里每个目的地一项（状态 + 码率，点 = 单路起停）+ 全部开始 / 全部停止；按钮按最差状态汇总；state 全走本地化；"重连上限"改叫"最长重试间隔"；推流页每个目的地加状态行与开关；起不来的路写明原因、改对地址后自动重试。见 docs/ui-study/01a-改动总表.md L1–L4、L13，K11（录制按钮文案）；缺陷编号 docs/ui-study/02-功能缺口.md X02、X11、X37、X38。
