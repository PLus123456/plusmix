// V8 用的固定输入图：全部由代码确定性生成，不依赖外部文件。参考图（Tests/References/）由 gen-references.sh 用同样的图生成。
import CoreGraphics
import CoreVideo
import Foundation
import SwitcherContracts

enum TestImages {
    static let width = 1920
    static let height = 1080

    /// BGRA 像素缓冲 → CGImage（sRGB，预乘）。
    static func image(from pb: CVPixelBuffer) -> CGImage {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(pb)!, count: bpr * h)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                       provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// 输入 1：合成测试图案（渐变底、帧号 1234、输入 ID 0）。
    static func patternBuffer(inputID: Int = 0, frame: UInt32 = 1234, background: TestPattern.Background = .gradient) -> CVPixelBuffer {
        let pb = PixelBuffers.bgra(width: width, height: height)
        TestPattern.draw(TestPattern.Content(frameNumber: frame, hostTimeMs: 0, inputID: inputID, flash: false, background: background), into: pb)
        return pb
    }

    /// 75% 色条（白 黄 青 绿 品 红 蓝，7 条等宽），full-range RGB 电平 191。
    static let colorBars75: [(UInt8, UInt8, UInt8)] = [
        (191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191),
    ]

    /// 输入 2：75% 色条，下方 1/4 是 0–255 步 8 的灰阶（32 级）。
    static func colorBarsBuffer() -> CVPixelBuffer {
        let pb = PixelBuffers.bgra(width: width, height: height)
        PixelBuffers.fillBGRA(pb) { x, y in
            if y >= height * 3 / 4 {
                let level = UInt8(min(31, x * 32 / width) * 8)
                return (level, level, level, 255)
            }
            let (r, g, b) = colorBars75[min(6, x * 7 / width)]
            return (r, g, b, 255)
        }
        return pb
    }

    /// 输入 3：带 alpha 的"下三分之一"：上 2/3 透明；下 1/3 是从左到右蓝→橙的不透明条，中间叠一块 50% 白的半透明方块。
    static func lowerThirdBuffer() -> CVPixelBuffer {
        let pb = PixelBuffers.bgra(width: width, height: height)
        PixelBuffers.fillBGRA(pb) { x, y in
            let barTop = height * 2 / 3 + 40, barBottom = height - 80
            if y >= barTop && y < barBottom && x >= 120 && x < width - 120 {
                let t = Double(x - 120) / Double(width - 240)
                let r = UInt8(30 + t * 200), g = UInt8(90 + t * 60), b = UInt8(220 - t * 200)
                return (r, g, b, 255)
            }
            if y >= 200 && y < 420 && x >= 200 && x < 620 { return (255, 255, 255, 128) }
            return (0, 0, 0, 0)
        }
        return pb
    }

    /// 输入 4：8×8 彩色棋盘（每格 240×135），四个象限不同色调，用于画中画缩放。
    static func checkerBuffer() -> CVPixelBuffer {
        let pb = PixelBuffers.bgra(width: width, height: height)
        PixelBuffers.fillBGRA(pb) { x, y in
            let cx = x / (width / 8), cy = y / (height / 8)
            let light = (cx + cy) % 2 == 0
            switch (x < width / 2, y < height / 2) {
            case (true, true): return light ? (230, 60, 60, 255) : (60, 10, 10, 255)
            case (false, true): return light ? (60, 200, 60, 255) : (10, 50, 10, 255)
            case (true, false): return light ? (60, 90, 230, 255) : (10, 20, 60, 255)
            case (false, false): return light ? (230, 230, 60, 255) : (60, 60, 10, 255)
            }
        }
        return pb
    }

    /// 纯灰 BGRA。
    static func grayBuffer(level: UInt8, width w: Int = width, height h: Int = height) -> CVPixelBuffer {
        let pb = PixelBuffers.bgra(width: w, height: h)
        PixelBuffers.fillBGRA(pb) { _, _ in (level, level, level, 255) }
        return pb
    }

    /// V8 的四路输入（CGImage 形态）。
    static func referenceInputs() -> [Int: CGImage] {
        [1: image(from: patternBuffer()), 2: image(from: colorBarsBuffer()), 3: image(from: lowerThirdBuffer()), 4: image(from: checkerBuffer())]
    }

    /// V8 的四路输入（像素缓冲形态，实时路径用）。
    static func referenceBuffers() -> [Int: CVPixelBuffer] {
        [1: patternBuffer(), 2: colorBarsBuffer(), 3: lowerThirdBuffer(), 4: checkerBuffer()]
    }
}

/// V8 的固定状态。
enum ReferenceStates {
    static func inputs(count: Int = 4) -> [InputConfig] {
        let names = ["摄像机 1", "Camera 2", "Lower Third", "PiP 画中画", "Cam 5", "Cam 6", "Cam 7", "Cam 8"]
        return (1...count).map { InputConfig(number: $0, name: names[($0 - 1) % names.count], source: .synthetic(settings: SyntheticSourceSettings())) }
    }

    /// 固定状态：PGM = 输入 1，PVW = 输入 2，Overlay 1 = 输入 3（整幅下三分之一），Overlay 3 = 输入 4（画中画右下 1/4），FTB 关。
    static func fixed() -> MixerState {
        var s = MixerState(format: .hd1080p60, inputs: inputs(), program: 1, preview: 2)
        s.overlays[0] = OverlayState(input: 3, on: true, rect: .full, animProgress: 1)
        s.overlays[2] = OverlayState(input: 4, on: true, rect: .bottomRightQuarter, animProgress: 1)
        s.transition = TransitionState(type: .fade, durationTicks: 30, progress: 0)
        s.ftb = FadeToBlack(on: false, durationTicks: 30, level: 0)
        return s
    }

    /// Fade 50%：输入 2 盖在输入 1 上一半。
    static func fade50() -> MixerState {
        var s = fixed()
        s.transition = TransitionState(type: .fade, durationTicks: 30, progress: 0.5, source: .auto, startTick: Tick(100))
        return s
    }

    /// FTB 100%。
    static func ftb100() -> MixerState {
        var s = fixed()
        s.ftb = FadeToBlack(on: true, durationTicks: 30, level: 1)
        return s
    }
}
