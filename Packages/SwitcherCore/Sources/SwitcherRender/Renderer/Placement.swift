// 把一路输入（裁切 + 变换）放进目标画面某个矩形的几何计算。纯函数、只用栈上的值，渲染线程每次调用零分配。
import simd
import SwitcherContracts

/// 目标画面里的像素矩形（原点左上，y 向下）。
struct PixelRect {
    var x: Float
    var y: Float
    var width: Float
    var height: Float

    init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 由归一化矩形换算。
    init(_ r: NormalizedRect, in width: Int, _ height: Int) {
        x = Float(r.x) * Float(width)
        y = Float(r.y) * Float(height)
        self.width = Float(r.width) * Float(width)
        self.height = Float(r.height) * Float(height)
    }

    /// 四边各收进 inset。
    func insetBy(_ inset: Float) -> PixelRect {
        PixelRect(x: x + inset, y: y + inset, width: max(0, width - 2 * inset), height: max(0, height - 2 * inset))
    }
}

enum Placement {
    /// 把 (sourceWidth × sourceHeight) 的画面按 crop / transform 放进目标 (targetWidth × targetHeight) 画面的 dest 矩形里：
    /// 先裁切，再按裁切后的宽高比 fit 进 dest（留黑边），乘 scale，平移 offset（占目标画面宽高的比例），绕中心顺时针旋转，翻转。
    /// 返回的 uniforms 只填几何部分（posMatrix / posOffset / uvOrigin / uvSize / sampleStep / taps）。
    static func fill(_ u: inout DrawUniforms,
                     sourceWidth: Int, sourceHeight: Int,
                     crop: CropInsets, transform: Transform2D,
                     dest: PixelRect, targetWidth: Int, targetHeight: Int) {
        let cl = Float(min(max(crop.left, 0), 1)), ct = Float(min(max(crop.top, 0), 1))
        let cr = Float(min(max(crop.right, 0), 1)), cb = Float(min(max(crop.bottom, 0), 1))
        let uvW = max(0.0001, 1 - cl - cr), uvH = max(0.0001, 1 - ct - cb)
        let croppedW = Float(sourceWidth) * uvW, croppedH = Float(sourceHeight) * uvH

        // fit：裁切后的画面按比例塞进 dest
        let k = min(dest.width / max(croppedW, 1), dest.height / max(croppedH, 1))
        let s = Float(max(transform.scale, 0.01))
        let fw = croppedW * k * s, fh = croppedH * k * s
        let cx = dest.x + dest.width / 2 + Float(transform.offsetX) * Float(targetWidth)
        let cy = dest.y + dest.height / 2 + Float(transform.offsetY) * Float(targetHeight)

        // 顺时针旋转（屏幕坐标 y 向下）
        let theta = Float(transform.rotationDegrees) * Float.pi / 180
        let c = cos(theta), sn = sin(theta)
        let rot = simd_float2x2(SIMD2(c, sn), SIMD2(-sn, c))   // 列主序：第一列 (c, s)，第二列 (−s, c)
        // 像素坐标 p(corner) = center + rot × ((corner − 0.5) × size)
        let sizeMat = simd_float2x2(diagonal: SIMD2(fw, fh))
        let toNDC = simd_float2x2(diagonal: SIMD2(2 / Float(targetWidth), -2 / Float(targetHeight)))
        let lin = toNDC * rot * sizeMat
        let center = SIMD2(cx, cy)
        let halfShift = rot * (SIMD2(fw, fh) * 0.5)
        u.posMatrix = lin
        u.posOffset = toNDC * (center - halfShift) + SIMD2(-1, 1)

        // uv：裁切区域，翻转就是反向
        var uvo = SIMD2(cl, ct), uvs = SIMD2(uvW, uvH)
        if transform.flipHorizontal { uvo.x += uvW; uvs.x = -uvW }
        if transform.flipVertical { uvo.y += uvH; uvs.y = -uvH }
        u.uvOrigin = uvo
        u.uvSize = uvs

        // 下采样倍数 → 超采样次数（1 / 2 / 4），目标一个像素对应的 uv 跨度
        let ratio = max(croppedW / max(fw, 1), croppedH / max(fh, 1))
        let taps: Int32 = ratio > 3 ? 4 : (ratio > 1.5 ? 2 : 1)
        u.taps = taps
        u.sampleStep = SIMD2(uvW / max(fw, 1), uvH / max(fh, 1))
    }

    /// 纯色矩形（边框、FTB、底色）：dest 像素矩形 → NDC。
    static func fillSolid(_ u: inout DrawUniforms, dest: PixelRect, targetWidth: Int, targetHeight: Int, color: SIMD4<Float>) {
        let toNDC = simd_float2x2(diagonal: SIMD2(2 / Float(targetWidth), -2 / Float(targetHeight)))
        u.posMatrix = toNDC * simd_float2x2(diagonal: SIMD2(dest.width, dest.height))
        u.posOffset = toNDC * SIMD2(dest.x, dest.y) + SIMD2(-1, 1)
        u.uvOrigin = SIMD2(0, 0)
        u.uvSize = SIMD2(1, 1)
        u.taps = 1
        u.format = DrawFormat.solid.rawValue
        u.tint = color
    }

    /// 已是 BGRA 的整张纹理（PGM / PVW / 标签）原样放进 dest，按 fit 处理比例。
    static func fillTexture(_ u: inout DrawUniforms, textureWidth: Int, textureHeight: Int,
                            dest: PixelRect, targetWidth: Int, targetHeight: Int) {
        fill(&u, sourceWidth: textureWidth, sourceHeight: textureHeight, crop: .none, transform: .identity,
             dest: dest, targetWidth: targetWidth, targetHeight: targetHeight)
    }
}
