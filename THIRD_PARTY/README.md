# THIRD_PARTY —— 内嵌源码的第三方库许可证

设计方案 §11 选型表里以源码内嵌（SwiftPM C target）方式进仓库的库，每个一个目录：许可证原文 + 来源说明。
动态链接的库（FFmpeg LGPL 等）不在这里，它们的许可证随发布工程（W4-B）处理。

| 目录 | 库 | 版本 | 许可证 | 在哪个包 | 谁引入 |
|---|---|---|---|---|---|
| libsamplerate/ | libsamplerate | 0.2.2 | BSD-2-Clause | Packages/SwitcherAudio/Sources/CLibSamplerate | W1-D |
| libebur128/ | libebur128 | 1.2.6 | MIT | Packages/SwitcherAudio/Sources/CLibEBUR128 | W1-D |

规则：上游源文件原样拷贝，不改一行；构建配置（例如 libsamplerate 的 config.h）另写文件放在同目录并注明。升级版本改这里的表和各目录的 SOURCE.md。
