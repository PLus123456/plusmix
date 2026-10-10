# 随发布包分发的第三方组件与许可证（prompt 71 第 8 条）

`scripts/release/archive.sh` 把每个组件的许可证原文放进 `PlusMix.app/Contents/Resources/Licenses/<组件>/`，仓库里 THIRD_PARTY/ 保留一份副本与来源说明。

| 组件 | 形式 | 许可证 | 我们要做的 | 在哪 |
|---|---|---|---|---|
| NDI® 运行库 `libndi.dylib`（Vizrt NDI AB） | 二进制，拷进 `Contents/Frameworks/`，用本产品身份重签 | NDI SDK License Agreement（http://ndi.link/ndisdk_license） | 随二进制分发 SDK 附带的 `libndi_licenses.txt`；保留版权与商标声明（"NDI® is a registered trademark of Vizrt NDI AB"）；商标写法按 SDK 的 NDI Brand Guidelines；只分发运行库不分发头文件 / 示例；不声称被 Vizrt 认证 | THIRD_PARTY/NDI/（NOTICE.md 逐条）；包内 Licenses/NDI/ |
| Sparkle 2.10.0 | `Sparkle.framework`（含 XPC、Autoupdate、Updater.app），用本产品身份重签 | MIT | 附带 LICENSE | THIRD_PARTY/Sparkle/；包内 Licenses/Sparkle/ |
| HaishinKit（RTMP / SRT 连接与封装） | 静态链进 SwitcherStreaming | BSD-3-Clause | 附带 LICENSE（二进制分发要保留版权声明） | 包内 Licenses/haishinkit.swift/（archive.sh 从 SwiftPM checkouts 拷） |
| libsrt（HaishinKit 自带的 xcframework） | 静态 | MPL-2.0 | 附带许可证；MPL 只要求改动它本身的源码公开，我们没改 | 包内 Licenses/haishinkit.swift/（随 HaishinKit 的 LICENSE；libsrt 的原文在其 xcframework 内） |
| swift-nio、hummingbird、swift-crypto、swift-collections、swift-log … | 静态 | Apache-2.0 / MIT | 附带 LICENSE | 包内 Licenses/<包名>/（archive.sh 从 checkouts 拷全部） |
| libsamplerate、libebur128 | 源码内嵌（SwitcherAudio） | BSD-2 / MIT | 附带 COPYING | THIRD_PARTY/；包内 Licenses/libsamplerate、libebur128 |

规则：THIRD_PARTY/README.md 的表要与这里一致；升级任何一项改两边。关于窗口 / 文档里出现 NDI 时写 "NDI®"，第一次出现带商标声明；
不用 NDI 商标做产品名或图标的一部分。SDK 的再分发许可写的是"可以把运行库嵌进你的产品分发"，头文件 / 文档 / 示例不许再分发——所以 SDK 不进仓库，
CI runner 与打包机各自安装（docs/release/ci.md）。没装 SDK 的机器编出来的包不含 NDI（Stats 标 unavailable，verify.sh 记 links_ndi=false）。

正式发布前问律师的两件事（设计方案 §0 也提了 VMixCompat）：NDI 商标的具体用法（关于面板的 credits 已有 NDI® 原句、版本、Apache-2.0 与"查看开源许可"链接（W5-A）；用户手册与随包 HTML 手册首次出现 NDI 时带商标声明）、Sparkle / HaishinKit 的署名放在关于窗口还是只放包内文件。
