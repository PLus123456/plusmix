// 输出 NV12 像素缓冲（IOSurface 背后）的环。
//
// 为什么不直接用 CVPixelBufferPool：探针实测 CVPixelBufferPoolCreatePixelBuffer 每次都新建 CVPixelBuffer 对象（约 6 次分配），
// 池子回收的只是 IOSurface。这里在 prepare 里一次建好 N 个 CVPixelBuffer，每帧挑一个"只有环自己持有"的（CFGetRetainCount == 1）
// 复用；消费者（编码、录制……）持有期间不会被挑到。全部被占时退回到池子分配一个新的（记 fallbackCount，这是消费者
// 拖着不放的信号，不该在稳态出现）。
import CoreVideo
import IOSurface
import SwitcherContracts

final class OutputBufferRing {
    let width: Int
    let height: Int
    private var buffers: [CVPixelBuffer] = []
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

    init(width: Int, height: Int, count: Int) throws {
        self.width = width
        self.height = height
        let attrs = OutputBufferRing.attributes(width: width, height: height) as CFDictionary
        for _ in 0..<max(3, count) {
            var pb: CVPixelBuffer?
            let st = CVPixelBufferCreate(nil, width, height, PixelFormat.nv12.cvPixelFormatType(range: .limited), attrs, &pb)
            guard st == kCVReturnSuccess, let pb else { throw RenderError.pixelBufferPool(st) }
            OutputBufferRing.tagColor(pb)
            buffers.append(pb)
        }
        var pool: CVPixelBufferPool?
        let st = CVPixelBufferPoolCreate(nil, nil, attrs, &pool)
        guard st == kCVReturnSuccess, let pool else { throw RenderError.pixelBufferPool(st) }
        fallbackPool = pool
        idleRetainCount = retainCount(at: 0)
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
    func next() -> CVPixelBuffer? {
        let n = buffers.count
        var step = 0
        while step < n {   // 显式循环：-Onone 下 for-in 会分配
            let i = (cursor + step) % n
            // 只有环自己持有 → 可以复用；消费者还拿着 → 跳过
            if retainCount(at: i) == idleRetainCount {
                cursor = (i + 1) % n
                return buffers[i]
            }
            step += 1
        }
        // 全被消费者占着：退回池子（分配）
        fallbackCount += 1
        var pb: CVPixelBuffer?
        if let pool = fallbackPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb {
            OutputBufferRing.tagColor(pb)
            return pb
        }
        return nil
    }

    var count: Int { buffers.count }
}
