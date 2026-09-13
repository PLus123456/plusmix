// 离线渲染：给一个状态和一组输入图，画出 PGM / PVW / 多画面 PNG 和 NV12 输出（测试标准 V8 / V9 的前提，设计方案 §5 最后一条）。
// 和实时路径共用 CompositorPasses.encodeFrame —— 这是全仓库唯一编码合成 pass 的函数；这里只是换了目标纹理和等待方式。
@preconcurrency import Metal
import CoreGraphics
import CoreVideo
import Foundation
import SwitcherContracts

/// renderOffline 要哪张图。
public enum OfflineRenderTarget: Sendable, Hashable {
    case program, preview, multiview
}

/// 一次离线渲染的全部产物。
public struct OfflineRenderResult {
    /// PGM（BGRA，alpha 恒 1）。
    public let program: CGImage
    /// PVW。
    public let preview: CGImage
    /// 多画面（带 tally 边框和名字）。
    public let multiview: CGImage
    /// PGM 经 RGB→NV12 kernel 的输出（BT.709 limited，IOSurface 背后）——与实时路径交给编码器的完全相同。
    public let programNV12: CVPixelBuffer
}

/// 离线渲染器。非实时，允许分配；同一实例按尺寸缓存目标纹理，重复调用不重建。线程：一次只在一个线程上用。
public final class OfflineRenderer {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let resources: RenderResources
    private var session: Session?

    /// 一个尺寸对应的目标纹理和读回纹理。
    private final class Session {
        let width: Int
        let height: Int
        let targets: RenderTargets
        let slot: RenderSlot
        let table: SurfaceTextureTable
        let labels: LabelSet
        let ring: OutputBufferRing
        let staging: [any MTLTexture]   // program / preview / multiview 的共享内存副本
        let scratch: UnsafeMutableRawPointer

        init(device: any MTLDevice, width: Int, height: Int, maxInputs: Int) throws {
            self.width = width
            self.height = height
            targets = try RenderTargets(device: device, width: width, height: height, label: "offline")
            slot = RenderSlot(index: 0, targets: targets, maxInputs: maxInputs)
            table = SurfaceTextureTable(device: device, capacity: maxInputs * 4 + 16)
            labels = try LabelSet(device: device, slices: maxInputs)
            ring = try OutputBufferRing(width: width, height: height, count: 3)
            var st: [any MTLTexture] = []
            for name in ["program", "preview", "multiview"] {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderResources.workingFormat,
                                                                 width: width, height: height, mipmapped: false)
                d.usage = .shaderRead
                d.storageMode = .shared
                guard let t = device.makeTexture(descriptor: d) else { throw RenderError.resource("建不出离线读回纹理 \(name)") }
                t.label = "offline.staging.\(name)"
                st.append(t)
            }
            staging = st
            scratch = UnsafeMutableRawPointer.allocate(byteCount: LabelSet.width * LabelSet.height * 4, alignment: 16)
        }

