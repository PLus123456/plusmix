// Aux 全分辨率画面的着色器与管线（W3-C2，G4 拟、用户 2026-09-22 批：本包自己画输入帧，不动渲染器）。
//
// 色彩换算与渲染器同一套：下面的 ycbcrToRGB / fetch 与 SwitcherRender 的 Compositor.metal 逐项相同——矩阵系数（BT.709 / 601 / 2020）、
// limited（16–235 / 16–240）与 full 的码值换算、4:2:0 色度水平左对齐（色度坐标 + 0.25 个色度像素）垂直居中、线性采样 + clamp_to_edge、
// 1:1 与放大走 float、缩小按目标像素足迹做 taps×taps 盒式滤波（taps 的选法同 Placement.fill：缩小 > 3 倍 4、> 1.5 倍 2）。
// 改那边的换算这里要跟着改；ExternalTests 的 testAux_inputWindowDrawsFullResolutionFrame 拿渲染器（OfflineRenderer）的同一帧逐像素对照，改漏了会红。
//
// 为什么是源码字符串、运行时编译：本 target 在 Package.swift 里没有资源声明（清单不归 W3-C2），.metal 文件进不了包。
// 编译一次约 80 ms（探针），`AuxPipeline.prepare` 在后台编，窗口在编好之前不取帧（不把没画的帧记成丢帧）。
// 数学模式 = fast：渲染器实际跑的是构建时编好的 default.metallib（swift build / Xcode 都把 Compositor.metal 编进包里，
// Metal 编译器默认 fast-math；RenderResources 里"运行时编译、.safe"那条只是没有 metallib 时的后备）。实验（报告 §1）：
// 随机色度的 1080p NV12 帧，.safe 编的这份与渲染器有 12 / 207 万像素差 1 LSB（单精度求值顺序不同、落在舍入边界上），.fast / .relaxed 逐像素相等。
@preconcurrency import Metal
import Foundation

/// 一次 Aux 绘制的参数，与着色器里的 `AuxUniforms` 逐字段对应（48 字节，两边都有大小检查）。
struct AuxUniforms {
    /// 单位正方形角 (0/1, 0/1) → NDC 的缩放。
    var posScale: SIMD2<Float> = SIMD2(2, -2)
    /// NDC 平移。
    var posOffset: SIMD2<Float> = SIMD2(-1, 1)
    /// NV12 色度平面尺寸（左对齐色度用）。
    var chromaSize: SIMD2<Float> = SIMD2(1, 1)
    /// 目标一个像素在 uv 里的跨度（缩小时的盒式滤波）。
    var sampleStep: SIMD2<Float> = SIMD2(0, 0)
    /// 0 BGRA、1 NV12、2 UYVY（与 Compositor.metal 的 DrawFormat 同值）。
    var format: Int32 = 0
    /// 0 limited、1 full。
    var fullRange: Int32 = 0
    /// 0 BT.709、1 BT.601、2 BT.2020。
    var matrix: Int32 = 0
    /// 每轴采样次数 1 / 2 / 4。
    var taps: Int32 = 1

    static let expectedStride = 48

    enum Format: Int32 {
        case bgra = 0
        case nv12 = 1
        case uyvy = 2
    }

    /// 把 sourceWidth × sourceHeight 的画面按比例放进 dest（像素矩形，原点左上）里居中（留黑边），目标 targetWidth × targetHeight。
    /// 几何与 Placement.fill（裁切 none、变换 identity）相同。
    static func fit(sourceWidth: Int, sourceHeight: Int, dest: CGRect, targetWidth: Int, targetHeight: Int) -> AuxUniforms {
        var u = AuxUniforms()
        let sw = Float(max(sourceWidth, 1)), sh = Float(max(sourceHeight, 1))
        let k = min(Float(dest.width) / sw, Float(dest.height) / sh)
        let fw = sw * k, fh = sh * k
        let x0 = Float(dest.minX) + (Float(dest.width) - fw) / 2
        let y0 = Float(dest.minY) + (Float(dest.height) - fh) / 2
        let tw = Float(max(targetWidth, 1)), th = Float(max(targetHeight, 1))
        u.posScale = SIMD2(2 * fw / tw, -2 * fh / th)
        u.posOffset = SIMD2(-1 + 2 * x0 / tw, 1 - 2 * y0 / th)
        let ratio = max(sw / max(fw, 1), sh / max(fh, 1))
        u.taps = ratio > 3 ? 4 : (ratio > 1.5 ? 2 : 1)
        u.sampleStep = SIMD2(1 / max(fw, 1), 1 / max(fh, 1))
        return u
    }
}

