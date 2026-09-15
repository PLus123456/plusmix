// 与 Compositor.metal 共享的结构。字段顺序和类型必须与 .metal 里的 DrawUniforms 逐一对应；
// 两边各有一个大小断言（Metal 112 字节 static_assert，这里 MemoryLayout 检查）。
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
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0

    /// 与 .metal 的 static_assert 对应。
    static let expectedStride = 112
}

/// 片段着色器的分支；值与 .metal 的 DrawFormat 一致。
enum DrawFormat: Int32 {
    case bgra = 0
    case nv12 = 1
    case uyvy = 2
    case solid = 3
    case label = 4
}
