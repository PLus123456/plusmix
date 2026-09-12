// SwitcherAudio —— 混音循环（C 热路径）、重采样、效果链、表、设备层（W1-D / W2-E 填）。
import SwitcherContracts

/// P0 占位：证明模块能编译并链接到 SwitcherContracts。W1-D / W2-E 开工时删掉。
public enum SwitcherAudioSkeleton {
    public static let contractsVersion = SwitcherVersion.current
}
