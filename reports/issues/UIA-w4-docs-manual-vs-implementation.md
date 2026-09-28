# 用户手册与实现对不上的几处

归属会话 / 分支：文档会话（W4-C 系，`docs/user/`、`docs/integrations/`、`docs/api/`）；每条要么改实现（见各行的关联单）、要么改文档，二选一由 docs/ui-study/04-待拍板.md Q64 定
发现于：界面对照调研 UIA，提交 c836cce；R1、R6、R8 与核对 VF1 / VF3（已剔除核对后不成立的两条：FTB 时长那句没写错、tally.md:17 只是没写谁起服务）
现象：
1. docs/user/概念.md:78"四条总线各有增益 / 静音 / 效果链"——效果链不生效（UIA-w2-audio-effect-chains-not-applied）。
2. docs/user/输出.md:22 写容器可选 .mp4——选了没用（UIA-w1-outputs-record-container-and-source）。
3. docs/user/输出.md:46、docs/user/故障排查.md:36 说录制磁盘下限在"偏好设置"能改——偏好设置窗里没有，只有启动参数和 UserDefaults 键（`App/Sources/AppSettings.swift:10`、`:51-52`、`:115-116`）。
4. docs/user/快捷键.md:78 按 App 也有只读 tally 流（:8766）写——App 不起 TallyServer，只有 headless 带 `--tally-port` 才起（`App/Sources/Engine/ControlRuntime.swift:59-69`；project.yml 的 App 依赖里没有 SwitcherTally）；docs/integrations/tally.md:17 没写明谁起它。
5. docs/user/输出.md:60"重连上限默认 30 s"——实际是两次重试之间的最长等待，App 里重连不限次数；:63 说"状态行显示"重连，实际显示在底栏推流按钮上。
6. docs/user/故障排查.md:68 让用户跑 caffeinate 防睡眠，命令缺 `-u`；App 自己不防睡眠 / App Nap（仓库里没有 beginActivity / IOPMAssertion）。
7. docs/user/输入.md:95 说输入设置的音频一节有"跟随视频"开关——设置窗里没有（调音台条子上有）。
8. NDI 在界面和手册里都没写 ®（THIRD_PARTY/NDI/NOTICE.md:8）。
9. 对外 API 文档与实现矛盾：docs/api.md:423、docs/integrations/vmix-compat.md:16（附录/核对-VF3 §4）。英文手册 docs/user/en/ 同样几处要一起改。
严重级：S3
建议：按 Q64 的倾向，能补实现的补实现（设置里加录制下限 / 备用目录、tally 开关、防睡眠），其余照实改文档；中英两份一起改。
