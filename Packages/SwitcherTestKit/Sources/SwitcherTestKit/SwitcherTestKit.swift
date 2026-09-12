// SwitcherTestKit —— 合成视频 / 音频源、StatsWriter / StatsSummary、ScenarioRunner（W1-A 填）。
import SwitcherAudio
import SwitcherContracts
import SwitcherControl
import SwitcherEngine
import SwitcherInputs
import SwitcherOutputs
import SwitcherRender

/// P0 占位：证明 TestKit 能链接到它下面的全部包。W1-A 开工时删掉。
public enum SwitcherTestKitSkeleton {
    public static let contractsVersion = SwitcherVersion.current
    /// 下层各包的占位常量，链接不上任何一个都会编译失败。
    public static let linkedVersions: [String] = [
        SwitcherEngineSkeleton.contractsVersion,
        SwitcherRenderSkeleton.contractsVersion,
        SwitcherInputsSkeleton.contractsVersion,
        SwitcherAudioSkeleton.contractsVersion,
        SwitcherOutputsSkeleton.contractsVersion,
        SwitcherControlSkeleton.contractsVersion,
    ]
}
