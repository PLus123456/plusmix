// W3-B 加的固定输入图：绿幕合成图（带已知 alpha）、stinger 图、小尺寸灰图。全部由代码确定性生成。
import CoreGraphics
import CoreVideo
import Foundation
import SwitcherContracts

extension TestImages {
    /// 绿幕背景色（键色）。
    static let greenScreenKey = RGB8(red: 0, green: 200, blue: 60)

    /// 1080p 的已知 alpha / 绿幕图 / stinger 图各算一次（debug 下逐像素生成要几十秒）。
    nonisolated(unsafe) static let cachedGreenScreenAlpha: [Float] = computeGreenScreenAlpha(width: width, height: height)
    nonisolated(unsafe) static let cachedGreenScreenBuffer: CVPixelBuffer = computeGreenScreenBuffer(width: width, height: height)
    nonisolated(unsafe) static let cachedStingerBuffer: CVPixelBuffer = computeStingerBuffer(width: width, height: height)
    nonisolated(unsafe) static let cachedPhase2Inputs: [Int: CGImage] = {
        var inputs = referenceInputs()
        inputs[5] = image(from: greenScreenBuffer())
        inputs[6] = image(from: stingerBuffer())
        inputs[7] = image(from: solidWithCenterBlock((0, 180, 200), center: (140, 20, 20)))
        inputs[8] = image(from: solidWithCenterBlock((230, 200, 0), center: (20, 20, 140)))
        return inputs
    }()

    static func greenScreenAlpha(width w: Int = width, height h: Int = height) -> [Float] {
        w == width && h == height ? cachedGreenScreenAlpha : computeGreenScreenAlpha(width: w, height: h)
    }
    static func greenScreenBuffer(width w: Int = width, height h: Int = height) -> CVPixelBuffer {
        w == width && h == height ? cachedGreenScreenBuffer : computeGreenScreenBuffer(width: w, height: h)
    }
    static func stingerBuffer(width w: Int = width, height h: Int = height) -> CVPixelBuffer {
        w == width && h == height ? cachedStingerBuffer : computeStingerBuffer(width: w, height: h)
    }

    /// 前景的已知 alpha（0–1）：一个大圆盘、一个圆环、三条斜细条、一块矩形，边缘按 1 px 覆盖率抗锯齿。
    /// 圆环和细条周长大，IoU 对边缘位置敏感。
    static func computeGreenScreenAlpha(width w: Int, height h: Int) -> [Float] {
        var alpha = [Float](repeating: 0, count: w * h)
        let s = Float(w) / 1920
        func disc(_ cx: Float, _ cy: Float, _ r: Float, _ x: Float, _ y: Float) -> Float {
            let d = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
            return min(1, max(0, r - d + 0.5))   // 1 px 过渡
        }
        for y in 0..<h {
            for x in 0..<w {
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                var a: Float = 0
                // 大圆盘
                a = max(a, disc(620 * s, 560 * s, 300 * s, fx, fy))
                // 圆环：外 220 内 160
                let ring = disc(1350 * s, 420 * s, 220 * s, fx, fy) - disc(1350 * s, 420 * s, 160 * s, fx, fy)
                a = max(a, max(0, ring))
                // 三条斜细条（宽 14 px），斜率 1
                let sqrt2: Float = 1.4142135
                let barTop: Float = 600 * s, barBottom: Float = 1000 * s, halfWidth: Float = 7 * s
                for k in 0..<3 {
                    let offset: Float = Float(1200 + k * 120) * s - 700 * s
                    let diff: Float = fx - fy - offset
                    let d: Float = abs(diff) / sqrt2
                    if fy > barTop && fy < barBottom {
                        let cov: Float = halfWidth - d + 0.5
                        a = max(a, min(1, max(0, cov)))
                    }
                }
                // 矩形（硬边，边缘在像素边界上）
                if x >= Int(100 * s) && x < Int(420 * s) && y >= Int(60 * s) && y < Int(240 * s) { a = 1 }
                alpha[y * w + x] = a
            }
        }
        return alpha
    }