        deinit { scratch.deallocate() }
    }

    public init(device: (any MTLDevice)? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = dev
        guard let q = dev.makeCommandQueue() else { throw RenderError.resource("建不出命令队列") }
        q.label = "switcher.render.offline"
        queue = q
        resources = try RenderResources.shared(for: dev)
    }

    /// prompt 里的签名：状态 + 输入图（按输入编号）+ 尺寸 → 一张图（默认 PGM）。
    public func renderOffline(state: MixerState, inputs: [Int: CGImage], size: CGSize,
                              target: OfflineRenderTarget = .program) throws -> CGImage {
        let r = try render(state: state, inputs: inputs, size: size)
        switch target {
        case .program: return r.program
        case .preview: return r.preview
        case .multiview: return r.multiview
        }
    }

    /// 输入图 → 全部产物。CGImage 一律转成 BGRA（预乘 alpha）IOSurface 像素缓冲，走 BGRA 输入路径。
    public func render(state: MixerState, inputs: [Int: CGImage], size: CGSize) throws -> OfflineRenderResult {
        var buffers: [Int: CVPixelBuffer] = [:]
        for (number, image) in inputs {
            buffers[number] = try OfflineRenderer.makeBGRAPixelBuffer(from: image)
        }
        return try render(state: state, pixelBuffers: buffers, size: size)
    }

    /// 直接给像素缓冲（NV12 / BGRA / UYVY 都行，须 IOSurface 背后）；色彩按像素格式推（BGRA = sRGB full，'420f' = 709 full，其余 709 limited）。
    public func render(state: MixerState, pixelBuffers: [Int: CVPixelBuffer], size: CGSize) throws -> OfflineRenderResult {
        var frames: [Int: Frame] = [:]
        for (number, pb) in pixelBuffers {
            frames[number] = Frame(pixelBuffer: pb, pts: .zero, duration: .zero, color: OfflineRenderer.colorInfo(of: pb),
                                   inputNumber: number, sequence: 0, ingressTime: .zero)
        }
        return try render(state: state, frames: frames, size: size)
    }

    /// 最底层：给带色彩描述的帧（BT.601 输入这类要自己标 ColorInfo 的用它）。
    public func render(state: MixerState, frames: [Int: Frame], size: CGSize) throws -> OfflineRenderResult {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width >= 2, height >= 2 else { throw RenderError.resource("尺寸至少 2×2") }
        let maxNumber = max(state.inputs.map(\.number).max() ?? 0, frames.keys.max() ?? 0)
        let maxInputs = maxNumber + 1
        let s: Session
        if let existing = session, existing.width == width, existing.height == height, existing.slot.heldFrames.count >= maxInputs {
            s = existing
        } else {
            s = try Session(device: device, width: width, height: height, maxInputs: max(maxInputs, 8))
            session = s
        }
        // 输入表（和引擎每拍填的那张一样）
        let table = RenderInputTable(capacity: s.slot.heldFrames.count)
        for (number, frame) in frames where number > 0 && number < table.capacity {
            table[inputNumber: number] = frame
        }
        // 标签同步画好（实时路径由后台线程画）
        LabelPainter.update(s.labels, from: state, scratch: s.scratch)

        guard let output = s.ring.next(), let unmanaged = CVPixelBufferGetIOSurface(output) else {
            throw RenderError.resource("拿不到输出像素缓冲")
        }
        let surface = unmanaged.takeUnretainedValue()
        guard let luma = s.table.texture(surface: surface, plane: 0, format: .r8Uint, width: width, height: height,
                                         usage: .shaderWrite, frame: 0),
              let chroma = s.table.texture(surface: surface, plane: 1, format: .rg8Uint, width: (width + 1) / 2, height: (height + 1) / 2,
                                           usage: .shaderWrite, frame: 0) else {
            throw RenderError.resource("输出平面包不成纹理")
        }
        guard let cb = queue.makeCommandBuffer() else { throw RenderError.resource("建不出命令缓冲区") }
        cb.label = "switcher.offline"
        let context = CompositorPasses.Context(resources: resources, table: s.table, labels: s.labels, frameIndex: 0)
        // ---- 与实时路径同一个函数 ----
        CompositorPasses.encodeFrame(state: state, inputs: table, slot: s.slot, context: context, commandBuffer: cb,
                                     outputLuma: luma, outputChroma: chroma, multiview: true)
        // 读回：三张目标纹理拷到共享内存
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: s.targets.program, to: s.staging[0])
            blit.copy(from: s.targets.preview, to: s.staging[1])
            blit.copy(from: s.targets.multiview, to: s.staging[2])
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        s.slot.releaseFrame()
        if let err = cb.error { throw RenderError.resource("GPU 执行失败：\(err)") }
        return OfflineRenderResult(program: try OfflineRenderer.makeImage(from: s.staging[0]),
                                   preview: try OfflineRenderer.makeImage(from: s.staging[1]),
                                   multiview: try OfflineRenderer.makeImage(from: s.staging[2]),
                                   programNV12: output)
    }

    // MARK: - 像素缓冲 ↔ CGImage

    static func colorInfo(of pb: CVPixelBuffer) -> ColorInfo {
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA: .sRGBFull
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: .bt709Full
        default: .bt709Limited
        }
    }

    /// CGImage → 32BGRA 预乘、IOSurface 背后的像素缓冲。用图像自己的 RGB 色彩空间画，不做色彩转换（像素值原样）。
    public static func makeBGRAPixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width, height = image.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let pb else { throw RenderError.pixelBufferPool(st) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space, bitmapInfo: info) else {
            throw RenderError.resource("建不出 CGContext")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    /// 共享内存的 BGRA 纹理 → CGImage（sRGB，预乘 alpha）。
    static func makeImage(from texture: any MTLTexture) throws -> CGImage {
        let width = texture.width, height = texture.height, bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { throw RenderError.resource("建不出 CGDataProvider") }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RenderError.resource("建不出 CGImage")
        }
        return image
    }
}
