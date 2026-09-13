// 合成引擎的全部着色器（设计方案 §5）。离线渲染和实时路径跑的是同一份代码：CompositorPasses.swift 是唯一的调用方。
//
// 约定：
// - 工作色彩空间 BGRA8 gamma 域（决策 6），所有混合在 gamma 域直接做。
// - 输入纹理三种：NV12（Y 平面 r8 + CbCr 平面 rg8）、BGRA（bgra8，alpha 预乘）、UYVY（bgrg422，硬件解包后给 (Cr, Y, Cb)）。
//   YCbCr → RGB 在片段着色器里做，BT.709 / BT.601 / BT.2020 矩阵，limited / full 两种范围。
// - 输出 RGB → NV12（BT.709 limited）由 compute kernel 写进 IOSurface 平面（以 r8Uint / rg8Uint 视图写，整数精确）。
// - DrawUniforms 的字段顺序、大小必须与 ShaderTypes.swift 逐字段一致（两边都有 static_assert / 断言）。
#include <metal_stdlib>
using namespace metal;

// MARK: - 与 Swift 共享的结构

enum DrawFormat : int {
    DrawFormatBGRA = 0,
    DrawFormatNV12 = 1,
    DrawFormatUYVY = 2,
    DrawFormatSolid = 3,
    DrawFormatLabel = 4,
};

struct DrawUniforms {
    float4   tint;         // 纹理：乘到输出上的不透明度（rgb 与 a 同值，预乘）；纯色：预乘后的颜色
    float2x2 posMatrix;    // 单位正方形角 (0/1, 0/1) → NDC
    float2   posOffset;
    float2   uvOrigin;     // uv = uvOrigin + corner * uvSize（翻转就是 uvSize 为负）
    float2   uvSize;
    float2   sampleStep;   // 目标一个像素在 uv 里的跨度（超采样用）
    float2   chromaSize;   // NV12 色度平面尺寸（左对齐色度用）
    int      taps;         // 每轴超采样次数 1 / 2 / 4（下采样时的盒式滤波）
    int      format;       // DrawFormat
    int      fullRange;    // 0 = limited(16–235) 1 = full(0–255)
    int      matrix;       // 0 = BT.709 1 = BT.601 2 = BT.2020
    int      slice;        // 标签纹理数组的切片
    int      pad0, pad1, pad2;
};
static_assert(sizeof(DrawUniforms) == 112, "DrawUniforms 布局变了，同步改 ShaderTypes.swift");

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

// MARK: - 顶点：单位正方形，四个角由 vertex_id 生成（0 左上 1 右上 2 左下 3 右下，triangle strip）

vertex QuadOut quadVertex(uint vid [[vertex_id]], constant DrawUniforms &u [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1u), float(vid >> 1u));
    QuadOut out;
    out.position = float4(u.posMatrix * corner + u.posOffset, 0.0, 1.0);
    out.uv = u.uvOrigin + corner * u.uvSize;
    return out;
}

// MARK: - 色彩

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
static inline float4 fetch(float2 uv, constant DrawUniforms &u,
                           texture2d<float> tex0, texture2d<float> tex1) {
    switch (u.format) {
    case DrawFormatBGRA:
        return tex0.sample(linearSampler, uv);                       // 已预乘
    case DrawFormatNV12: {
        float y = tex0.sample(linearSampler, uv).r * 255.0;
        // 4:2:0 色度水平左对齐（与偶数亮度样本共址）、垂直居中：色度坐标 = uv + (0.25 / 色度宽, 0)
        float2 cuv = float2(uv.x + 0.25 / u.chromaSize.x, uv.y);
        float2 c = tex1.sample(linearSampler, cuv).rg * 255.0;
        return float4(ycbcrToRGB(float3(y, c.x, c.y), u.fullRange, u.matrix), 1.0);
    }
    case DrawFormatUYVY: {
        // bgrg422：硬件给 (Cr, Y, Cb, 1)，无色彩转换
        float3 s = tex0.sample(linearSampler, uv).rgb * 255.0;
        return float4(ycbcrToRGB(float3(s.g, s.b, s.r), u.fullRange, u.matrix), 1.0);
    }
    default:
        return float4(0.0);
    }
}