    /// 绿幕合成图：前景（肤色 / 蓝 / 白 / 深灰渐变）按已知 alpha 叠在带光照渐变 + 噪声的绿幕上。alpha 全部烧成 255（这是一张普通不透明图）。
    static func computeGreenScreenBuffer(width w: Int, height h: Int) -> CVPixelBuffer {
        let alpha = greenScreenAlpha(width: w, height: h)
        let pb = PixelBuffers.bgra(width: w, height: h)
        PixelBuffers.fillBGRA(pb) { x, y in
            // 绿幕：亮度左右 ±7%、上下 ±5% 的光照渐变，加 ±6 的确定性噪声
            let nx: Double = Double(x) / Double(w - 1) - 0.5
            let ny: Double = Double(y) / Double(h - 1) - 0.5
            let lx: Double = 1 + 0.14 * nx
            let ly: Double = 1 + 0.10 * ny
            let light: Double = lx * ly
            let n: Double = Double(Int(TestPattern.noiseValue(level: 128, amplitude: 6, seed: 42, frameNumber: 7, x: x, y: y)) - 128)
            func clip(_ v: Double) -> Double { min(255, max(0, v)) }
            let gr: Double = clip(Double(greenScreenKey.red) * light + n)
            let gg: Double = clip(Double(greenScreenKey.green) * light + n)
            let gb: Double = clip(Double(greenScreenKey.blue) * light + n)
            // 前景颜色按位置选
            let fg: (Double, Double, Double)
            if x < w / 2 && y < h / 2 { fg = (220, 170, 140) }          // 肤色
            else if x >= w / 2 && y < h / 2 { fg = (40, 80, 220) }      // 蓝
            else if x < w / 2 { fg = (250, 250, 250) }                   // 白
            else { fg = (60, 60, 60) }                                   // 深灰
            let a: Double = Double(alpha[y * w + x])
            let r: Double = fg.0 * a + gr * (1 - a)
            let g: Double = fg.1 * a + gg * (1 - a)
            let b: Double = fg.2 * a + gb * (1 - a)
            return (UInt8(r.rounded()), UInt8(g.rounded()), UInt8(b.rounded()), 255)
        }
        return pb
    }

    /// Stinger 图（带 alpha）：一条从左下到右上的斜带，带内不透明、两侧 60 px 软边；带里橙→品红渐变。
    /// 左上角和右下角两块区域永远透明（V6 的 stinger 测试在那里看"底"什么时候换）。
    static func computeStingerBuffer(width w: Int, height h: Int) -> CVPixelBuffer {
        let pb = PixelBuffers.bgra(width: w, height: h)
        let s = Double(w) / 1920
        PixelBuffers.fillBGRA(pb) { x, y in
            // 带的中心线：x + y = w（左下 (0, w) 到右上 (w, 0)，按 1080p 比例）
            let fx: Double = Double(x) / s, fy: Double = Double(y) / s
            let sum: Double = fx + fy - 1920
            let d: Double = abs(sum) / 1.4142135623730951   // 到中心线的距离（1080p 像素）
            let half: Double = 260, soft: Double = 60
            let cov: Double = (half + soft - d) / soft
            let a: Double = min(1, max(0, cov))
            guard a > 0 else { return (0, 0, 0, 0) }
            let t: Double = fx / 1920
            let g: Double = 140 - 120 * t
            let b: Double = 40 + 180 * t
            return (255, UInt8(g), UInt8(b), UInt8((a * 255).rounded()))
        }
        return pb
    }

    /// 带边框的画中画输入用输入 4（棋盘）即可；这里给"叠加顺序"用一张纯色底 + 大号编号的图：整幅 color，中间一块对比色。
    static func solidWithCenterBlock(_ rgb: (UInt8, UInt8, UInt8), center: (UInt8, UInt8, UInt8), width w: Int = width, height h: Int = height) -> CVPixelBuffer {
        let pb = PixelBuffers.bgra(width: w, height: h)
        PixelBuffers.fillBGRA(pb) { x, y in
            if x >= w / 4 && x < w * 3 / 4 && y >= h / 4 && y < h * 3 / 4 { return (center.0, center.1, center.2, 255) }
            return (rgb.0, rgb.1, rgb.2, 255)
        }
        return pb
    }

    /// W3-B 的参考图输入：1–4 同 W1-C，5 = 绿幕合成图，6 = stinger，7 = 纯色 + 中心块（青 / 深红），8 = 纯色 + 中心块（黄 / 深蓝）。
    static func phase2ReferenceInputs() -> [Int: CGImage] { cachedPhase2Inputs }

    /// 同上，像素缓冲形态。
    static func phase2ReferenceBuffers() -> [Int: CVPixelBuffer] {
        var b = referenceBuffers()
        b[5] = greenScreenBuffer()
        b[6] = stingerBuffer()
        b[7] = solidWithCenterBlock((0, 180, 200), center: (140, 20, 20))
        b[8] = solidWithCenterBlock((230, 200, 0), center: (20, 20, 140))
        return b
    }
}

