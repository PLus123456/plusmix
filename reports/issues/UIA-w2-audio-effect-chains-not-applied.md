# 每路与总线的音频效果链"界面能调、声音不变"：音频引擎不读 effects

归属会话 / 分支：音频集成会话（W2-E 系，`Packages/SwitcherAudio/Sources/Integration/` + `App/Sources/Engine/`）；界面标注与手册分别归 App 会话、文档会话（W4-C 系）
发现于：界面对照调研 UIA，提交 c836cce；三份区域报告独立发现（R4-G27、R6-M02 / G01 / G02、R8-S18 / S19），两份核对确认（附录/核对-VF1、核对-VF3）
现象：调音台总线条"效果 (n)"和输入设置"效果链"一节都能编辑 EQ / 压缩 / 限幅，状态机也收 setBusEffects / setInputSettings，但听不出任何变化。用户手册 docs/user/概念.md:78 写"四条总线各有增益 / 静音 / 效果链"。
复现步骤：给 Master 加一段 +12 dB 的 EQ 或把限幅预增益拉满，监听 / 录一段，与关掉时对比，没有差别。
严重级：S1（功能错但节目能继续；设计方案 §1.2 承诺了"每输入 EQ / 压缩"）
猜测原因：已查实。
- `Packages/SwitcherAudio/Sources/Integration/AudioEngine.swift:463-489`：applySettings 只落增益 / 静音 / 独听 / 声像 / 路由 / 延迟，applyBuses 只落增益 / 静音；集成层和 App/Sources/Engine 里没有任何地方读 effects。
- `installEffect` / `installStandardEffects`（`Packages/SwitcherAudio/Sources/SwitcherAudio/BusEffectChain.swift:83`、`:112`）只有单元测试在调；C 端每条总线已有 EQ → 动态 → 限幅三格（`sw_mix.c`），每路没有效果格。
- reports/w3-app2.md:56 当时就写了"音频引擎暂不读效果"，reports/w2-audio-integ.md:130 把"效果链参数 → AU 参数"列为后续，没排进任何会话。
- 另：编辑器范围超出苹果 AU 范围（阈值 −60 vs AU −40；EQ 增益 ±24 vs ±20），界面能加 3 段 EQ 而每条总线只有 1 个单段 AUParametricEQ（附录 R6 B4，VF3 已核）。
建议改法：先让界面不说谎（效果页与总线条标"尚未生效"、计数不亮、手册改），再按 docs/ui-study/04-待拍板.md Q02 / Q09 / Q10 的定案接线：总线三格映射（M）→ 每路效果格（L，C 热路径，守铁律 3）。接线前按铁律 10 写探针量 AUGraphicEQ / AUNBandEQ 的频点与范围。
