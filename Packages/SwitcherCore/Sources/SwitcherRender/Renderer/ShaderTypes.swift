// 与 Compositor.metal 共享的结构。字段顺序和类型必须与 .metal 里的 DrawUniforms 逐一对应；
// 两边各有一个大小断言（Metal 160 字节 static_assert，这里 MemoryLayout 检查）。
import simd

/// 一次 quad 绘制的全部参数。渲染线程在栈上填好后用 setVertexBytes / setFragmentBytes 送进命令缓冲区（不分配）。
struct DrawUniforms {
    /// 纹理：不透明度（rgb 与 a 同值，预乘）；纯色：预乘后的颜色。
    var tint: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    /// 单位正方形角 (0/1, 0/1) → NDC 的线性部分。
    var posMatrix: simd_float2x2 = simd_float2x2(diagonal: SIMD2(2, -2))
    /// 平移部分。
    var posOffset: SIMD2<Float> = SIMD2(-1, 1)
    /// uv = uvOrigin + corner × uvSize。
    var uvOrigin: SIMD2<Float> = SIMD2(0, 0)
    /// 翻转时为负。
    var uvSize: SIMD2<Float> = SIMD2(1, 1)
    /// 目标一个像素在 uv 里的跨度（超采样用）。
    var sampleStep: SIMD2<Float> = SIMD2(0, 0)
    /// NV12 色度平面尺寸。
    var chromaSize: SIMD2<Float> = SIMD2(1, 1)
    /// 每轴超采样次数 1 / 2 / 4。
    var taps: Int32 = 1
    /// DrawFormat。
    var format: Int32 = DrawFormat.bgra.rawValue
    /// 0 limited 1 full。
    var fullRange: Int32 = 0
    /// 0 BT.709 1 BT.601 2 BT.2020。
    var matrix: Int32 = 0
    /// 标签纹理数组切片。
    var slice: Int32 = 0
    /// 1 = 抠像（提案 009 的口径）。
    var keyer: Int32 = 0
    /// Wipe 遮罩：0 无，1 左→右，2 右→左，3 上→下，4 下→上，5 对角（WipeMode）。
    var wipeMode: Int32 = 0
    var pad0: Int32 = 0
    /// 目标纹理尺寸（像素），Wipe 遮罩按片段位置算用。
    var targetSize: SIMD2<Float> = SIMD2(1, 1)
    /// 键色的 (Cb, Cr)，归一化 −0.5…0.5。
    var keyChroma: SIMD2<Float> = SIMD2(0, 0)
    /// (完全抠掉的色度距离半径, 柔化带宽度)。
    var keyRange: SIMD2<Float> = SIMD2(0, 0)
    /// 键色色度的单位向量（CPU 算好，溢色抑制用；键色是灰时为 0）。
    var keyNormal: SIMD2<Float> = SIMD2(0, 0)
    /// 溢色抑制强度 0–1。
    var keySpill: Float = 0
    /// Wipe 擦边位置 0–1（= 进度）。
    var wipeEdge: Float = 0
    /// Wipe 软边宽度（占场的比例）。
    var wipeSoftness: Float = 0
    var pad1: Float = 0
    var pad2: SIMD2<Float> = SIMD2(0, 0)

    /// 与 .metal 的 static_assert 对应。
    static let expectedStride = 160
}

/// 片段着色器的分支；值与 .metal 的 DrawFormat 一致。
enum DrawFormat: Int32 {
    case bgra = 0
    case nv12 = 1
    case uyvy = 2
    case solid = 3
    case label = 4
}

/// Wipe 遮罩方向；值与 .metal 的 wipeMode 一致。
enum WipeMode: Int32 {
    case none = 0
    case leftToRight = 1
    case rightToLeft = 2
    case topToBottom = 3
    case bottomToTop = 4
    case diagonal = 5
}