/// W3-B 的固定状态（参考图 + 结构测试共用）。
extension ReferenceStates {
    static func phase2Inputs() -> [InputConfig] {
        let names = ["摄像机 1", "Camera 2", "Lower Third", "PiP 画中画", "绿幕 Key", "Stinger", "Cam 7", "Cam 8"]
        return (1...8).map { InputConfig(number: $0, name: names[$0 - 1], source: .synthetic(settings: SyntheticSourceSettings())) }
    }

    /// 8 路输入版的固定状态（与 fixed() 同一套叠加 / PGM / PVW）。
    static func fixed8() -> MixerState {
        var s = fixed()
        s.inputs = phase2Inputs()
        return s
    }

    /// 画中画边框的旧写法：效果格 "border"（提案 010 的过渡做法）。W3-B2 起渲染器不再读它（只读 `OverlayState.border`），
    /// 只留给"旧键被忽略"的用例造数据。
    static func borderEffect(width: Double = 0.006, color: (Int, Int, Int) = (255, 255, 255)) -> EffectSlot {
        EffectSlot(id: "border", enabled: true, params: ["width": .number(width), "color": .array([.number(Double(color.0)), .number(Double(color.1)), .number(Double(color.2))])])
    }

    /// 叠加顺序：Overlay 1 = 输入 7 画中画在 (0.3, 0.3, 0.4, 0.4)，Overlay 3 = 输入 8 画中画在 (0.5, 0.5, 0.4, 0.4) 与之重叠 → 重叠处是 8。
    static func overlayOrder() -> MixerState {
        var s = fixed8()
        s.overlays[0] = OverlayState(input: 7, on: true, rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), animProgress: 1)
        s.overlays[2] = OverlayState(input: 8, on: true, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), animProgress: 1)
        return s
    }

    /// 带边框的画中画：Overlay 3 = 输入 4 在左上 (0.05, 0.05, 0.3, 0.3)，白边 0.006。
    /// 边框走正式字段 `OverlayState.border`（提案 010）。`v8-pip-border-pgm.png` 是 W3-B 用效果格画的，
    /// P3 证明过两条路径逐像素相同，所以换写法之后参考图不变。
    static func pipBorder() -> MixerState {
        var s = fixed8()
        s.overlays[0] = OverlayState()
        s.overlays[2] = OverlayState(input: 4, on: true, rect: NormalizedRect(x: 0.05, y: 0.05, width: 0.3, height: 0.3), animProgress: 1)
        s.overlays[2].border = OverlayBorder()
        return s
    }

    /// 抠像参数（提案 009 的口径；绿幕图的光照 / 噪声在容差内）。
    static func keyer(enabled: Bool = true, tolerance: Double = 0.15, softness: Double = 0.1, spill: Double = 0.5) -> KeyerSettings {
        KeyerSettings(enabled: enabled, keyColor: TestImages.greenScreenKey, tolerance: tolerance, softness: softness, spillSuppression: spill)
    }

    /// 抠像：Overlay 2 = 输入 5（绿幕合成图）整幅叠在输入 1 上，抠像开；其他叠加关。
    static func keyed() -> MixerState {
        var s = fixed8()
        s.overlays = Array(repeating: OverlayState(), count: 4)
        s.overlays[1] = OverlayState(input: 5, on: true, rect: .full, animProgress: 1)
        s.inputs[4].settings.keyer = keyer()
        return s
    }

    /// Wipe 50%（1 → 2），可选软边。
    static func wipe50(_ direction: WipeDirection, softness: Double = 0) -> MixerState {
        var s = fixed8()
        s.transition = TransitionState(type: .wipe, durationTicks: 30, progress: 0.5, source: .auto, startTick: Tick(100),
                                       wipe: WipeParams(direction: direction, softness: softness))
        return s
    }

    /// Zoom 50%。
    static func zoom50() -> MixerState {
        var s = fixed8()
        s.transition = TransitionState(type: .zoom, durationTicks: 30, progress: 0.5, source: .auto, startTick: Tick(100))
        return s
    }

    /// Stinger 中点：输入 6 作 stinger，30 拍，第 15 拍换底，进度 0.5（= 第 15 拍，底已经是输入 2）。
    static func stingerMid() -> MixerState {
        var s = fixed8()
        s.transition = TransitionState(type: .stinger, durationTicks: 30, progress: 0.5, source: .auto, startTick: Tick(100),
                                       stinger: StingerParams(input: 6, cutAtTick: 15))
        return s
    }

    /// 下三分之一滑入到一半（Overlay 1 = 输入 3 整幅，slide，animProgress 0.5 → 从底边上来一半）。
    static func overlaySlide50() -> MixerState {
        var s = fixed8()
        s.overlays[0] = OverlayState(input: 3, on: true, rect: .full, animProgress: 0.5, animation: OverlayAnimation(kind: .slide, durationTicks: 20), startTick: Tick(100))
        return s
    }

    /// 画中画缩放进入到一半（Overlay 3 = 输入 4 右下 1/4，zoom，animProgress 0.5 → 绕中心缩到一半）。
    static func overlayZoom50() -> MixerState {
        var s = fixed8()
        s.overlays[2] = OverlayState(input: 4, on: true, rect: .bottomRightQuarter, animProgress: 0.5, animation: OverlayAnimation(kind: .zoom, durationTicks: 20), startTick: Tick(100))
        return s
    }

    /// 多画面布局：放进 kind = multiview 的输出的正式字段 `settings.multiview`（提案 010）。
    /// W3-B 时这里写的是过渡键 `extra["layout"]`；W3-B2 删了渲染器的过渡读取，参考图的状态改走正式字段（像素不变，见 README）。
    static func withMultiviewLayout(_ state: MixerState, _ layout: MultiviewLayoutSettings) -> MixerState {
        var s = state
        s.outputs = [OutputState(number: 9, kind: .multiview, name: "多画面", enabled: true,
                                 settings: OutputSettings(source: .multiview, multiview: layout))]
        return s
    }

    /// 预设名的简写。
    static func withMultiviewPreset(_ state: MixerState, _ preset: String) -> MixerState {
        withMultiviewLayout(state, MultiviewLayoutSettings(preset: preset))
    }

    /// 旧写法：把 layout JSON 放进过渡键 `extra["layout"]`、不给正式字段。W3-B2 起渲染器忽略它（只留给"旧键被忽略"的用例）。
    static func withLegacyExtraLayout(_ state: MixerState, _ layout: JSONValue) -> MixerState {
        var s = state
        s.outputs = [OutputState(number: 9, kind: .multiview, name: "多画面", enabled: true,
                                 settings: OutputSettings(source: .multiview, extra: [MultiviewLayoutSettings.legacyExtraKey: layout]))]
        return s
    }

    /// 自定义布局：PGM 占左上 70%，右列 PVW + 输入 3 / 4，底行输入 1 / 2 / 5；安全框和电平表都开。
    /// 数值与 W3-B 的过渡键写法 `customLayoutLegacyJSON` 逐位相同（`testP3_multiviewReadsOnlyOfficialField…` 钉住），
    /// 所以 `v8-multiview-custom.png` 不用重生成。
    static let customLayout = MultiviewLayoutSettings(custom: [
        MultiviewCell(source: .program, rect: NormalizedRect(x: 0.0, y: 0.0, width: 0.7, height: 0.7)),
        MultiviewCell(source: .preview, rect: NormalizedRect(x: 0.7, y: 0.0, width: 0.3, height: 0.2333)),
        MultiviewCell(source: .input(number: 3), rect: NormalizedRect(x: 0.7, y: 0.2333, width: 0.3, height: 0.2333)),
        MultiviewCell(source: .input(number: 4), rect: NormalizedRect(x: 0.7, y: 0.4667, width: 0.3, height: 0.2333)),
        MultiviewCell(source: .input(number: 1), rect: NormalizedRect(x: 0.0, y: 0.7, width: 0.3333, height: 0.3)),
        MultiviewCell(source: .input(number: 2), rect: NormalizedRect(x: 0.3333, y: 0.7, width: 0.3333, height: 0.3)),
        MultiviewCell(source: .input(number: 5), rect: NormalizedRect(x: 0.6667, y: 0.7, width: 0.3333, height: 0.3)),
    ], safeArea: true, meters: true)

    /// 同一个自定义布局的过渡键写法（W3-B 原样）。
    static let customLayoutLegacyJSON: JSONValue = [
        "cells": [
            ["source": "program", "rect": ["x": 0.0, "y": 0.0, "width": 0.7, "height": 0.7]],
            ["source": "preview", "rect": ["x": 0.7, "y": 0.0, "width": 0.3, "height": 0.2333]],
            ["source": 3, "rect": ["x": 0.7, "y": 0.2333, "width": 0.3, "height": 0.2333]],
            ["source": 4, "rect": ["x": 0.7, "y": 0.4667, "width": 0.3, "height": 0.2333]],
            ["source": 1, "rect": ["x": 0.0, "y": 0.7, "width": 0.3333, "height": 0.3]],
            ["source": 2, "rect": ["x": 0.3333, "y": 0.7, "width": 0.3333, "height": 0.3]],
            ["source": 5, "rect": ["x": 0.6667, "y": 0.7, "width": 0.3333, "height": 0.3]],
        ],
        "safeArea": true,
        "meters": true,
    ]
}
