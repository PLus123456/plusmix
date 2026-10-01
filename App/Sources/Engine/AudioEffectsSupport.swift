// 音频效果链有没有真的作用到声音（W5-B / prompt 87 建，88 / 102 各翻一个；界面"尚未生效"的横幅与"效果 (n)"计数读这里）。
// 常量名照 87（w5-app-safety）的：88 的 prompt 写的 busChainsApplied 是 87 落地之前的叫法。87 的版本另有 banner(applied:)，
// 它的本地化键只在 87 的 Localizable.strings 里，这里不带；G6 合并两边的同名新文件时取 87 的文件、把 busEffectsApplied 改成 true。
enum AudioEffectsSupport {
    /// 四条总线的效果链已经作用到声音：W5-C（prompt 88）接进了混音器每条总线的三个 AU 格（EQ = AUNBandEQ / 压缩 / 限幅）。
    static let busEffectsApplied = true
    /// 每路输入的效果链已经作用到声音：要在 C 热路径里加每路效果格（W1-D3 / prompt 102），之前仍是 false。
    static let inputEffectsApplied = false
}
