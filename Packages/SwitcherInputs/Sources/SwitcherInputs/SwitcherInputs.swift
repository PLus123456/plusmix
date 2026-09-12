// SwitcherInputs —— 各输入实现（摄像头 / UVC、屏幕、文件、图片、纯音频；DeckLink、NDI 各自独立可选 target）（W2-A / W3-A 填）。
import SwitcherContracts

/// P0 占位：证明模块能编译并链接到 SwitcherContracts。W2-A / W3-A 开工时删掉。
public enum SwitcherInputsSkeleton {
    public static let contractsVersion = SwitcherVersion.current
}
