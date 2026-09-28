# 界面文案合规：出现竞品模块名"VMixCompat"、没有 NDI® 声明、保存后标题变回代码名、开发术语进界面

归属会话 / 分支：App 会话（W3-E 系，`App/Resources/`、`App/Sources/`）；关于面板的许可 / 商标声明与发布工程（W4-B 系）一起看
发现于：界面对照调研 UIA，提交 c836cce；目视检查 V-13 / V-14、R1-M13、R3a-M20，核对 VF1 §4 第 10 条、VF3
现象：
1. 偏好设置里兼容层那一节的标题是"第三方 API 兼容层（VMixCompat）"，中英两份都有——铁律 6 的例外只放行代码里的模块名，不放行界面文案；`make lint` 放过它是因为这个 token 本身在白名单里。
2. 关于面板是系统标准面板，没有 credits：没有 NDI® 商标声明、没有开源许可入口。THIRD_PARTY/NDI/NOTICE.md:8 要求写在关于窗口或文档里；docs/release/third-party.md:18 以为关于窗口已经写了。界面和手册里的 NDI 也都没写 ®。
3. 保存 / 另存为之后窗口标题变成代码名"Switcher 0.1.0 — 名字"，和启动时的"PlusMix 0.1.0 — 名字"不一致——W4-D 改名时漏改的回归（reports/w4-rename.md:21 改了另外三处）。
4. 规格号、开发术语进了界面：测试标准 §2.1、设计方案 §0 / §9.3、BLOCKED-签名、AVCaptureDevice、ParametricEQ、`--api-listen`、AppleLanguages、环形缓冲、时钟从属、scheme、"bltn" 等（行号见 docs/ui-study/附录/目视检查-原始记录.md V-14）。
复现步骤：偏好设置滚到底；PlusMix › 关于；节目 › 另存为… 后看窗口标题；添加输入 › 音频设备看说明行。
严重级：S2（1、2 是发布合规）；3、4 为 S3
猜测原因：`App/Resources/{zh-Hans,en}.lproj/Localizable.strings:648`；`App/Sources/AppDelegate.swift:68`（orderFrontStandardAboutPanel 不带 options）；`App/Sources/AppController.swift:264`；V-14 所列各行。
建议改法：标题去掉模块名；关于面板加 credits（版本、Apache-2.0、"NDI® is a registered trademark of Vizrt NDI AB"、打开包内 Licenses/）；:264 改用 ProductName.display；文案改成面向操作员的说法、实现口径挪进手册。另建议 lint 规则扫 `.strings` 时不放行 VMixCompat 这个 token（规则归 P0 / 检查点）。
