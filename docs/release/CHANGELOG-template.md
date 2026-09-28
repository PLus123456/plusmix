# 变更日志

格式见 docs/release/versioning.md：每个版本一个 `## X.Y.Z — 日期` 小节，顶上永远有一个 `## 未发布`；小节内按 新增 / 变更 / 修复 / 已知问题 四类列条目，
每条写用户看得到的行为（不写内部重构），涉及测试标准里的指标就带上 ID（V6、A1…）。`scripts/release/bump-version.sh` 把"未发布"改成版本号 + 日期，
`scripts/release/changelog.sh X.Y.Z` 抽出一个小节给发布说明和 Sparkle 的更新说明。G5 从这个模板建仓库根的 CHANGELOG.md。

## 未发布

### 新增
- 多机位切换：PGM / PVW、Cut / Fade / Wipe / Zoom / Stinger、FTB，T-Bar。
- 输入：合成源、摄像头 / 采集卡、DeckLink、NDI、屏幕 / 窗口 / 应用、视频文件、图片、纯音频设备。
- 输出：录制（片段 .mov，可恢复）、ISO 分路、推流（RTMP / RTMPS / SRT）、NDI 发送、外部显示、多画面、虚拟摄像头。
- 控制：本地 HTTP / WebSocket API、快捷键、MIDI、Stream Deck 插件、Tally。
- 发布：Developer ID 签名与公证、Sparkle 自动更新、崩溃诊断与诊断包导出。

### 变更
- （无）

### 修复
- （无）

### 已知问题
- 见 docs/KNOWN_ISSUES.md。
