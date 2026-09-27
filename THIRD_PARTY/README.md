# THIRD_PARTY —— 内嵌源码的第三方库许可证

设计方案 §11 选型表里以源码内嵌（SwiftPM C target）方式进仓库的库，每个一个目录：许可证原文 + 来源说明。
动态链接 / 随包分发的二进制库（NDI 运行库、Sparkle）也各占一个目录：许可证或声明 + SOURCE.md，二进制本身不进仓库；
它们怎么进发布包、包里的许可证目录（Contents/Resources/Licenses/）见 docs/release/third-party.md（W4-B）。

| 目录 | 库 | 版本 | 许可证 | 在哪个包 | 谁引入 |
|---|---|---|---|---|---|
| libsamplerate/ | libsamplerate | 0.2.2 | BSD-2-Clause | Packages/SwitcherAudio/Sources/CLibSamplerate | W1-D |
| libebur128/ | libebur128 | 1.2.6 | MIT | Packages/SwitcherAudio/Sources/CLibEBUR128 | W1-D |
| NDI/ | NDI® SDK 运行库 libndi.dylib（二进制，随发布包分发，不进仓库） | 打包机 SDK 的 Version.txt | NDI SDK License Agreement（再分发声明见 NOTICE.md） | 发布包 Contents/Frameworks（scripts/release/archive.sh） | W4-B |
| Sparkle/ | Sparkle 自动更新框架（SwiftPM 二进制 xcframework） | 2.10.0 | MIT | App（project.yml packages.Sparkle） | W4-B |

规则：上游源文件原样拷贝，不改一行；构建配置（例如 libsamplerate 的 config.h）另写文件放在同目录并注明。升级版本改这里的表和各目录的 SOURCE.md。
