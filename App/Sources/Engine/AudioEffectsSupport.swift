// 音频效果"已经作用到声音"的开关表（prompt 87 建、88 / 102 各翻一个）：为 false 的那一类，界面在效果页顶部标"效果尚未作用到声音（本版本）"、
// 调音台"效果 (n)"计数不亮（标签本身由 87 的界面代码读这两个常量）。
enum AudioEffectsSupport {
    /// 四条总线的效果链（BusState.effects）：W5-C（prompt 88）接进了混音器每条总线的三个 AU 格（EQ = AUNBandEQ / 压缩 / 限幅），true。
    static let busChainsApplied = true
    /// 每路输入的效果链（InputSettings.effects）：要在 C 热路径里加每路效果格（W1-D3 / prompt 102），之前仍是 false。
    static let inputChainsApplied = false
}