// MARK: - 片段：输入 / 纯色

fragment float4 quadFragment(QuadOut in [[stage_in]],
                             constant DrawUniforms &u [[buffer(0)]],
                             texture2d<float> tex0 [[texture(0)]],
                             texture2d<float> tex1 [[texture(1)]]) {
    if (u.format == DrawFormatSolid) {
        return u.tint;
    }
    int taps = clamp(u.taps, 1, 4);
    float4 acc = float4(0.0);
    if (taps == 1) {
        acc = fetch(in.uv, u, tex0, tex1);
    } else {
        // 下采样：在目标像素的足迹内均匀取 taps×taps 个点做盒式滤波（第一版代替 mipmap，见报告）
        float inv = 1.0 / float(taps);
        for (int j = 0; j < taps; ++j) {
            for (int i = 0; i < taps; ++i) {
                float2 o = (float2(float(i), float(j)) + 0.5) * inv - 0.5;
                acc += fetch(in.uv + o * u.sampleStep, u, tex0, tex1);
            }
        }
        acc *= inv * inv;
    }
    return acc * u.tint;   // 预乘颜色整体乘不透明度
}

// MARK: - 片段：标签（预渲染的文字纹理数组）

fragment float4 labelFragment(QuadOut in [[stage_in]],
                              constant DrawUniforms &u [[buffer(0)]],
                              texture2d_array<float> labels [[texture(0)]]) {
    return labels.sample(linearSampler, in.uv, uint(u.slice)) * u.tint;
}

// MARK: - 输出：RGB → NV12（BT.709 limited）

/// 亮度 Y'（0–1）。
static inline float luma709(float3 rgb) {
    return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
}

/// 每个线程处理一个 2×2 亮度块（= 一个色度样本）。
/// 舍入策略：Y = 16 + 219·Y'，Cb = 128 + 224·(B'−Y')/1.8556，Cr = 128 + 224·(R'−Y')/1.5748，
/// 先钳到合法范围（Y 16–235，C 16–240）再 round（四舍五入，.5 远离 0），以整数写进 r8Uint / rg8Uint 视图，不经过 unorm 转换。
/// 色度取 2×2 块四个像素 RGB 的平均再转换（线性运算可交换，等于平均 Cb/Cr）。
kernel void rgbToNV12(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<uint, access::write> lumaPlane [[texture(1)]],
                      texture2d<uint, access::write> chromaPlane [[texture(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= chromaPlane.get_width() || gid.y >= chromaPlane.get_height()) return;
    uint2 p = gid * 2u;
    uint2 last = uint2(src.get_width() - 1u, src.get_height() - 1u);
    float3 c00 = src.read(min(p, last)).rgb;
    float3 c10 = src.read(min(p + uint2(1u, 0u), last)).rgb;
    float3 c01 = src.read(min(p + uint2(0u, 1u), last)).rgb;
    float3 c11 = src.read(min(p + uint2(1u, 1u), last)).rgb;
    float4 ys = 16.0 + 219.0 * float4(luma709(c00), luma709(c10), luma709(c01), luma709(c11));
    uint4 yc = uint4(round(clamp(ys, 16.0, 235.0)));
    lumaPlane.write(uint4(yc.x, 0u, 0u, 0u), p);
    lumaPlane.write(uint4(yc.y, 0u, 0u, 0u), p + uint2(1u, 0u));
    lumaPlane.write(uint4(yc.z, 0u, 0u, 0u), p + uint2(0u, 1u));
    lumaPlane.write(uint4(yc.w, 0u, 0u, 0u), p + uint2(1u, 1u));
    float3 avg = (c00 + c10 + c01 + c11) * 0.25;
    float y = luma709(avg);
    float cb = 128.0 + 224.0 * (avg.b - y) / 1.8556;
    float cr = 128.0 + 224.0 * (avg.r - y) / 1.5748;
    uint2 cc = uint2(round(clamp(float2(cb, cr), 16.0, 240.0)));
    chromaPlane.write(uint4(cc.x, cc.y, 0u, 0u), gid);
}
