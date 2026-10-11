# 文件输入不支持纯音频文件（mp3 / wav / m4a / aac 加上就报"文件里没有视频轨"）

归属会话 / 分支：W2-A 系（SwitcherInputs/File：FileInput / FileDecoder）
发现于：W5-K 面板改版（w5-app-panels，prompt 97 交付 1 / 04 Q57），读 `Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileDecoder.swift`
现象：Q57 定"背景音乐这类纯音频文件放宽'视频文件'输入：接受 mp3 / wav / m4a / aac，加出来按纯音频格子显示（话筒 + 表），继续用 .file 来源"。
      App 这边 97 已经做了：视频文件页的打开面板收这四种扩展名、文件信息写"纯音频 · AAC · 48 kHz · 2 声道 · 3:20"、格子按纯音频画（话筒 + 电平表，
      `InputCellView.isAudioOnly`）。但 `FileAsset.init(url:)`（FileDecoder.swift:70）没有视频轨就抛 `Failure.noVideoTrack`，
      所以加出来的那一路运行状态是 error"文件里没有视频轨"，没有声音。App 页上已写明（`addInput.file.audioOnlyNote`，指向本问题单）。
复现步骤：添加输入 › 视频文件 › 选一个 .m4a / .wav → 添加 → 格子显示话筒和"文件里没有视频轨"，调音台这一路没有表。
严重级：S3（功能缺口；Q57 的倾向做法，0.1.x）
建议改法：FileAsset 允许只有音轨（`video == nil` 时不建 AVAssetReaderTrackOutput 视频那一路、帧槽不推帧，与纯音频设备输入同一口径：引擎挑不到帧画黑场）；
      音轨照现在的路径解码、按节目时钟送环（播完动作 / 速率 / 循环照用）；`FileInputCounters` 的视频计数为 0。
      测试：Tests/Fixtures 加一个几秒的 m4a，`FileInputTests` 加"纯音频文件 live、环里有样本、循环回绕"；App 侧 `AddInputRevampTests.testPanels_addInputAcceptsAudioFilesShownAsAudioOnly`
      现在只验到"按纯音频格子画、页上写明"，FileInput 支持之后可以加一条端到端（加 m4a → 调音台条子有表）。

## W5-N（prompt 101）没连带做（2026-10-11）

G7 追加 ④ 写"播放控制若连带做纯音频文件请一并解"，但 101 的目录许可写明 SwitcherInputs/File 只做"播放命令的接线与就地改结束动作 / 速率，**不动解码路径**"：
支持纯音频要改 `FileAsset.init`（允许没有视频轨）、`decodeLoop`（不建视频那一路）和 `paceLoop`（锚点现在等解码线程给出**视频**首帧才定，纯音频要改成等音频首块），
都在解码 / 推帧路径上，所以没做，仍归 W2-A 系。W5-N 的格子 ⏮ / ▶⏸ / 🔁 对这类输入是亮的（来源是 .file），但这一路本身是 error，按了没有效果。
