// 从显示纹理取一点的颜色（W5-K，H6：抠像"在画面上取色"取 3×3 平均）。
import Metal
import SwitcherContracts

enum PixelSampler {
    /// 纹理上以 (x, y) 为中心 3×3 的平均（BGRA8；贴边只平均落在纹理里的那几个）。
    static func average3x3(texture: any MTLTexture, queue: any MTLCommandQueue, x: Int, y: Int) -> RGB8? { nil }
}
