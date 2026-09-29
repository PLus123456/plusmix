# NDI® 运行库（libndi.dylib）——随发布包分发的声明

NDI® is a registered trademark of Vizrt NDI AB. 本产品使用 NDI® SDK 提供 NDI 发送与接收；运行库 `libndi.dylib` 按 NDI SDK 许可协议
（SDK 目录里的 "NDI SDK License Agreement.pdf"，在线版 http://ndi.link/ndisdk_license）以二进制形式随本产品再分发，未做任何修改。

再分发条款里我们照做的几条（docs/release/third-party.md 有逐条对照）：
1. 随二进制一起分发 SDK 附带的 `libndi_licenses.txt`（本目录有一份副本；发布包里在 `PlusMix.app/Contents/Resources/Licenses/NDI/`）。
2. 保留 Vizrt 的版权与商标声明；在产品文案中出现 "NDI" 时按 SDK 的 "NDI Brand Guidelines.pdf" 使用注册商标符号与写法（关于窗口 / 文档：“NDI® is a registered trademark of Vizrt NDI AB”）。
3. 不重新分发 SDK 的头文件、文档、示例，只分发运行库；运行库由本产品的 Developer ID 重签（硬化运行时的库校验要求，SDK 许可允许以二进制形式嵌入）。
4. 不声称本产品由 Vizrt 认证 / 背书；不用 NDI 商标做产品名的一部分。

来源：SDK 版本见 SOURCE.md；用户没装 SDK 的机器上，Package.swift 自动把 NDI 编成空实现，Stats 标 `unavailable`，发布包不受影响（运行库随包）。
