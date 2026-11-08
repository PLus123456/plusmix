# PlusMix 用户手册

PlusMix（代码名 Switcher：模块、命令行工具仍叫这个名字）是一个只跑在 Apple Silicon Mac 上的多机位导播台：编号的输入、PGM / PVW 两个监视器、Cut / Fade / Wipe / Zoom / Stinger 转场、
四个叠加通道、四条音频总线，输出到录制文件、推流平台、NDI®、第二块显示器、虚拟摄像头和多画面。（NDI® is a registered trademark of Vizrt NDI AB.）
本手册面向操作的人；想知道它内部怎么工作的看 [设计方案](../spec/导播台设计方案.md)，想验证它有多稳的看 [测试标准](../testing/README.md)。

界面按 0.1.x 改版后的样子写（工具条、三段式底栏、一个"设置"窗……）；0.1.0 的老界面对照见 [docs/ui-study/03](../ui-study/03-目视检查.md)。

English version: [en/](en/README.md).

## 目录

| 页 | 讲什么 |
|---|---|
| [概念](概念.md) | PGM / PVW、输入、转场与四个转场槽、T-bar、FTB、叠加通道、总线、输出、Tally、节目文件、拍；主窗口各区域（工具条、监视器、转场列、调音台、输入条、底栏、状态行）、菜单栏、提醒 / 统计窗 / 界面锁；音频效果与监听同步 |
| [输入](输入.md) | 添加输入面板；八种输入各怎么接：摄像头 / 采集卡、DeckLink、屏幕、视频文件（含播放控制）、图片、NDI®、纯音频设备、合成测试源；输入条与格子；每路输入的设置；已知设备 |
| [输出](输出.md) | 输出总览、录制（含 ISO 分路与磁盘保护）、推流（服务预设、质量、推流 / 录制状态窗、两种鉴权写法）、NDI® 发送、外部显示、虚拟摄像头、多画面 |
| [快捷键](快捷键.md) | 默认快捷键表、改表与选动作面板、hotkeys.json、MIDI 映射、Stream Deck / Companion / tally |
| [设置](设置.md) | 一个"设置"窗：本节目 / 本机两组页、什么时候生效、导出 / 导入 / 恢复默认、远程控制、Tally、性能与电源、高级；启动参数 |
| [故障排查](故障排查.md) | 权限、无信号、磁盘、推流（连接中 / 重连 / 起不来 / 鉴权）、NDI® / DeckLink / 虚拟摄像头、画面与声音、界面、API、日志与诊断、已知问题 |

配套：[示例节目文件](../../Samples/README.md)（教会 / 教室 / 活动，打开就能跑）、[本地 API](../api/README.md)（写脚本、接控制面板）、[对接控制面板与 tally](../integrations/README.md)。

App 里 帮助 › PlusMix 使用手册 打开的就是本手册（随 App 一起装的网页版，按界面语言打开中文或英文）。

## 先跑起来

1. 编译并打开（要 Xcode，详见仓库 [README](../../README.md)）：

```bash
make gen build-app && open .build/DerivedData/Build/Products/Debug/PlusMix.app
```

2. 节目 › 打开…（或工具条"打开"）选 `Samples/event/event.switcher.json`：四路合成源、多画面、四路 ISO 都配好了。
3. 键盘 `2` 把 2 号选到 PVW，`空格` Cut，`回车` 按当前转场槽（转场 1 · Fade 0.5 秒）切，`⌥2` 用转场 2（Wipe）切，`F` 渐黑；也可以点转场列的"转场 1–4"、格子上的"转场"或"Cut"，或者拖横放的 T-bar。
4. 底栏"录制"开始录到 `~/Movies/PlusMix/活动/`，再按一次停（先确认）。
5. 输入 › 添加输入…（⌘I）接上你的摄像头：第一次系统会问摄像头 / 麦克风权限；屏幕录制权限要自己去系统设置里给（[故障排查 › 权限](故障排查.md#1-权限)）。

## 版本与语言

本手册对应 PlusMix 0.1.x（见 [仓库 README](../../README.md) 的状态）。界面有简体中文和英文两种语言，跟随系统，设置 › 常规 › 语言 可以改（重开 App 生效）；本手册里的菜单名用中文界面的写法，英文写法在 [en/](en/README.md)。
