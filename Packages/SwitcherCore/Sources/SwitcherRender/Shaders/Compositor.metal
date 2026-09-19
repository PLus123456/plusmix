// 合成引擎的全部着色器（设计方案 §5）。离线渲染和实时路径跑的是同一份代码：CompositorPasses.swift 是唯一的调用方。
//
// 约定：
// - 工作色彩空间 BGRA8 gamma 域（决策 6），所有混合在 gamma 域直接做。
// - 输入纹理三种：NV12（Y 平面 r8 + CbCr 平面 rg8）、BGRA（bgra8，alpha 预乘）、UYVY（bgrg422，硬件解包后给 (Cr, Y, Cb)）。
//   YCbCr → RGB 在片段着色器里做，BT.709 / BT.601 / BT.2020 矩阵，limited / full 两种范围。
// - 抠像（提案 008 的口径）：转成 RGB 之后在 BT.709 的 (Cb, Cr) 平面算到键色的距离，半径内全透、柔化带内 smoothstep、
//   留下的像素做溢色抑制（减掉色度在键色方向上的正分量，亮度不变），输出预乘 alpha。
// - Wipe（W3-B）：新画面整幅画上来，片段按自己在目标里的位置算遮罩 alpha（硬边 = step，软边 = smoothstep）。
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
    int      keyer;        // 1 = 抠像
    int      wipeMode;     // 0 无 1 左→右 2 右→左 3 上→下 4 下→上 5 对角
    int      pad0;
    float2   targetSize;   // 目标纹理尺寸（像素）
    float2   keyChroma;    // 键色 (Cb, Cr)，−0.5…0.5
    float2   keyRange;     // (全透半径, 柔化带宽度)
    float2   keyNormal;    // 键色色度的单位向量（CPU 算好）
    float    keySpill;     // 溢色抑制 0–1
    float    wipeEdge;     // 擦边位置 0–1
    float    wipeSoftness; // 软边宽度（占场的比例）
    float    pad1;
    float2   pad2;
};
static_assert(sizeof(DrawUniforms) == 160, "DrawUniforms 布局变了，同步改 ShaderTypes.swift");

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

// MARK: - 抠像（提案 008）：BT.709 色度平面上的距离；输入 / 输出都是预乘 RGBA

static inline float4 applyKey(float4 c, constant DrawUniforms &u) {
    float a0 = c.a;
    float3 rgb = a0 > 0.0 ? c.rgb / a0 : float3(0.0);
    float y = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
    float2 chroma = float2((rgb.b - y) / 1.8556, (rgb.r - y) / 1.5748);
    float d = distance(chroma, u.keyChroma);
    float radius = u.keyRange.x, ramp = u.keyRange.y;
    float alpha = ramp > 0.0 ? smoothstep(radius, radius + ramp, d) : step(radius, d);
    float proj = dot(chroma, u.keyNormal);
    if (u.keySpill > 0.0 && proj > 0.0) {
        chroma -= u.keySpill * proj * u.keyNormal;
        float r = y + 1.5748 * chroma.y;
        float b = y + 1.8556 * chroma.x;
        float g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
        rgb = saturate(float3(r, g, b));
    }
    float a = alpha * a0;
    return float4(rgb * a, a);
}

/// 下采样路径（缩略图 / 画中画）的 half 版：同一套公式，half 精度（色度距离误差 ~5e-4，远小于最小容差 0.005）。
static inline half4 applyKeyHalf(half4 c, constant DrawUniforms &u) {
    half a0 = c.a;
    half3 rgb = a0 > 0.0h ? c.rgb / a0 : half3(0.0h);
    half y = 0.2126h * rgb.r + 0.7152h * rgb.g + 0.0722h * rgb.b;
    half2 chroma = half2((rgb.b - y) * (1.0h / 1.8556h), (rgb.r - y) * (1.0h / 1.5748h));
    half2 key = half2(u.keyChroma);
    half d = distance(chroma, key);
    half radius = half(u.keyRange.x), ramp = half(u.keyRange.y);
    half alpha = ramp > 0.0h ? smoothstep(radius, radius + ramp, d) : step(radius, d);
    half2 kn = half2(u.keyNormal);
    half spill = half(u.keySpill);
    half proj = dot(chroma, kn);
    if (spill > 0.0h && proj > 0.0h) {
        chroma -= spill * proj * kn;
        half r = y + 1.5748h * chroma.y;
        half b = y + 1.8556h * chroma.x;
        half g = (y - 0.2126h * r - 0.0722h * b) * (1.0h / 0.7152h);
        rgb = saturate(half3(r, g, b));
    }
    half a = alpha * a0;
    return half4(rgb * a, a);
}

// MARK: - 下采样用的 half 精度版（缩略图 / 画中画的 taps×taps 盒式滤波；1:1 的路径保持 float 以保证 V9 的电平精度）
// 实测（reports/w1-compositor.md）：60 fps 节奏下 GPU 时钟很低，8 个 1/4 缩略图 4×4 taps 用 float 要 1.2 ms，half 0.4 ms。

