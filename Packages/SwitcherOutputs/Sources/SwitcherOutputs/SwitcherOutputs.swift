// SwitcherOutputs —— 编码、录制、推流、NDI 发送、外部显示、虚拟摄像头桥（W1-E / W2-D / W3-C 填）。
import SwitcherContracts

/// P0 占位：证明模块能编译并链接到 SwitcherContracts。W1-E / W2-D / W3-C 开工时删掉。
public enum SwitcherOutputsSkeleton {
    public static let contractsVersion = SwitcherVersion.current
}
