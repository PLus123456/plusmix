// 音频效果链有没有真的作用到声音（W5-B，01a J1 / H2，02 X06 / X07：先让界面不说谎）。
// 界面能编辑 EQ / 压缩 / 限幅、节目文件也存，但这一版的音频引擎不读 effects（applySettings / applyBuses 只落增益 / 静音 / 路由……），调了听不出变化。
// 88（W5-C）把总线三格接上时把 busEffectsApplied 翻成 true，102（W1-D3）接上每路效果格时翻 inputEffectsApplied；
// 翻了之后总线条的"效果 (n)"计数恢复、"尚未生效"的横幅自动消失（MixerModel / InputSettingsModel 读这里）。
enum AudioEffectsSupport {
    /// 四条总线的效果链已经作用到声音。
    static let busEffectsApplied = false
    /// 每路输入的效果链已经作用到声音。
    static let inputEffectsApplied = false

    /// 没接上时效果页顶部的横幅；接上了为 nil。
    static func banner(applied: Bool) -> String? { applied ? nil : L("effects.notEffective") }
}
