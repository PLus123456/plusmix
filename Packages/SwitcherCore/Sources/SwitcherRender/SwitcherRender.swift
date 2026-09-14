// SwitcherRender —— Metal 合成、RGB→NV12、MetalDisplayView。
// 入口：MetalRenderer（实时，实现 SwitcherContracts.Renderer）、OfflineRenderer（离线，V8 / V9）、MetalDisplayView / PreviewWindow（显示）。
import SwitcherContracts

/// P0 占位，SwitcherTestKit 的骨架还引用它（W1-A 并行开发中）；G2 合并时连同各包骨架一起拆。
public enum SwitcherRenderSkeleton {
    public static let contractsVersion = SwitcherVersion.current
}
