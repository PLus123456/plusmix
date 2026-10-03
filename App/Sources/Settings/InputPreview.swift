// 输入设置窗的本路画面与取色（W5-K，prompt 97 交付 2，01a H3 / H6，04 Q55）：
// - 画面：MetalDisplayView 切多画面纹理里这一格（与输入条缩略图同一算法 InputStripView.thumbnailRect，不动渲染器、画质是缩略图级）；
// - 取色：在画面上点一下 → 换成纹理里的像素位置 → 取 3×3 平均作键色（PixelSampler）。显示视图按比例放（上下 / 左右留黑边），点到黑边不取。
import AppKit
import Metal
import SwiftUI
import SwitcherContracts
import SwitcherRender

/// 从显示纹理取一点的颜色。
enum PixelSampler {
    /// 纹理上以 (x, y) 为中心 3×3 的平均（BGRA8；贴边只平均落在纹理里的那几个）。私有存储的纹理先 blit 到一块小的共享纹理再读。
    static func average3x3(texture: any MTLTexture, queue: any MTLCommandQueue, x: Int, y: Int) -> RGB8? {
        guard texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb, texture.width > 0, texture.height > 0 else { return nil }
        let cx = min(max(x, 0), texture.width - 1), cy = min(max(y, 0), texture.height - 1)
        let x0 = max(cx - 1, 0), x1 = min(cx + 1, texture.width - 1)
        let y0 = max(cy - 1, 0), y1 = min(cy + 1, texture.height - 1)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: w, height: h, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        guard let staging = texture.device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            staging.getBytes(raw.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var b = 0, g = 0, r = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            b += Int(bytes[i])
            g += Int(bytes[i + 1])
            r += Int(bytes[i + 2])
        }
        let n = w * h
        func avg(_ s: Int) -> UInt8 { UInt8(min(255, (s + n / 2) / n)) }
        return RGB8(red: avg(r), green: avg(g), blue: avg(b))
    }
}

/// 本路画面的容器：装着显示视图，取色时十字光标、点一下报"点在这一格画面里的哪儿"（0–1，原点左上）。
@MainActor
final class InputPreviewContainer: NSView {
    let display: MetalDisplayView
    /// 多画面纹理的尺寸（= 节目分辨率），算按比例放的位置用。
    var textureSize = NSSize(width: 1920, height: 1080)
    /// 切多画面纹理的哪一块。
    var sourceRect: NormalizedRect = .full {
        didSet { if display.sourceRect != sourceRect { display.sourceRect = sourceRect } }
    }
    /// 正在取色（十字光标、点一下就取）。
    var isPicking = false {
        didSet { if oldValue != isPicking { window?.invalidateCursorRects(for: self) } }
    }
    var onPick: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }

    init(display: MetalDisplayView) {
        self.display = display
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.frame = bounds
        display.autoresizingMask = [.width, .height]
        addSubview(display)
        setAccessibilityLabel(L("inputSettings.preview.label"))
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        display.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isPicking { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isPicking, let p = Self.normalizedPoint(convert(event.locationInWindow, from: nil), viewSize: bounds.size, sourceRect: sourceRect, textureSize: textureSize) else {
            super.mouseDown(with: event)
            return
        }
        onPick?(p)
    }

    /// 视图里的点（原点左上）→ 这一格画面里的位置（0–1）：画面按比例放在视图正中（与 MetalDisplayView / Placement.fill 同一个 fit），点到黑边为 nil。
    nonisolated static func normalizedPoint(_ point: NSPoint, viewSize: NSSize, sourceRect: NormalizedRect, textureSize: NSSize) -> CGPoint? {
        let srcW = sourceRect.width * textureSize.width, srcH = sourceRect.height * textureSize.height
        guard srcW > 0, srcH > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let k = min(viewSize.width / srcW, viewSize.height / srcH)
        let dw = srcW * k, dh = srcH * k
        let ox = (viewSize.width - dw) / 2, oy = (viewSize.height - dh) / 2
        let u = (point.x - ox) / dw, v = (point.y - oy) / dh
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }
}

/// SwiftUI 里放本路画面的容器（窗口控制器持有容器本身，SwiftUI 只负责摆位置）。
struct InputPreviewRepresentable: NSViewRepresentable {
    let container: InputPreviewContainer

    func makeNSView(context: Context) -> InputPreviewContainer {
        container.setAccessibilityLabel(L("inputSettings.preview.label"))
        return container
    }

    func updateNSView(_ nsView: InputPreviewContainer, context: Context) {}
}
