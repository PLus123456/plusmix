// SwitcherControl —— 命令总线、HTTP / WS API、快捷键、MIDI、Tally；VMixCompat 独立 target 默认关（W2-C / W3-D 填）。
import SwitcherContracts

/// P0 占位：证明模块能编译并链接到 SwitcherContracts。W2-C / W3-D 开工时删掉。
public enum SwitcherControlSkeleton {
    public static let contractsVersion = SwitcherVersion.current
}
