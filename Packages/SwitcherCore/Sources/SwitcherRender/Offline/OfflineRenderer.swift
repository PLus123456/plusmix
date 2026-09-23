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
    /// PVW 的 NV12（= 实时路径 previewOutput 打开时 RenderedFrame.preview 的内容）。
    public let previewNV12: CVPixelBuffer
    /// 多画面的 NV12（= 实时路径 multiviewOutput 打开时 RenderedFrame.multiview 的内容）。
    public let multiviewNV12: CVPixelBuffer
}

/// 只要 NV12 时的产物（V6 / V7 逐拍渲染用，省掉三张 CGImage 的读回）。
public struct OfflineNV12Result {
    public let program: CVPixelBuffer
    public let preview: CVPixelBuffer
    public let multiview: CVPixelBuffer
}

/// 离线渲染器。非实时，允许分配；同一实例按尺寸缓存目标纹理，重复调用不重建。线程：一次只在一个线程上用。
public final class OfflineRenderer {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let resources: RenderResources
    private var session: Session?
    /// PVW 也画叠加（= MetalRendererOptions.overlaysInPreview）。
    public var overlaysInPreview = false
    /// 多画面电平表的读数（= MetalRenderer.setMeters 那条通道，W3-B2）；离线渲染不判过期。
    private let meterFeed = MultiviewMeterFeed()

    /// 一个尺寸对应的目标纹理和读回纹理。
    private final class Session {
        let width: Int
        let height: Int
        let targets: RenderTargets
        let slot: RenderSlot
        let table: SurfaceTextureTable
        let labels: LabelSet
        let ring: OutputBufferRing
        let previewRing: OutputBufferRing
        let multiviewRing: OutputBufferRing
        let layout = MultiviewLayoutTable()
        let staging: [any MTLTexture]   // program / preview / multiview 的共享内存副本
        let scratch: UnsafeMutableRawPointer

        init(device: any MTLDevice, width: Int, height: Int, maxInputs: Int) throws {
            self.width = width
            self.height = height
            targets = try RenderTargets(device: device, width: width, height: height, label: "offline")
            slot = RenderSlot(index: 0, targets: targets, maxInputs: maxInputs)
            table = SurfaceTextureTable(device: device, capacity: maxInputs * 4 + 32)
            labels = try LabelSet(device: device, inputSlots: maxInputs)
            ring = try OutputBufferRing(width: width, height: height, count: 3)
            previewRing = try OutputBufferRing(width: width, height: height, count: 3)
            multiviewRing = try OutputBufferRing(width: width, height: height, count: 3)
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

    /// 多画面电平表的读数（同 `MetalRenderer.setMeters`：峰值保持按 `time` 算；nil = 清掉）。之后每次渲染都用最后喂的那份，
    /// 离线渲染不看钟、不判过期。参考图 / 测试用固定的 `time`，结果确定。
    public func setMeters(_ meters: Stats.AudioCounters.Meters?, at time: HostTime = HostClock.now()) {
        meterFeed.write(meters, at: time)
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
        let (s, nv12) = try encode(state: state, frames: frames, size: size, readback: true)
        return OfflineRenderResult(program: try OfflineRenderer.makeImage(from: s.staging[0]),
                                   preview: try OfflineRenderer.makeImage(from: s.staging[1]),
                                   multiview: try OfflineRenderer.makeImage(from: s.staging[2]),
                                   programNV12: nv12.program, previewNV12: nv12.preview, multiviewNV12: nv12.multiview)
    }

    /// 只要 NV12（不读回 CGImage）。
    public func renderNV12(state: MixerState, frames: [Int: Frame], size: CGSize) throws -> OfflineNV12Result {
        try encode(state: state, frames: frames, size: size, readback: false).1
    }

    /// 同上，给像素缓冲。
    public func renderNV12(state: MixerState, pixelBuffers: [Int: CVPixelBuffer], size: CGSize) throws -> OfflineNV12Result {
        var frames: [Int: Frame] = [:]
        for (number, pb) in pixelBuffers {
            frames[number] = Frame(pixelBuffer: pb, pts: .zero, duration: .zero, color: OfflineRenderer.colorInfo(of: pb),
                                   inputNumber: number, sequence: 0, ingressTime: .zero)
        }
        return try renderNV12(state: state, frames: frames, size: size)
    }

    /// 编码 + 提交 + 等完成。readback = true 时把三张目标纹理拷到共享内存（staging）。
    private func encode(state: MixerState, frames: [Int: Frame], size: CGSize, readback: Bool) throws -> (Session, OfflineNV12Result) {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width >= 2, height >= 2 else { throw RenderError.resource("尺寸至少 2×2") }
        let maxNumber = max(state.inputs.map(\.number).max() ?? 0, frames.keys.max() ?? 0, state.transition.stinger.input ?? 0)
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
        // 布局每次都解析（实时路径只在 sequence 变了时解析）；标签按解析好的布局同步画好（实时路径由标签线程画）
        s.layout.parse(state: state, width: width, height: height)
        LabelPainter.update(s.labels, from: state, layout: s.layout, scratch: s.scratch)

        func target(_ ring: OutputBufferRing) throws -> (CVPixelBuffer, CompositorPasses.NV12Target) {
            guard let output = ring.next(), let unmanaged = CVPixelBufferGetIOSurface(output) else {
                throw RenderError.resource("拿不到输出像素缓冲")
            }
            let surface = unmanaged.takeUnretainedValue()
            guard let luma = s.table.texture(surface: surface, plane: 0, format: .r8Uint, width: width, height: height,
                                             usage: .shaderWrite, frame: 0),
                  let chroma = s.table.texture(surface: surface, plane: 1, format: .rg8Uint, width: (width + 1) / 2, height: (height + 1) / 2,
                                               usage: .shaderWrite, frame: 0) else {
                throw RenderError.resource("输出平面包不成纹理")
            }
            return (output, CompositorPasses.NV12Target(luma: luma, chroma: chroma))
        }
        let (program, programTarget) = try target(s.ring)
        let (preview, previewTarget) = try target(s.previewRing)
        let (multiview, multiviewTarget) = try target(s.multiviewRing)
        guard let cb = queue.makeCommandBuffer() else { throw RenderError.resource("建不出命令缓冲区") }
        cb.label = "switcher.offline"
        var context = CompositorPasses.Context(resources: resources, table: s.table, labels: s.labels, layout: s.layout, frameIndex: 0)
        context.overlaysInPreview = overlaysInPreview
        context.meters = meterFeed.acquire(now: nil)
        // ---- 与实时路径同一个函数 ----
        CompositorPasses.encodeFrame(state: state, inputs: table, slot: s.slot, context: context, commandBuffer: cb,
                                     outputs: CompositorPasses.FrameOutputs(program: programTarget, preview: previewTarget, multiview: multiviewTarget),
                                     multiview: true)
        if readback, let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: s.targets.program, to: s.staging[0])
            blit.copy(from: s.targets.preview, to: s.staging[1])
            blit.copy(from: s.targets.multiview, to: s.staging[2])
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        s.slot.releaseFrame()
        if let err = cb.error { throw RenderError.resource("GPU 执行失败：\(err)") }
        return (s, OfflineNV12Result(program: program, preview: preview, multiview: multiview))
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