static inline half3 ycbcrToRGBHalf(half3 codes, int fullRange, int matrixID) {
    half kr, kb;
    if (matrixID == 1)      { kr = 0.299h;  kb = 0.114h;  }
    else if (matrixID == 2) { kr = 0.2627h; kb = 0.0593h; }
    else                    { kr = 0.2126h; kb = 0.0722h; }
    half kg = 1.0h - kr - kb;
    half y, cb, cr;
    if (fullRange != 0) {
        y  = codes.x;
        cb = codes.y - (128.0h / 255.0h);
        cr = codes.z - (128.0h / 255.0h);
    } else {
        y  = (codes.x * 255.0h - 16.0h) / 219.0h;
        cb = (codes.y * 255.0h - 128.0h) / 224.0h;
        cr = (codes.z * 255.0h - 128.0h) / 224.0h;
    }
    half r = y + 2.0h * (1.0h - kr) * cr;
    half b = y + 2.0h * (1.0h - kb) * cb;
    half g = (y - kr * r - kb * b) / kg;
    return saturate(half3(r, g, b));
}

static inline half4 fetchHalf(float2 uv, constant DrawUniforms &u,
                              texture2d<half> tex0, texture2d<half> tex1) {
    switch (u.format) {
    case DrawFormatBGRA:
        return tex0.sample(linearSampler, uv);
    case DrawFormatNV12: {
        half y = tex0.sample(linearSampler, uv).r;
        float2 cuv = float2(uv.x + 0.25 / u.chromaSize.x, uv.y);
        half2 c = tex1.sample(linearSampler, cuv).rg;
        return half4(ycbcrToRGBHalf(half3(y, c.x, c.y), u.fullRange, u.matrix), 1.0h);
    }
    case DrawFormatUYVY: {
        half3 s = tex0.sample(linearSampler, uv).rgb;
        return half4(ycbcrToRGBHalf(half3(s.g, s.b, s.r), u.fullRange, u.matrix), 1.0h);
    }
    default:
        return half4(0.0h);
    }
}

// MARK: - Wipe 遮罩：按片段在目标里的位置

static inline float wipeAlpha(float2 position, constant DrawUniforms &u) {
    float2 p = position / u.targetSize;
    float f;
    switch (u.wipeMode) {
    case 1: f = p.x; break;
    case 2: f = 1.0 - p.x; break;
    case 3: f = p.y; break;
    case 4: f = 1.0 - p.y; break;
    case 5: f = (p.x + p.y) * 0.5; break;
    default: return 1.0;
    }
    float e = u.wipeEdge, s = u.wipeSoftness;
    if (s <= 0.0) return f < e ? 1.0 : 0.0;
    return 1.0 - smoothstep(e - 0.5 * s, e + 0.5 * s, f);
}

// MARK: - 片段：输入 / 纯色

fragment float4 quadFragment(QuadOut in [[stage_in]],
                             constant DrawUniforms &u [[buffer(0)]],
                             texture2d<float> tex0 [[texture(0)]],
                             texture2d<float> tex1 [[texture(1)]],
                             texture2d<half> tex0h [[texture(2)]],
                             texture2d<half> tex1h [[texture(3)]]) {
    float4 color;
    if (u.format == DrawFormatSolid) {
        color = u.tint;
    } else {
        int taps = clamp(u.taps, 1, 4);
        if (taps == 1) {
            // 1:1 或放大：float 精度，采样点正好落在纹素中心时逐电平精确
            color = fetch(in.uv, u, tex0, tex1);
            if (u.keyer != 0) color = applyKey(color, u);
        } else {
            // 下采样：在目标像素的足迹内均匀取 taps×taps 个点做盒式滤波（第一版代替 mipmap，见报告），half 精度；抠像逐采样点做
            // 累加与缩放保持 half（与 W1-C 逐位相同，参考图不变）。
            // 抠像：2×2（画中画）逐采样点抠，边缘干净；4×4（缩略图）先滤波再抠一次——每像素 16 次抠像在 60 fps 的低 GPU 时钟下
            // 要 1 ms 以上（V1 实测），缩略图看不出差别（reports/w3-compositor2.md §2）。
            bool keyPerTap = u.keyer != 0 && taps == 2;
            float inv = 1.0 / float(taps);
            half4 acc = half4(0.0h);
            for (int j = 0; j < taps; ++j) {
                for (int i = 0; i < taps; ++i) {
                    float2 o = (float2(float(i), float(j)) + 0.5) * inv - 0.5;
                    half4 s = fetchHalf(in.uv + o * u.sampleStep, u, tex0h, tex1h);
                    if (keyPerTap) s = applyKeyHalf(s, u);
                    acc += s;
                }
            }
            acc *= half(inv * inv);
            color = float4(acc);
            if (u.keyer != 0 && !keyPerTap) color = applyKey(color, u);
        }
        color *= u.tint;   // 预乘颜色整体乘不透明度
    }
    if (u.wipeMode != 0) color *= wipeAlpha(in.position.xy, u);
    return color;
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
