// SwitcherAudio —— 混音循环（C 热路径）、重采样、效果链、表、设备层（W1-D）。
// 模块入口：AudioMixer（控制面）、CAudioRing（契约 AudioRing 的实现）、OfflineAudioDriver / NullOutputDevice（无声卡驱动）、
// AudioOutputDevice / AudioInputDevice（CoreAudio 设备层）、LoudnessMeter（离线分析）、RealtimeGuard（A7）。
import SwitcherContracts

/// P0 骨架占位。TestKit 的 P0 骨架仍引用它；W1-A 删掉那个引用之后这里可以删。
@available(*, deprecated, message: "P0 占位，W1-A 删掉 TestKit 里的引用后删除")
public enum SwitcherAudioSkeleton {
    public static let contractsVersion = SwitcherVersion.current
}