/// 着色器源码（Metal Shading Language）。
enum AuxShaderSource {
    static let text = """
    #include <metal_stdlib>
    using namespace metal;

    struct AuxUniforms {
        float2 posScale;
        float2 posOffset;
        float2 chromaSize;
        float2 sampleStep;
        int    format;      // 0 BGRA 1 NV12 2 UYVY
        int    fullRange;   // 0 limited 1 full
        int    matrix;      // 0 BT.709 1 BT.601 2 BT.2020
        int    taps;        // 1 / 2 / 4
    };
    static_assert(sizeof(AuxUniforms) == 48, "AuxUniforms 布局变了，同步改 AuxShaders.swift");

    struct AuxOut {
        float4 position [[position]];
        float2 uv;
    };

    // 单位正方形，四个角由 vertex_id 生成（0 左上 1 右上 2 左下 3 右下，triangle strip）
    vertex AuxOut auxVertex(uint vid [[vertex_id]], constant AuxUniforms &u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        AuxOut out;
        out.position = float4(corner * u.posScale + u.posOffset, 0.0, 1.0);
        out.uv = corner;
        return out;
    }

    // —— 以下两个函数与 SwitcherRender/Shaders/Compositor.metal 的同名函数逐项相同 ——

    /// YCbCr 码值（0–255 标尺）→ 非线性 RGB（0–1）。
    static inline float3 ycbcrToRGB(float3 codes, int fullRange, int matrixID) {
        float kr, kb;
        if (matrixID == 1)      { kr = 0.299;  kb = 0.114;  }   // BT.601
        else if (matrixID == 2) { kr = 0.2627; kb = 0.0593; }   // BT.2020
        else                    { kr = 0.2126; kb = 0.0722; }   // BT.709
        float kg = 1.0 - kr - kb;
        float y, cb, cr;
        if (fullRange != 0) {
            y  = codes.x / 255.0;
            cb = (codes.y - 128.0) / 255.0;
            cr = (codes.z - 128.0) / 255.0;
        } else {
            y  = (codes.x - 16.0) / 219.0;
            cb = (codes.y - 128.0) / 224.0;
            cr = (codes.z - 128.0) / 224.0;
        }
        float r = y + 2.0 * (1.0 - kr) * cr;
        float b = y + 2.0 * (1.0 - kb) * cb;
        float g = (y - kr * r - kb * b) / kg;
        return saturate(float3(r, g, b));
    }

    constexpr sampler linearSampler(coord::normalized, filter::linear, mip_filter::none, address::clamp_to_edge);

    /// 取一个采样点的预乘 RGBA。
    static inline float4 fetch(float2 uv, constant AuxUniforms &u, texture2d<float> tex0, texture2d<float> tex1) {
        switch (u.format) {
        case 0:
            return tex0.sample(linearSampler, uv);                       // BGRA，已预乘
        case 1: {
            float y = tex0.sample(linearSampler, uv).r * 255.0;
            // 4:2:0 色度水平左对齐（与偶数亮度样本共址）、垂直居中：色度坐标 = uv + (0.25 / 色度宽, 0)
            float2 cuv = float2(uv.x + 0.25 / u.chromaSize.x, uv.y);
            float2 c = tex1.sample(linearSampler, cuv).rg * 255.0;
            return float4(ycbcrToRGB(float3(y, c.x, c.y), u.fullRange, u.matrix), 1.0);
        }
        case 2: {
            // bgrg422：硬件给 (Cr, Y, Cb, 1)
            float3 s = tex0.sample(linearSampler, uv).rgb * 255.0;
            return float4(ycbcrToRGB(float3(s.g, s.b, s.r), u.fullRange, u.matrix), 1.0);
        }
        default:
            return float4(0.0);
        }
    }

    // 显示用：不透明（CAMetalLayer 是 opaque，预乘颜色落在黑底上 = rgb 本身）
    fragment float4 auxFragment(AuxOut in [[stage_in]], constant AuxUniforms &u [[buffer(0)]],
                                texture2d<float> tex0 [[texture(0)]], texture2d<float> tex1 [[texture(1)]]) {
        int taps = clamp(u.taps, 1, 4);
        if (taps == 1) {
            return float4(fetch(in.uv, u, tex0, tex1).rgb, 1.0);        // 1:1 或放大：采样点落在纹素中心时逐电平精确
        }
        float inv = 1.0 / float(taps);
        float4 acc = float4(0.0);
        for (int j = 0; j < taps; ++j) {
            for (int i = 0; i < taps; ++i) {
                float2 o = (float2(float(i), float(j)) + 0.5) * inv - 0.5;
                acc += fetch(in.uv + o * u.sampleStep, u, tex0, tex1);
            }
        }
        return float4(acc.rgb * (inv * inv), 1.0);
    }
    """
}

