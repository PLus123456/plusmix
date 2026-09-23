// 输出 NV12 像素缓冲（IOSurface 背后）的环。
//
// 为什么不直接用 CVPixelBufferPool：探针实测 CVPixelBufferPoolCreatePixelBuffer 每次都新建 CVPixelBuffer 对象（约 6 次分配），
// 池子回收的只是 IOSurface。这里在建环时一次建好 N 个 CVPixelBuffer，每帧挑一个"只有环自己持有"的（CFGetRetainCount == 1）
// 复用；消费者（编码、录制……）持有期间不会被挑到。全部被占时退回到池子分配一个新的（记 fallbackCount，这是消费者
// 拖着不放的信号，不该在稳态出现）。
// W3-B2：建环时给了 device 就顺手把每个缓冲的两个平面包成 compute 写的整数纹理（r8Uint / rg8Uint），渲染线程拿缓冲时一起拿走，
// 不再在渲染线程第一次用到时建纹理——环可以在别的线程建（PVW / 多画面的环按需建，见 AuxOutputRings），渲染线程照样零分配。
@preconcurrency import Metal
import CoreVideo
import IOSurface
import SwitcherContracts

/// `@unchecked Sendable`：建好之后只有一条线程用它（实时路径是渲染线程；按需建的环由后台线程建好、原子发布之后交给渲染线程）。
final class OutputBufferRing: @unchecked Sendable {
    let width: Int
    let height: Int
    private var buffers: [CVPixelBuffer] = []
    /// 每个缓冲预先包好的 NV12 目标（init 给了 device 才有，与 buffers 一一对应）。
    private var targets: [CompositorPasses.NV12Target] = []
    private var cursor = 0
    private var fallbackPool: CVPixelBufferPool?
    /// 环里没有空闲缓冲、只好从池子分配的次数。
    private(set) var fallbackCount = 0

    /// NV12 BT.709 limited 的 CVPixelBuffer 属性（引擎输出永远是它，V9）。
    static func attributes(width: Int, height: Int) -> [CFString: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey: PixelFormat.nv12.cvPixelFormatType(range: .limited),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
    }

    /// "只有环自己持有"时 `retainCount(at:)` 的读数。在 init 里用同一个函数量出来，不猜编译器会不会为局部变量多 retain 一次。
    private var idleRetainCount: CFIndex = 0

    /// device 给了就预先包好每个缓冲的 NV12 目标纹理（`nextSlot()` 一起返回）；不给（单元测试）就只有缓冲。
    init(width: Int, height: Int, count: Int, device: (any MTLDevice)? = nil) throws {
        self.width = width
        self.height = height
        let attrs = OutputBufferRing.attributes(width: width, height: height) as CFDictionary
        for _ in 0..<max(3, count) {
            var pb: CVPixelBuffer?
            let st = CVPixelBufferCreate(nil, width, height, PixelFormat.nv12.cvPixelFormatType(range: .limited), attrs, &pb)
            guard st == kCVReturnSuccess, let pb else { throw RenderError.pixelBufferPool(st) }
            OutputBufferRing.tagColor(pb)
            buffers.append(pb)
            if let device {
                guard let target = OutputBufferRing.makeTarget(pb, device: device) else { throw RenderError.resource("输出缓冲包不成 NV12 纹理") }
                targets.append(target)
            }
        }
        var pool: CVPixelBufferPool?
        let st = CVPixelBufferPoolCreate(nil, nil, attrs, &pool)
        guard st == kCVReturnSuccess, let pool else { throw RenderError.pixelBufferPool(st) }
        fallbackPool = pool
        idleRetainCount = retainCount(at: 0)
    }

    /// IOSurface 的两个平面 → compute kernel 写的整数视图（与 MetalRenderer.nv12Target 同一个描述）。
    static func makeTarget(_ pb: CVPixelBuffer, device: any MTLDevice) -> CompositorPasses.NV12Target? {
        guard let unmanaged = CVPixelBufferGetIOSurface(pb) else { return nil }
        let surface = unmanaged.takeUnretainedValue()
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        func plane(_ index: Int, _ format: MTLPixelFormat, _ pw: Int, _ ph: Int) -> (any MTLTexture)? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: pw, height: ph, mipmapped: false)
            d.usage = .shaderWrite
            d.storageMode = .shared
            return device.makeTexture(descriptor: d, iosurface: surface, plane: index)
        }
        guard let luma = plane(0, .r8Uint, w, h), let chroma = plane(1, .rg8Uint, (w + 1) / 2, (h + 1) / 2) else { return nil }
        return CompositorPasses.NV12Target(luma: luma, chroma: chroma)
    }

    /// 不内联：init 里量基线和 next 里做判断走的是同一段机器码，retain 行为一致。
    @inline(never)
    private func retainCount(at i: Int) -> CFIndex {
        CFGetRetainCount(buffers[i])
    }

    /// 把 BT.709 limited 写进附件，编码器（VideoToolbox）会读它。
    private static func tagColor(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// 下一个空闲的缓冲。渲染线程调用；稳态零分配。
    func next() -> CVPixelBuffer? { nextSlot()?.buffer }

    /// 下一个空闲的缓冲 + 它预先包好的 NV12 目标（没预包 / 退回池子分配的缓冲为 nil，调用方自己包）。渲染线程调用；稳态零分配。
    func nextSlot() -> (buffer: CVPixelBuffer, target: CompositorPasses.NV12Target?)? {
        let n = buffers.count
        var step = 0
        while step < n {   // 显式循环：-Onone 下 for-in 会分配
            let i = (cursor + step) % n
            // 只有环自己持有 → 可以复用；消费者还拿着 → 跳过
            if retainCount(at: i) == idleRetainCount {
                cursor = (i + 1) % n
                return (buffers[i], i < targets.count ? targets[i] : nil)
            }
            step += 1
        }
        // 全被消费者占着：退回池子（分配）
        fallbackCount += 1
        var pb: CVPixelBuffer?
        if let pool = fallbackPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb {
            OutputBufferRing.tagColor(pb)
            return (pb, nil)
        }
        return nil
    }

    var count: Int { buffers.count }
    /// 这个环常驻的像素字节数（NV12 = 宽 × 高 × 1.5，报告算内存用）。
    var residentBytes: Int { buffers.count * width * height * 3 / 2 }
}
