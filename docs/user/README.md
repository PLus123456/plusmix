# PlusMix 用户手册

PlusMix（代码名 Switcher：模块、命令行工具仍叫这个名字）是一个只跑在 Apple Silicon Mac 上的多机位导播台：编号的输入、PGM / PVW 两个监视器、Cut / Fade / Wipe / Zoom / Stinger 转场、
四个叠加通道、四条音频总线，输出到录制文件、推流平台、NDI、第二块显示器、虚拟摄像头和多画面。
本手册面向操作的人；想知道它内部怎么工作的看 [设计方案](../spec/导播台设计方案.md)，想验证它有多稳的看 [测试标准](../testing/README.md)。

English version: [en/](en/README.md).

## 目录

| 页 | 讲什么 |
|---|---|
| [概念](概念.md) | PGM / PVW、输入、转场、T-bar、FTB、叠加通道、总线、输出、Tally、节目文件、拍。主窗口各区域对应什么 |
| [输入](输入.md) | 八种输入各怎么接：摄像头 / 采集卡、DeckLink、屏幕、视频文件、图片、NDI、纯音频设备、合成测试源；每种输入的状态；已知设备 |
| [输出](输出.md) | 录制（含 ISO 分路与磁盘保护）、推流、NDI 发送、外部输出、虚拟摄像头、多画面 |
| [快捷键](快捷键.md) | 默认快捷键表、改表、MIDI 映射、Stream Deck / Companion |
| [故障排查](故障排查.md) | 权限、无信号、磁盘、推流断线、NDI / DeckLink 没装、虚拟摄像头装不上、日志在哪 |

配套：[示例节目文件](../../Samples/README.md)（教会 / 教室 / 活动，打开就能跑）、[本地 API](../api/README.md)（写脚本、接控制面板）、[对接控制面板与 tally](../integrations/README.md)。

## 先跑起来

1. 编译并打开（要 Xcode，详见仓库 [README](../../README.md)）：

```bash
make gen build-app && open .build/DerivedData/Build/Products/Debug/PlusMix.app
```

2. 节目 › 打开… 选 `Samples/event/event.switcher.json`：四路合成源、多画面、四路 ISO 都配好了。
3. 键盘 `2` 把 2 号选到 PVW，`空格` Cut，`回车` 按已选转场（默认 Fade）切，`F` 渐黑。
4. 底栏"录制"开始录到 `~/Movies/PlusMix/活动/`，再按一次停。
5. 输入 › 添加输入…（⌘I）接上你的摄像头：第一次系统会问摄像头 / 麦克风权限；屏幕录制权限要自己去系统设置里给（[故障排查 › 权限](故障排查.md#1-权限)）。

## 版本与语言

本手册对应 PlusMix 0.1.0（第一版，见 [仓库 README](../../README.md) 的状态）。界面有简体中文和英文两种语言，跟随系统，偏好设置 › 语言可以改；本手册里的菜单名用中文界面的写法，英文写法在 [en/](en/README.md)。