/// Aux 的渲染管线（每台设备一份，进程内共享）。`@unchecked Sendable`：建好之后不变，只读。
final class AuxPipeline: @unchecked Sendable {
    let device: any MTLDevice
    let state: any MTLRenderPipelineState
    /// 目标格式：与 MetalDisplayView / 渲染器的工作格式相同（BGRA8 gamma 域，决策 6）。
    static let targetFormat: MTLPixelFormat = .bgra8Unorm

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt64: AuxPipeline] = [:]
    nonisolated(unsafe) private static var compiling: Set<UInt64> = []

    private init(device: any MTLDevice) throws {
        precondition(MemoryLayout<AuxUniforms>.stride == AuxUniforms.expectedStride,
                     "AuxUniforms 的 Swift 布局（\(MemoryLayout<AuxUniforms>.stride)）与着色器不一致")
        let options = MTLCompileOptions()
        options.mathMode = .fast   // 与渲染器的 default.metallib 同一数学模式（见文件头），这样才逐像素相同
        let library = try device.makeLibrary(source: AuxShaderSource.text, options: options)
        guard let vertex = library.makeFunction(name: "auxVertex"), let fragment = library.makeFunction(name: "auxFragment") else {
            throw AuxRenderError.shader("找不到 auxVertex / auxFragment")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "switcher.aux"
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        d.colorAttachments[0].pixelFormat = AuxPipeline.targetFormat
        self.device = device
        state = try device.makeRenderPipelineState(descriptor: d)
    }

    /// 同步取（没有就当场编；测试和后台预编用）。
    static func shared(for device: any MTLDevice) throws -> AuxPipeline {
        lock.lock()
        if let p = cache[device.registryID] {
            lock.unlock()
            return p
        }
        lock.unlock()
        let p = try AuxPipeline(device: device)
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[device.registryID] { return existing }
        cache[device.registryID] = p
        return p
    }

    /// 不阻塞地取：还没编好为 nil。
    static func cached(for device: any MTLDevice) -> AuxPipeline? {
        lock.lock()
        defer { lock.unlock() }
        return cache[device.registryID]
    }

    /// 在后台编（已编好 / 正在编就什么也不做）。主线程只调这个，不等编译。
    static func prepare(for device: any MTLDevice) {
        let key = device.registryID
        lock.lock()
        if cache[key] != nil || compiling.contains(key) {
            lock.unlock()
            return
        }
        compiling.insert(key)
        lock.unlock()
        let box = DeviceBox(device)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = try? AuxPipeline.shared(for: box.device)
            lock.lock()
            compiling.remove(key)
            lock.unlock()
            if p == nil { NSLog("Aux 着色器编译失败") }
        }
    }

    private struct DeviceBox: @unchecked Sendable {
        let device: any MTLDevice
        init(_ device: any MTLDevice) { self.device = device }
    }
}

/// Aux 画不了的原因。
enum AuxRenderError: Error, CustomStringConvertible {
    case shader(String)
    var description: String {
        switch self {
        case .shader(let s): "Aux 着色器：\(s)"
        }
    }
}
