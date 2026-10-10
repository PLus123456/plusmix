// 音频效果链有没有真的作用到声音（W5-B，01a J1 / H2，02 X06 / X07：先让界面不说谎）。
// 界面能编辑 EQ / 压缩 / 限幅、节目文件也存，但这一版的音频引擎不读 effects（applySettings / applyBuses 只落增益 / 静音 / 路由……），调了听不出变化。
// 88（W5-C，2026-10-01）已把总线三格接进混音器（EQ = AUNBandEQ / 压缩 / 限幅，延迟在泵里补），G6 合并时把 busEffectsApplied 翻成 true；102（W1-D3）接上每路效果格时翻 inputEffectsApplied；
// 翻了之后总线条的"效果 (n)"计数恢复、"尚未生效"的横幅自动消失（MixerModel / InputSettingsModel 读这里）。
enum AudioEffectsSupport {
    /// 四条总线的效果链已经作用到声音：W5-C（prompt 88）接进了混音器每条总线的三个 AU 格。
    static let busEffectsApplied = true
    /// 每路输入的效果链已经作用到声音：W1-D3（prompt 102）在 C 热路径里给每路加了 EQ / 动态两格，`InputSettings.effects` 由音频引擎按最新快照落下去。
    static let inputEffectsApplied = true

    /// 没接上时效果页顶部的横幅；接上了为 nil。
    static func banner(applied: Bool) -> String? { applied ? nil : L("effects.notEffective") }
}
